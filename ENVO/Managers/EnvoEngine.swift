import Foundation
import Combine
import SwiftUI
import AVFoundation

// MARK: - Configuration Types

enum SpeedMode: String, CaseIterable, Identifiable, Codable {
    case slow   = "SLOW"
    case medium = "MED"
    case fast   = "FAST"

    var id: String { rawValue }

    var windowSeconds: Double {
        switch self {
        case .slow:   return 60.0
        case .medium: return 30.0
        case .fast:   return 10.0
        }
    }
}

enum RangeMode: String, CaseIterable, Identifiable, Codable {
    case quiet  = "±3dB"
    case medium = "±6dB"
    case loud   = "±9dB"

    var id: String { rawValue }

    /// Maximum adjustment in dB, in either direction.
    ///
    /// This is a **limit, not a gain**. The previous implementation folded
    /// this value into the control law's sensitivity, so choosing a wider
    /// range also made ENVO react more aggressively — two different things
    /// behind one control. Sensitivity is now `compensationGain` below and
    /// is independent of this setting.
    var maxOffsetDB: Float {
        switch self {
        case .quiet:  return 3.0
        case .medium: return 6.0
        case .loud:   return 9.0
        }
    }
}

// MARK: - Engine

/// The control loop.
///
/// UNITS
/// -----
/// Everything in this file is in **decibels** unless the name says
/// `slider`. The engine's control variable is `currentOffsetDB` — how much
/// louder or quieter than the user's baseline ENVO currently wants to be.
/// Converting that intent into slider movement is `VolumeTaper`'s job and
/// happens exactly once, at the point of application.
///
/// That separation is the fix for the range-bound leak: the old code clamped
/// its intent to ±rangeDB correctly, then converted to a slider delta with a
/// curve that assumed the iOS slider is proportional to amplitude. The clamp
/// was real; the conversion threw the bound away.
final class EnvoEngine: ObservableObject {

    // MARK: - Published State (UI-facing)

    @Published var speedMode: SpeedMode = .medium
    @Published var rangeMode: RangeMode = .medium
    @Published var isActive: Bool = false

    @Published var allowIncrease: Bool = true
    @Published var allowDecrease: Bool = true

    /// Current adjustment in dB — the number the UI shows. The old ADJ
    /// readout printed `sliderOffset × 100` with no unit, which users
    /// reasonably read as decibels; a "-14" there was a 14% slider move.
    @Published private(set) var currentOffsetDB: Float = 0.0

    /// Current adjustment as slider travel, for diagnostics.
    @Published private(set) var currentSliderOffset: Float = 0.0

    /// Estimated room level in dBFS, or nil while the estimate is not
    /// trustworthy (mic dead, or our own playback masking the room).
    @Published private(set) var estimatedAmbientDB: Float?

    /// Normalized 0…1 history for the visualizer. Display only.
    @Published private(set) var levelHistory: [Float] = []

    /// What the hardware is actually delivering, in dB, relative to the user's
    /// baseline. Differs from `currentOffsetDB` — the intent — by up to half a
    /// hardware step, because the system volume is quantized. This is what the
    /// readout shows: the intent is what ENVO wants, and showing it as though it
    /// were the result meant the app's most prominent number was routinely
    /// 1.5 dB away from anything the user could hear.
    @Published private(set) var deliveredOffsetDB: Float = 0

    /// True when the live room floor disagrees materially with the calibrated
    /// one. Surfaced as a "recalibrate?" hint.
    @Published private(set) var calibrationStale: Bool = false

    /// The microphone appears to be covered — pocket, bag, face-down. The
    /// adjustment is held while this is true, and the UI says so.
    @Published private(set) var isMicrophoneObstructed: Bool = false

    /// The input is hitting full scale, so the level reading has stopped
    /// tracking the room. Held, not acted on.
    @Published private(set) var isInputClipping: Bool = false

    /// Nothing else is playing, so there is nothing to adapt. ENVO keeps
    /// measuring the room but leaves the volume alone.
    @Published private(set) var isWaitingForPlayback: Bool = false

    /// Set when START could not proceed, so the UI can say why instead of
    /// silently doing nothing.
    @Published private(set) var lastStartFailure: String?

    // MARK: - Dependencies (injected)

    let audioManager: AudioManager
    let volumeController: VolumeController
    let calibrationStore: CalibrationStore
    let settings: SettingsStore

    var isCalibrated: Bool { calibrationStore.isCalibrated }

    /// The taper in force right now: measured when a valid profile exists for
    /// the current output route, the conservative default otherwise.
    var activeTaper: VolumeTaper {
        guard let profile = calibrationStore.profile, profile.isUsable else {
            return .default
        }
        return profile.applicableTaper
    }

    // MARK: - Control law constants

    /// How many dB of volume change ENVO applies per dB of ambient change.
    ///
    /// Full compensation (1.0) is wrong: rooms get louder partly *because*
    /// listeners raise their voices, and matching a noisy room dB-for-dB
    /// produces an arms race. Partial compensation in the 0.3–0.5 range is
    /// the established behaviour for automotive and hearing-aid volume
    /// compensation, and it is what makes the result feel like it is holding
    /// the music steady rather than chasing the room.
    /// Applies whether or not a profile exists. The ambient floor is now
    /// measured the same way in both cases (see AmbientTracker), so there is
    /// no longer a reason for the loop to behave differently — what
    /// calibration buys is dB *accuracy* via the measured taper, plus gap and
    /// staleness reporting.
    private let compensationGain: Float = 0.40

    /// Smoothing retention on the dB intent, per 1 Hz tick.
    private let offsetSmoothing: Float = 0.85

    /// Anti-Lombard correction. See LombardDamper for why it can only ever
    /// make ENVO do less, never more.
    private let lombardDamper = LombardDamper()

    /// Dead band. Below this the adjustment is snapped to zero rather than
    /// micro-nudged. 0.5 dB is under the just-noticeable difference for
    /// music, so this costs nothing audible and stops the volume creeping
    /// around by fractions of a step all evening.
    private let zeroHysteresisDB: Float = 0.5

    /// Maximum rate of change of the adjustment. Slow enough that the change
    /// is not perceived as an event, which is the entire point of the app.
    let maxRateDBPerSecond: Float = 0.75

    /// Hard ceiling on the resulting system volume. ENVO never pushes above
    /// this no matter how loud the room gets.
    let safetyCeiling: Float = 0.92

    // MARK: - Private state

    private var cancellables = Set<AnyCancellable>()
    private var engineTimer: Timer?

    private let sampleInterval: TimeInterval = 1.0

    /// Microphone readings per second. The loop still *decides* once a second,
    /// but it *measures* ten times a second, because the floor is an order
    /// statistic and an order statistic needs samples. At 1 Hz the L90 of a
    /// ten-second window was the single lowest of ten readings — an estimator
    /// whose several-decibel scatter came from nothing but which millisecond
    /// each reading happened to land on.
    static let micSamplesPerSecond = 10

    /// Rolling microphone history, from which the ambient floor is derived.
    /// L90 over up to sixty seconds at 10 Hz.
    private var ambientTracker = AmbientTracker(percentile: 0.1,
                                                minimumSamples: 20,
                                                capacity: 600)

    /// Removes ENVO's own contribution from the measured floor. See
    /// `SelfCouplingEstimator` — without it the loop partly steers on its own
    /// output whenever dense music is playing through a speaker.
    private var selfCoupling = SelfCouplingEstimator()

    /// Spots a covered microphone, which a low percentile follows straight down.
    private var obstructionDetector = ObstructionDetector()

    /// Estimated-ambient history, for the visualizer.
    private var ambientSamplesDB: [Float] = []
    private let maxSampleCount = 600

    /// The room level ENVO is compensating relative to: the room as it was
    /// when START was pressed. Deliberately does NOT drift — a drifting
    /// baseline means a sustained loud room eventually reads as "normal"
    /// again and the compensation quietly evaporates. It is re-anchored only
    /// when the user manually changes the volume, which is them restating
    /// what "normal" means.
    private var baselineAmbientDB: Float = 0
    private var hasBaseline = false
    private var warmupTicks = 0

    /// Ticks of history before the baseline is fixed. Long enough for the
    /// percentile floor to be meaningful, short enough that START feels like
    /// it did something.
    private let warmupCount = 8

    /// Rolling raw-level window used to spot stretches quiet enough to compare
    /// against the calibrated silence floor. See `checkCalibrationDrift`.
    private var recentRawDB: [Float] = []
    private let gapWindowSize = 5

    /// A stretch counts as clean when the mic hears nothing beyond what we
    /// believe the room to be, plus this margin. Additive, because the
    /// quantity is a decibel value — the old code multiplied the floor by 1.4,
    /// which meant +1 dB at a floor of 0.05 and +11 dB at a floor of 0.5, an
    /// effectively random threshold that fired on nearly every tick.
    private let gapMarginDB: Float = 3.0

    /// Consecutive clean observations disagreeing with the calibrated floor
    /// before the stale hint appears, so the button label cannot flicker.
    private let staleConfirmations = 4
    private let staleThresholdDB: Float = 6.0
    private var staleStreak = 0

    private var appliedSliderOffset: Float = 0.0
    private let sliderChangeThreshold: Float = 0.004

    /// Consecutive ticks with a dead mic. The offset is held regardless; this
    /// drives the revival backoff and the logging.
    private var deadMicTicks = 0

    /// Ticks to wait before the next attempt to rebuild the input engine, and
    /// how long since the last one. Rebuilding once a second forever hammers
    /// the audio subsystem during exactly the system-wide trouble that caused
    /// the failure, floods the log, and costs battery for no benefit. Doubles
    /// to a thirty-second ceiling instead.
    private var revivalBackoffTicks = 1
    private var ticksSinceRevival = 0
    private let maxRevivalBackoffTicks = 30

    /// Consecutive ticks with nothing else playing. Debounced, because the gap
    /// between two tracks is not the user having stopped listening.
    private var idlePlaybackTicks = 0
    private let playbackIdleConfirmTicks = 5

    /// Three-second window at 10 Hz.
    private var spikeFilter = SpikeFilter(windowSize: 31, spikeRatio: 2.5, minimumMargin: 1.0)

    private var routeChangeToken: NSObjectProtocol?

    // MARK: - Lifecycle

    init(audioManager: AudioManager,
         volumeController: VolumeController,
         calibrationStore: CalibrationStore,
         settings: SettingsStore) {
        self.audioManager = audioManager
        self.volumeController = volumeController
        self.calibrationStore = calibrationStore
        self.settings = settings

        self.speedMode      = settings.speedMode
        self.rangeMode      = settings.rangeMode
        self.allowIncrease  = settings.allowIncrease
        self.allowDecrease  = settings.allowDecrease

        calibrationStore.$profile
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.calibrationStale = false
                self?.staleStreak = 0
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // A manual volume change re-anchors everything: the offset goes to
        // zero and the baseline is re-measured. See VolumeController.
        volumeController.$userAdjustmentCount
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleUserVolumeAdjustment()
            }
            .store(in: &cancellables)

        $speedMode.dropFirst()
            .sink { [weak settings] v in settings?.speedMode = v }
            .store(in: &cancellables)
        $rangeMode.dropFirst()
            .sink { [weak self, weak settings] v in
                settings?.rangeMode = v
                // Tightening the range must take effect immediately, not
                // whenever the loop happens to drift back inside it.
                self?.clampOffsetToRange(v.maxOffsetDB)
            }
            .store(in: &cancellables)
        $allowIncrease.dropFirst()
            .sink { [weak settings] v in settings?.allowIncrease = v }
            .store(in: &cancellables)
        $allowDecrease.dropFirst()
            .sink { [weak settings] v in settings?.allowDecrease = v }
            .store(in: &cancellables)
        $isActive.dropFirst()
            .sink { [weak settings] v in settings?.wasActive = v }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func start() {
        guard !isActive else { return }
        lastStartFailure = nil

        guard audioManager.permissionGranted else {
            lastStartFailure = "Microphone access is required."
            return
        }
        guard !CalibrationManager.isCalibrating else {
            lastStartFailure = "Calibration is running."
            return
        }

        // Acquiring the session is what makes ENVO's presence audible to the
        // rest of the system, so it happens here — on an explicit start —
        // and never at launch.
        guard AudioSessionController.shared.acquire(.engine) else {
            lastStartFailure = "Could not start the audio session."
            return
        }

        BackgroundAudioHandler.shared.enableBackgroundAudio()
        volumeController.captureBaseVolume()
        audioManager.startMonitoring()
        registerRouteObserver()

        resetControlState()
        selfCoupling.prior = AudioSessionController.shared.selfCouplingPrior

        engineTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = engineTimer {
            RunLoop.main.add(t, forMode: .common)
        }

        isActive = true
        Log.engine.info("ENVO started. Taper span \(self.activeTaper.spanDB, format: .fixed(precision: 1)) dB, calibrated=\(self.isCalibrated).")
    }

    deinit {
        removeRouteObserver()
    }

    func stop() {
        engineTimer?.invalidate()
        engineTimer = nil
        removeRouteObserver()
        audioManager.stopMonitoring()

        volumeController.clearOffset()
        BackgroundAudioHandler.shared.disableBackgroundAudio()
        AudioSessionController.shared.release(.engine)

        resetControlState()
        isActive = false
        levelHistory = []
        estimatedAmbientDB = nil
        calibrationStale = false
    }

    private func resetControlState() {
        ambientSamplesDB.removeAll()
        recentRawDB.removeAll()
        ambientTracker.reset()
        spikeFilter.reset()
        selfCoupling.reset()
        obstructionDetector.reset()
        warmupTicks = 0
        baselineAmbientDB = 0
        hasBaseline = false
        currentOffsetDB = 0
        currentSliderOffset = 0
        appliedSliderOffset = 0
        deliveredOffsetDB = 0
        staleStreak = 0
        deadMicTicks = 0
        revivalBackoffTicks = 1
        ticksSinceRevival = 0
        idlePlaybackTicks = 0
        isWaitingForPlayback = false
        isMicrophoneObstructed = false
        isInputClipping = false
    }

    /// The user moved the volume by hand. Their new position is the new
    /// definition of "correct", so the adjustment goes to zero and the room
    /// baseline is measured again from here.
    private func handleUserVolumeAdjustment() {
        guard isActive else { return }
        reanchor(reason: "user adjusted volume")
    }

    /// The output route changed — headphones in or out, a Bluetooth speaker
    /// connecting, AirPlay engaging.
    ///
    /// This invalidates almost everything the loop is holding, because the
    /// *acoustic path itself* changed:
    ///
    ///   * The baseline was measured with the old path's playback bleeding
    ///     into the microphone. Switch from the built-in speaker to
    ///     headphones and that bleed vanishes, so the noise floor drops for a
    ///     reason that has nothing to do with the room — and ENVO would read
    ///     it as "it got quieter" and turn the volume DOWN. Unplugging does
    ///     the reverse and turns it UP.
    ///   * Each route remembers its own system volume, so the baseline volume
    ///     is wrong too.
    ///   * A measured taper describes the route it was measured on;
    ///     `applicableTaper` falls back to the default on any other route.
    ///
    /// Deliberately does NOT write the slider on the way out: the old offset
    /// is meaningless on the new path, and restoring it would fight the volume
    /// iOS has just selected for that route.
    private func handleRouteChange() {
        guard isActive else { return }
        volumeController.captureBaseVolume()
        reanchor(reason: "output route changed")

        // How much of the microphone's floor is our own playback is a property
        // of the acoustic path. Headphones couple essentially nothing; a
        // speaker on the same desk couples nearly everything. Carrying the old
        // number across a route change would be worse than starting again from
        // what the new route implies.
        selfCoupling.reset()
        selfCoupling.prior = AudioSessionController.shared.selfCouplingPrior
        obstructionDetector.reset()
    }

    /// Drop the adjustment and re-measure the room from here.
    private func reanchor(reason: String) {
        currentOffsetDB = 0
        currentSliderOffset = 0
        appliedSliderOffset = 0
        deliveredOffsetDB = 0
        hasBaseline = false
        warmupTicks = 0
        ambientTracker.reset()
        spikeFilter.reset()
        recentRawDB.removeAll()
        // The delivered offset jumps to zero here without ENVO having stepped
        // anything, which would look like a probe it never made.
        selfCoupling.discardObservationInProgress()
        Log.engine.info("Re-anchoring (\(reason, privacy: .public)): adjustment zeroed, baseline re-measuring.")
    }

    private func registerRouteObserver() {
        guard routeChangeToken == nil else { return }
        routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, self.isActive,
                  let info = notification.userInfo,
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                self.handleRouteChange()
            default:
                // .categoryChange fires when we configure our own session, and
                // .routeConfigurationChange is often cosmetic. Neither means
                // the acoustic path moved.
                break
            }
        }
    }

    private func removeRouteObserver() {
        if let token = routeChangeToken {
            NotificationCenter.default.removeObserver(token)
            routeChangeToken = nil
        }
    }

    /// Bring an existing offset inside a newly-narrowed range immediately.
    private func clampOffsetToRange(_ rangeDB: Float) {
        guard isActive else { return }
        let limit = effectiveRangeDB(rangeDB)
        guard abs(currentOffsetDB) > limit else { return }
        currentOffsetDB = AcousticMath.clamp(currentOffsetDB, -limit, limit)
        applyCurrentOffset()
    }

    /// The range setting is honoured as chosen. Uncalibrated, the *accuracy*
    /// of the dB is limited by the assumed taper — which errs toward moving
    /// the slider too little — so there is no need to also narrow the range.
    private func effectiveRangeDB(_ requested: Float) -> Float { requested }

    // MARK: - Engine Loop

    private func tick() {
        guard isActive else { return }

        // Watchdog. `isRunning` alone is not enough: the engine can report
        // running while its tap has stopped delivering buffers, in which case
        // the readings freeze at their last value and steering on them would be
        // steering on a stale number. Hold the offset and try to revive, with
        // an exponential backoff so a persistent failure is not met with a
        // rebuild attempt every single second forever.
        guard audioManager.isReceivingAudio() else {
            deadMicTicks += 1
            ticksSinceRevival += 1
            if ticksSinceRevival >= revivalBackoffTicks {
                ticksSinceRevival = 0
                Log.audio.error("Mic not delivering audio (\(self.deadMicTicks) ticks); holding offset and rebuilding (next attempt in \(self.revivalBackoffTicks * 2)s).")
                revivalBackoffTicks = min(revivalBackoffTicks * 2, maxRevivalBackoffTicks)
                audioManager.stopMonitoring()
                audioManager.startMonitoring()
            }
            return
        }
        if deadMicTicks > 0 {
            deadMicTicks = 0
            revivalBackoffTicks = 1
            ticksSinceRevival = 0
        }

        // ── Drain the 10 Hz readings taken since the last tick ──
        let samples = audioManager.drainPendingSamples()
        guard !samples.isEmpty else { return }

        // Obstruction is judged on every reading, not once per tick: three
        // seconds of evidence at 1 Hz is three samples, which is not evidence.
        var obstructed = obstructionDetector.isObstructed
        for sample in samples {
            obstructed = obstructionDetector.ingest(levelDB: sample.controlLevelDB,
                                                    highFrequencyShare: sample.highFrequencyShare,
                                                    dt: sample.dt)
        }
        if obstructed != isMicrophoneObstructed {
            isMicrophoneObstructed = obstructed
            Log.engine.info("Microphone obstruction \(obstructed ? "detected" : "cleared", privacy: .public); adjustment \(obstructed ? "held" : "resumed", privacy: .public).")
        }

        // A clipped reading is compressed rather than wrong-by-an-offset: past
        // full scale the microphone stops tracking the room at all. Such
        // readings are kept out of the floor entirely rather than being fed in
        // as an underestimate.
        let usable = samples.filter { !$0.isClipping }
        isInputClipping = usable.count < samples.count

        // Both conditions mean the same thing: the number arriving is not a
        // measurement of the room. Hold, exactly as for a dead microphone.
        guard !obstructed, !usable.isEmpty else { return }

        // The staleness check wants the loudest instant in the window, so a
        // brief pause inside busy playback cannot masquerade as silence.
        checkCalibrationDrift(rawDB: usable.map(\.controlLevelDB).max() ?? usable[0].controlLevelDB)

        // Blunt transients in both directions before they reach the floor
        // estimate. The speech-likeness score is stored alongside the level it
        // was measured with, so the Lombard damper can later look at the
        // character of the readings that actually defined the floor rather than
        // of whatever happens to be arriving on this tick.
        for sample in usable {
            let despikedDB = spikeFilter.ingest(sample.controlLevelDB)
            ambientTracker.ingest(despikedDB, voiceShare: sample.speechLikeness)
        }

        let windowSamples = max(EnvoEngine.micSamplesPerSecond * 2,
                                Int(speedMode.windowSeconds) * EnvoEngine.micSamplesPerSecond)
        guard let floorDB = ambientTracker.floorDB(overLast: windowSamples) else {
            // Not enough history yet. Genuinely nothing to say.
            return
        }

        // ── Remove ENVO's own contribution ──
        // The measured floor includes whatever fraction of our own playback
        // survives into the quiet moments of the programme material. For speech
        // that is nearly nothing; for heavily limited music on a speaker it is
        // nearly everything, and the loop would be partly listening to itself.
        // The estimator learns that fraction from ENVO's own volume steps, and
        // reads zero until it has evidence.
        let deliveredDB = currentDeliveredOffsetDB()
        deliveredOffsetDB = deliveredDB
        // Capped well below the SLOW window: a sixty-tick wait is long enough
        // that a second step almost always interrupts the observation before it
        // completes, so a shorter, slightly pessimistic reading is worth more
        // than a perfect one that never arrives.
        selfCoupling.settleTicks = min(Int(speedMode.windowSeconds), 20)
        selfCoupling.ingest(floorDB: floorDB, deliveredDB: deliveredDB)
        let roomDB = selfCoupling.roomLevelDB(fromFloorDB: floorDB, deliveredDB: deliveredDB)

        var ambientDB = roomDB
        if hasBaseline,
           let floorVoiceShare = ambientTracker.voiceShareAtFloor(overLast: windowSamples) {
            ambientDB = lombardDamper.damp(ambientDB: roomDB,
                                           voiceShare: floorVoiceShare,
                                           baselineDB: baselineAmbientDB)
        }
        estimatedAmbientDB = ambientDB

        ambientSamplesDB.append(ambientDB)
        if ambientSamplesDB.count > maxSampleCount {
            ambientSamplesDB.removeFirst(ambientSamplesDB.count - maxSampleCount)
        }
        levelHistory = ambientSamplesDB.suffix(60).map(normalizedForDisplay)

        // Baseline: the room as it was when START was pressed.
        guard hasBaseline else {
            warmupTicks += 1
            if warmupTicks >= warmupCount {
                baselineAmbientDB = ambientDB
                hasBaseline = true
                Log.engine.info("Baseline anchored at \(self.baselineAmbientDB, format: .fixed(precision: 1)) dBFS.")
            }
            return
        }

        updatePlaybackIdleState()

        let noiseDeltaDB = ambientDB - baselineAmbientDB

        // ── Control law ──
        currentOffsetDB = controlLaw.nextOffsetDB(
            currentOffsetDB: currentOffsetDB,
            noiseDeltaDB: noiseDeltaDB,
            rangeDB: effectiveRangeDB(rangeMode.maxOffsetDB),
            allowIncrease: allowIncrease,
            allowDecrease: allowDecrease,
            dt: Float(sampleInterval)
        )

        applyCurrentOffset()
    }

    /// What the hardware is actually delivering, in dB relative to the user's
    /// baseline — the achieved slider position run back through the taper, not
    /// the offset ENVO asked for. The two differ by up to half a hardware step,
    /// and the self-coupling estimator is measuring a physical response, so it
    /// has to be told what physically happened.
    private func currentDeliveredOffsetDB() -> Float {
        activeTaper.deliveredDB(forDelta: volumeController.achievedOffset,
                                atBase: volumeController.baseVolume)
    }

    /// Track whether anything is actually playing.
    ///
    /// With nothing playing there is nothing to keep audible, and moving the
    /// system volume anyway means the user's next track starts at a level they
    /// did not choose — possibly in a different app, minutes later, with no
    /// visible reason. ENVO keeps measuring the room so it is warm when
    /// playback resumes; it simply stops writing, and hands the level back the
    /// moment it goes idle.
    private func updatePlaybackIdleState() {
        let playing = AVAudioSession.sharedInstance().isOtherAudioPlaying
        idlePlaybackTicks = playing ? 0 : idlePlaybackTicks + 1

        let idle = idlePlaybackTicks >= playbackIdleConfirmTicks
        guard idle != isWaitingForPlayback else { return }
        isWaitingForPlayback = idle

        if idle {
            // Hand the level back rather than leaving ENVO's offset parked on
            // the slider for whatever plays next.
            volumeController.clearOffset()
            appliedSliderOffset = 0
            Log.engine.info("Nothing playing; volume handed back, still measuring.")
        } else {
            Log.engine.info("Playback resumed; adaptation active again.")
        }
    }

    /// The loop's parameters.
    var controlLaw: ControlLaw {
        ControlLaw(
            gain: compensationGain,
            smoothing: offsetSmoothing,
            zeroHysteresisDB: zeroHysteresisDB,
            maxRateDBPerSecond: maxRateDBPerSecond
        )
    }

    /// Convert the dB intent into slider travel and hand it to the hardware.
    /// The single place where dB becomes slider movement.
    private func applyCurrentOffset() {
        let baseVol = volumeController.baseVolume
        let rangeDB = effectiveRangeDB(rangeMode.maxOffsetDB)

        let sliderOffset = activeTaper.volumeDelta(
            forDB: currentOffsetDB,
            atBase: baseVol,
            rangeDB: rangeDB,
            ceiling: safetyCeiling
        )
        currentSliderOffset = sliderOffset

        // Nothing is playing, or this route does not let anyone move its level.
        // The loop keeps running either way — it is the write that is pointless,
        // not the measurement — and resumes the moment the condition lifts.
        guard !isWaitingForPlayback, volumeController.isVolumeControlAvailable else { return }

        guard abs(sliderOffset - appliedSliderOffset) >= sliderChangeThreshold else { return }
        appliedSliderOffset = sliderOffset
        volumeController.applyOffset(sliderOffset)
        deliveredOffsetDB = currentDeliveredOffsetDB()
    }

    // MARK: - Calibration Staleness

    /// Watches for stretches where the microphone hears nothing beyond what we
    /// already believe the room to be — a pause between tracks, or silence
    /// from the playing app.
    ///
    /// Such a stretch gives a reading of the room with no playback mixed into
    /// it, which is the cleanest possible comparison against the silence floor
    /// recorded at calibration time. A persistent disagreement means the room
    /// is not the room that was calibrated, and the user is prompted to
    /// recalibrate.
    ///
    /// This used to be the sole source of ambient readings, back when the
    /// estimate came from subtracting the calibrated speaker level, and it was
    /// surfaced to the user as a GAP badge. `AmbientTracker` now reads the room
    /// floor continuously without needing playback to stop, so the badge was
    /// removed and this is the only remaining consumer.
    private func checkCalibrationDrift(rawDB: Float) {
        guard let profile = calibrationStore.profile, profile.isUsable else { return }

        recentRawDB.append(rawDB)
        if recentRawDB.count > gapWindowSize {
            recentRawDB.removeFirst(recentRawDB.count - gapWindowSize)
        }
        guard recentRawDB.count >= gapWindowSize else { return }

        // Compare against whichever is higher: the calibrated floor, or what
        // we currently believe the room to be. Otherwise a room that has got
        // louder since calibration never registers a quiet stretch at all.
        let reference = max(profile.silenceFloorDB,
                            hasBaseline ? baselineAmbientDB : profile.silenceFloorDB)

        // The MAXIMUM over the window, so a single loud instant anywhere in it
        // disqualifies the stretch. A mean would let a brief pause inside busy
        // playback masquerade as silence.
        let recentMax = recentRawDB.max() ?? rawDB
        guard recentMax <= reference + gapMarginDB else { return }

        updateStaleness(observedFloorDB: AcousticMath.meanDB(recentRawDB),
                        profile: profile)
    }

    /// Flag the calibration as stale only after several consecutive clean
    /// readings disagree with it, so a single odd measurement cannot make the
    /// button label flicker between CALIBRATED and RECAL?.
    private func updateStaleness(observedFloorDB: Float, profile: CalibrationProfile) {
        let drift = abs(observedFloorDB - profile.silenceFloorDB)
        if drift > staleThresholdDB {
            staleStreak += 1
            if staleStreak >= staleConfirmations, !calibrationStale {
                calibrationStale = true
            }
        } else {
            staleStreak = 0
            if calibrationStale { calibrationStale = false }
        }
    }

    // MARK: - Display Accessors

    private func normalizedForDisplay(_ dbfs: Float) -> Float {
        let lo = AudioManager.displayFloorDB
        let hi = AudioManager.displayCeilingDB
        return AcousticMath.clamp((dbfs - lo) / (hi - lo), 0, 1)
    }

    /// Normalized level for the visualizer.
    var visualizerLevel: Float {
        guard let ambient = estimatedAmbientDB else { return 0 }
        return normalizedForDisplay(ambient)
    }

    /// Adjustment in dB, formatted for the readout — with a sign, and always
    /// alongside a "dB" unit in the UI.
    ///
    /// Shows what the hardware **delivered**, not what the control law asked
    /// for. iOS quantizes the system volume to steps worth roughly 3 dB each,
    /// so the intent and the result routinely differ by more than a decibel;
    /// printing the intent meant the app's largest number described a change the
    /// user could not hear, in either direction.
    var displayOffset: String {
        let rounded = (deliveredOffsetDB * 10).rounded() / 10
        if rounded > 0.05 { return String(format: "+%.1f", rounded) }
        if rounded < -0.05 { return String(format: "%.1f", rounded) }
        return "0.0"
    }

    /// How much of the measured floor the estimator currently attributes to
    /// ENVO's own playback, 0…1. Diagnostic.
    var selfCouplingEstimate: Float { selfCoupling.coupling }

    /// Approximate room level in dB SPL, or nil when not measurable.
    var displayAmbient: Int? {
        guard let ambient = estimatedAmbientDB else { return nil }
        return AudioManager.approximateSPL(fromDBFS: ambient)
    }
}
