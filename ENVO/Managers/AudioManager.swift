import Foundation
import AVFoundation
import Accelerate
import Combine

/// One drained microphone observation.
///
/// The engine ticks at 1 Hz but reads the microphone at 10 Hz, because the
/// statistics it computes need samples, not ticks. `AmbientTracker`'s L90 over a
/// ten-second window is the lowest of ten readings when sampled once per second
/// — an estimator with several decibels of variance produced by nothing but
/// chance. At 10 Hz the same window carries a hundred readings.
///
/// Everything the engine needs about a moment is carried together, so the level
/// and the spectral descriptors measured alongside it can never drift apart.
struct AmbientSample: Equatable {
    /// Masking-weighted level in dBFS — the signal the control loop steers on.
    let controlLevelDB: Float
    /// A-weighted broadband level in dBFS. Diagnostic: this is the number that
    /// is comparable to a dB(A) sound level meter.
    let aWeightedLevelDB: Float
    /// 0…1 estimate of how speech-like the room is right now.
    let speechLikeness: Float
    /// The spectral half of that score, on its own. Diagnostic: when the damper
    /// behaves unexpectedly, the first question is always which of the two
    /// measurements moved.
    let spectralSpeechScore: Float
    /// The temporal half, as raw modulation depth in dB rather than a score, so
    /// the ramp constants can be retuned against real rooms.
    let modulationDepthDB: Float
    /// Share of band energy above 1 kHz. Feeds obstruction detection.
    let highFrequencyShare: Float
    /// Octave-band levels in dBFS, low to high, energy-averaged over this
    /// sample's interval. Diagnostic only.
    let bandLevelsDB: [Float]
    /// The input hit full scale during this interval, so the level is a floor
    /// on the truth rather than the truth.
    let isClipping: Bool
    /// Seconds this sample represents.
    let dt: Float
}

/// Audio-thread-owned processing state.
///
/// A class, and captured **strongly** by the input tap, on purpose. The
/// previous code kept this state on `AudioManager` and cleared it from the main
/// thread during teardown, while `removeTap(onBus:)` gives no guarantee that a
/// callback is not already running. Releasing a filter's coefficient array out
/// from under a buffer being processed is a data race on a heap object, and the
/// failure mode is a crash rather than a wrong number. Holding it from the
/// closure means an in-flight callback keeps the object alive until it returns,
/// and teardown merely drops the manager's own reference.
private final class LevelProcessor {

    let sampleRate: Double
    var aWeighting: AWeightingFilter
    var bands: OctaveBandAnalyzer
    var modulation = ModulationDetector()

    /// IEC 61672 Fast time weighting: a 125 ms exponential average in the power
    /// domain. The previous smoothing coefficient (0.3 retained per buffer)
    /// worked out to a ~19 ms time constant, so each reading the engine took was
    /// effectively an instantaneous snapshot of one twentieth of a second rather
    /// than an integrated level. Fast is the standard short integration and is
    /// what makes a percentile over the window mean something.
    static let fastTimeConstant: Float = 0.125

    var smoothedControlDB: Float = AcousticMath.silenceDB
    var smoothedAWeightedDB: Float = AcousticMath.silenceDB
    var seeded = false

    var speechLikeness: Float = 0
    var spectralSpeechScore: Float = 0
    var highFrequencyShare: Float = 0

    /// Band **power** accumulated across the publish interval, and the buffer
    /// count behind it.
    ///
    /// The band columns used to be an instantaneous snapshot of whichever buffer
    /// happened to be last before a publish. A device log caught the failure
    /// exactly: one tick reported every band 26 dB below its neighbours while the
    /// smoothed control level barely moved, because a single near-silent 21 ms
    /// buffer landed on the sampling instant. Averaging the power over the whole
    /// interval makes the bands an Leq like every other level in the row, and
    /// makes the spectral ratios derived from them steady rather than jittery.
    var bandPowerAccum = [Float](repeating: 0, count: OctaveBandAnalyzer.centerFrequencies.count)
    var bandAccumCount = 0

    /// Sticky within a publish interval: one clipped buffer taints the whole
    /// reading, and a peak that just touched full scale is usually accompanied
    /// by neighbours that nearly did.
    var sawClipping = false

    var lastPublish: CFAbsoluteTime = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.aWeighting = AWeightingFilter(sampleRate: sampleRate)
        self.bands = OctaveBandAnalyzer(sampleRate: sampleRate)
    }
}

/// Manages microphone input for ambient noise level measurement.
/// IMPORTANT: No audio data is recorded or stored. Only instantaneous
/// power levels are read from the audio engine's input node.
final class AudioManager: ObservableObject {

    // MARK: - Published State

    /// Masking-weighted level in dBFS. **This is the engine's primary signal**,
    /// and since it is also what the UI displays, what the user sees is what the
    /// loop acts on. See `MaskingWeighting` for why this is not A-weighted.
    @Published private(set) var levelDB: Float = AcousticMath.silenceDB

    /// A-weighted broadband level in dBFS. Not used for control — published so
    /// the calibration log can report a figure that is directly comparable to a
    /// dB(A) sound level meter, which the masking-weighted number is not.
    @Published private(set) var aWeightedLevelDB: Float = AcousticMath.silenceDB

    /// Display-only 0…1 mapping of `levelDB`. Never use this for arithmetic:
    /// it is linear in *decibels*, so multiplying or ratioing it is
    /// meaningless. Doing exactly that is what broke gap detection and the
    /// calibrated ambient estimate.
    @Published private(set) var normalizedLevel: Float = 0.0

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var permissionGranted: Bool = false

    /// Tri-state mic permission so the UI can show a distinct empty state
    /// for an explicit denial versus a not-yet-asked state.
    enum PermissionState { case undetermined, granted, denied }
    @Published private(set) var permissionState: PermissionState = .undetermined

    /// 0…1 estimate of how speech-like the ambient noise is, combining a
    /// spectral and a temporal measurement. Used by the engine for anti-Lombard
    /// correction so people talking louder doesn't drive the offset upward.
    ///
    /// Replaces the previous `voiceBandShare`, which compared the energy in four
    /// 43 Hz-wide Goertzel bins against three others and called the ratio a
    /// band share. That measurement was blind to everything between the probe
    /// frequencies, leaked low-frequency energy into every bin through an
    /// unwindowed transform, and could not distinguish speech from any other
    /// broadband sound. See `MaskingWeighting.speechBandShare` and
    /// `ModulationDetector`.
    @Published private(set) var speechLikeness: Float = 0.0

    /// Most recent octave-band levels in dBFS, low to high. Diagnostic only —
    /// nothing steers on it, but it is what makes the masking weighting and the
    /// obstruction detector checkable against a real room rather than trusted.
    @Published private(set) var latestBandLevelsDB: [Float] = []

    /// True when the input recently hit full scale. An iPhone microphone clips
    /// somewhere around 105–110 dB SPL, and past that point the reading
    /// compresses and stops tracking the room — exactly where a volume
    /// controller most needs to be honest about not knowing.
    @Published private(set) var isClipping: Bool = false

    /// Readings taken since the engine last drained, oldest first.
    ///
    /// Appended on the main thread from the publish block and drained on the
    /// main thread by the engine tick, so no locking is involved and the audio
    /// thread is never blocked.
    ///
    /// Deliberately **not** `@Published`: nothing observes it, and publishing it
    /// would fire `objectWillChange` ten times a second, re-rendering every view
    /// that holds `AudioManager` as an `EnvironmentObject` for data none of them
    /// read.
    private var pendingSamples: [AmbientSample] = []

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var processor: LevelProcessor?

    /// Synchronous flag separate from the @Published isMonitoring.
    /// Prevents double-start races where two callers pass the guard
    /// before the main-async @Published write lands.
    private let stateQueue = DispatchQueue(label: "envo.audiomanager.state")
    private var isStarting: Bool = false

    /// Display range for `normalizedLevel`.
    ///
    /// Shifted down relative to the old A-weighted broadband range. The control
    /// level is a weighted average of *octave-band* levels, and a broadband room
    /// spreads its energy over roughly eight octaves, so any one band sits about
    /// 9 dB below the broadband figure. The visualizer would otherwise spend its
    /// life in the bottom fifth of its scale.
    static let displayFloorDB: Float = -90.0
    static let displayCeilingDB: Float = -20.0

    /// Approximate dB SPL of a full-scale **control level** reading.
    ///
    /// Turning dBFS into an SPL figure requires knowing the microphone's
    /// absolute sensitivity, which iOS does not expose and which varies by
    /// device and by route. **This constant is an estimate, not a
    /// calibration**, and the displayed number should be read as
    /// "approximately", ±10 dB.
    ///
    /// **Measured on device**, not derived: an iPhone 14 reading rooms verified
    /// at 60 / 70 / 80 dB(A) on a sound level meter implied offsets of 103.3,
    /// 106.6 and 107.6. The value is not constant because iOS compresses the
    /// input scale (see `EnvoEngine.compensationGain`), so the figure below is
    /// chosen to be right in the middle of the range people actually listen in
    /// — roughly 55–75 dB(A) — and reads a few dB low in very loud rooms.
    ///
    /// Was 117.0, a reasoned guess, which put every reading about 12 dB high.
    static let fullScaleSPL: Float = 105.0

    /// Same idea for the A-weighted diagnostic level, which unlike the control
    /// level *is* directly comparable to any dB(A) meter. Same device
    /// measurement: implied offsets of 96.7, 99.9 and 101.1 at 60 / 70 / 80
    /// dB(A). Was 105.0.
    static let aWeightedFullScaleSPL: Float = 98.0

    /// Audio-thread-only. Gates the main-thread @Published writes to
    /// ~10 Hz — the rate the engine samples at, and plenty for the 30 fps
    /// visualizer (which has its own decay smoothing) — instead of publishing
    /// at buffer rate (~45 Hz) even while backgrounded.
    private let publishInterval: CFAbsoluteTime = 0.1

    /// Cap on the undrained queue, so a stalled engine cannot grow it without
    /// bound. Ten seconds of readings is far more than a tick ever needs.
    private let maxPendingSamples = 100

    /// Wall-clock time of the last buffer delivered by the input tap.
    /// `AVAudioEngine.isRunning` can report true while no buffers arrive;
    /// this is the signal that actually proves the mic is alive.
    private var lastBufferTime: CFAbsoluteTime = 0

    /// Rebuilds the engine when the input configuration changes underneath
    /// it (headphone plug/unplug, route format change). Without this the
    /// engine silently stops and readings freeze at their last value.
    private var configChangeToken: NSObjectProtocol?
    private var mediaResetToken: NSObjectProtocol?

    // MARK: - Lifecycle

    init() {
        // The media subsystem can be torn down out from under us (rare but
        // real). All engine objects are invalid afterwards; rebuild if we
        // were monitoring. Delayed so session owners (BackgroundAudioHandler)
        // get to restore the category first — and if they lose the race,
        // the engine watchdog revives us a tick later anyway.
        mediaResetToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.audioEngine != nil else { return }
            self.stopMonitoring()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startMonitoring()
            }
        }
    }

    deinit {
        // Only the synchronous teardown here. stopMonitoring() dispatches
        // async closures that capture self — illegal during deinit.
        tearDownEngine()
        if let token = mediaResetToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// True while the underlying engine is actually delivering input.
    /// `isMonitoring` alone can lie: a route change or interruption stops
    /// the engine without any callback of ours running. The EnvoEngine
    /// tick uses this as a watchdog before acting on readings.
    var isEngineRunning: Bool {
        audioEngine?.isRunning ?? false
    }

    /// Stronger liveness check than `isEngineRunning`: the tap has actually
    /// delivered a buffer recently. A running engine whose tap has gone
    /// silent still freezes the readings at their last value, and steering
    /// the volume on a frozen reading is exactly what the watchdog exists to
    /// prevent.
    func isReceivingAudio(within seconds: CFAbsoluteTime = 1.5) -> Bool {
        guard isEngineRunning, lastBufferTime > 0 else { return false }
        return CFAbsoluteTimeGetCurrent() - lastBufferTime <= seconds
    }

    // MARK: - Sample queue

    /// Take everything measured since the last call. Main thread only.
    func drainPendingSamples() -> [AmbientSample] {
        guard !pendingSamples.isEmpty else { return [] }
        let drained = pendingSamples
        pendingSamples = []
        return drained
    }

    // MARK: - Setup

    func prepare() {
        refreshPermissionState()
    }

    // MARK: - Permission

    /// Reads the current permission WITHOUT triggering the system prompt.
    /// Used at launch so the dialog doesn't fire underneath onboarding;
    /// the actual request happens on the first START (checkPermission).
    func refreshPermissionState() {
        let apply = { (granted: Bool, state: PermissionState) in
            DispatchQueue.main.async {
                self.permissionGranted = granted
                self.permissionState = state
            }
        }
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:      apply(true, .granted)
            case .denied:       apply(false, .denied)
            case .undetermined: apply(false, .undetermined)
            @unknown default:   apply(false, .undetermined)
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:      apply(true, .granted)
            case .denied:       apply(false, .denied)
            case .undetermined: apply(false, .undetermined)
            @unknown default:   apply(false, .undetermined)
            }
        }
    }

    /// Resolves the mic permission state.
    /// If currently undetermined, requests it and calls `completion` with the result
    /// AFTER the user has answered. If already determined, calls back immediately.
    func checkPermission(completion: ((Bool) -> Void)? = nil) {
        let applyGranted = { (granted: Bool, state: PermissionState) in
            DispatchQueue.main.async {
                self.permissionGranted = granted
                self.permissionState = state
                completion?(granted)
            }
        }

        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                applyGranted(true, .granted)
            case .denied:
                applyGranted(false, .denied)
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        self?.permissionGranted = granted
                        self?.permissionState = granted ? .granted : .denied
                        completion?(granted)
                    }
                }
            @unknown default:
                applyGranted(false, .denied)
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                applyGranted(true, .granted)
            case .denied:
                applyGranted(false, .denied)
            case .undetermined:
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        self?.permissionGranted = granted
                        self?.permissionState = granted ? .granted : .denied
                        completion?(granted)
                    }
                }
            @unknown default:
                applyGranted(false, .denied)
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard permissionGranted else { return }

        // Synchronous claim guards against double-starts that the @Published
        // isMonitoring flag (set via async dispatch) can't catch in time.
        let canStart: Bool = stateQueue.sync {
            if isStarting || audioEngine != nil { return false }
            isStarting = true
            return true
        }
        guard canStart else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.audio.error("Invalid audio format from input node.")
            stateQueue.sync { isStarting = false }
            return
        }

        // Built once per engine, at the route's rate. Captured strongly by the
        // tap below so teardown cannot pull it out from under a running buffer.
        let processor = LevelProcessor(sampleRate: format.sampleRate)
        self.processor = processor

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer, using: processor)
        }

        do {
            try engine.start()
            self.audioEngine = engine

            // Headphone connect/disconnect changes the input node's format;
            // the engine stops itself and posts this. Rebuild with the new
            // route's format or the mic stays silently dead.
            configChangeToken = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, self.audioEngine != nil else { return }
                Log.audio.info("Engine configuration changed (route change); rebuilding input engine.")
                self.stopMonitoring()
                self.startMonitoring()
            }

            DispatchQueue.main.async {
                self.isMonitoring = true
            }
        } catch {
            Log.audio.error("AudioEngine start failed: \(error.localizedDescription, privacy: .public)")
            inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            self.processor = nil
        }
        stateQueue.sync { isStarting = false }
    }

    func stopMonitoring() {
        let hadEngine = audioEngine != nil
        tearDownEngine()

        DispatchQueue.main.async {
            self.isMonitoring = false
            if hadEngine {
                self.levelDB = AcousticMath.silenceDB
                self.aWeightedLevelDB = AcousticMath.silenceDB
                self.normalizedLevel = 0.0
                self.speechLikeness = 0.0
                self.isClipping = false
                self.pendingSamples = []
            }
        }
    }

    /// Synchronous, idempotent engine teardown. Safe to call from deinit.
    private func tearDownEngine() {
        if let token = configChangeToken {
            NotificationCenter.default.removeObserver(token)
            configChangeToken = nil
        }
        guard let engine = audioEngine else { return }
        // Remove the tap first so no *new* buffers arrive. A callback already
        // running keeps the processor alive through its own strong capture, so
        // dropping our reference here is safe even mid-buffer.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        processor = nil
        lastBufferTime = 0
    }

    // MARK: - Audio Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer, using p: LevelProcessor) {
        guard let channelData = buffer.floatChannelData else { return }

        let samples = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let dt = Float(frameLength) / Float(p.sampleRate)
        guard dt > 0 else { return }

        // Peak first: clipping invalidates everything downstream, and the
        // cheapest possible check is worth doing before the filtering.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameLength))
        guard peak.isFinite else { return }
        if peak >= 0.99 { p.sawClipping = true }

        // ── Octave-band analysis: the control signal ──
        // The masking-weighted level, not a broadband one. Ears are less
        // sensitive at low frequencies, but low-frequency noise *masks upward*
        // into the midrange far more than any loudness weighting suggests —
        // which is why a bus or an aircraft cabin destroys intelligibility while
        // reading unremarkably on a dB(A) meter. See MaskingWeighting.
        p.bands.analyze(samples, count: frameLength)
        let controlDB = MaskingWeighting.maskingLevelDB(p.bands.bandLevelsDB,
                                                        activeBandCount: p.bands.activeBandCount)

        // The control level stays per-buffer, because the 125 ms Fast weighting
        // below is the thing that integrates it. The spectral descriptors do not:
        // they are ratios, and a ratio of one 21 ms frame is needlessly noisy, so
        // the power is accumulated and they are derived once per publish.
        for i in 0..<p.bands.activeBandCount {
            p.bandPowerAccum[i] += AcousticMath.power(fromDB: p.bands.bandLevelsDB[i])
        }
        p.bandAccumCount += 1

        // ── A-weighted broadband: the diagnostic ──
        // Accumulated in place rather than filtered into a scratch buffer, so
        // there is no allocation on the audio thread.
        var sumSquares: Float = 0
        for i in 0..<frameLength {
            let weighted = p.aWeighting.process(samples[i])
            sumSquares += weighted * weighted
        }
        let aRMS = (sumSquares / Float(frameLength)).squareRoot()
        let aDB: Float = aRMS > 0 ? max(20.0 * log10f(aRMS), AcousticMath.silenceDB)
                                  : AcousticMath.silenceDB

        guard controlDB.isFinite, aDB.isFinite else { return }

        lastBufferTime = CFAbsoluteTimeGetCurrent()

        // ── Fast (125 ms) time weighting, in the power domain ──
        let retention = expf(-dt / LevelProcessor.fastTimeConstant)
        if !p.seeded {
            // Seed rather than ramp: starting the average at digital silence
            // made the first readings after every start (and after every mic
            // rebuild) artificially low.
            p.smoothedControlDB = controlDB
            p.smoothedAWeightedDB = aDB
            p.seeded = true
        } else {
            p.smoothedControlDB = AcousticMath.emaDB(current: p.smoothedControlDB,
                                                     sample: controlDB,
                                                     retention: retention)
            p.smoothedAWeightedDB = AcousticMath.emaDB(current: p.smoothedAWeightedDB,
                                                       sample: aDB,
                                                       retention: retention)
        }

        // ── Speech likeness: spectral shape and syllabic modulation ──
        // Fed at buffer rate, not at the publish rate: resolving a 2–8 Hz
        // envelope needs samples well above 16 Hz.
        //
        // Fed the *unsmoothed* level, deliberately. The Fast time weighting is a
        // 125 ms one-pole, which attenuates a 4 Hz envelope component to about
        // 30% — it would remove most of the very modulation this is trying to
        // measure. The per-buffer level is a ~21 ms integration, which passes
        // the syllabic band essentially intact at the cost of a little more
        // statistical scatter; `ModulationDetector`'s floor is set for that.
        p.modulation.ingest(levelDB: controlDB, dt: dt)

        // Smoothing and modulation state above update on every buffer; only the
        // main-thread publish is rate-limited.
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - p.lastPublish
        guard elapsed >= publishInterval else { return }
        let interval = p.lastPublish > 0 ? Float(elapsed) : Float(publishInterval)
        p.lastPublish = now

        // ── Derive the spectral descriptors from the interval's mean power ──
        var meanBands = [Float](repeating: AcousticMath.silenceDB,
                                count: OctaveBandAnalyzer.centerFrequencies.count)
        if p.bandAccumCount > 0 {
            let n = Float(p.bandAccumCount)
            for i in 0..<p.bands.activeBandCount {
                meanBands[i] = AcousticMath.dB(fromPower: p.bandPowerAccum[i] / n)
            }
        }
        for i in 0..<p.bandPowerAccum.count { p.bandPowerAccum[i] = 0 }
        p.bandAccumCount = 0

        p.spectralSpeechScore = spectralSpeechScore(
            MaskingWeighting.speechBandShare(meanBands, activeBandCount: p.bands.activeBandCount)
        )
        p.highFrequencyShare = MaskingWeighting.highFrequencyShare(
            meanBands, activeBandCount: p.bands.activeBandCount
        )
        // Averaged rather than multiplied, because the two measurements fail in
        // opposite situations and neither should be able to veto the other.
        // Many-talker babble averages toward steady noise and loses its
        // modulation but keeps its speech-shaped spectrum; a broadband hiss in a
        // room with no low end reads spectrally speech-like but does not
        // modulate. Requiring both would miss the first; accepting either would
        // fire on the second.
        p.speechLikeness = AcousticMath.clamp(
            0.5 * p.spectralSpeechScore + 0.5 * p.modulation.score, 0, 1
        )

        let sample = AmbientSample(
            controlLevelDB: p.smoothedControlDB,
            aWeightedLevelDB: p.smoothedAWeightedDB,
            speechLikeness: p.speechLikeness,
            spectralSpeechScore: p.spectralSpeechScore,
            modulationDepthDB: p.modulation.depthDB,
            highFrequencyShare: p.highFrequencyShare,
            bandLevelsDB: meanBands,
            isClipping: p.sawClipping,
            dt: interval
        )
        p.sawClipping = false

        let clamped = min(max(sample.controlLevelDB, AudioManager.displayFloorDB),
                          AudioManager.displayCeilingDB)
        let normalized = (clamped - AudioManager.displayFloorDB)
            / (AudioManager.displayCeilingDB - AudioManager.displayFloorDB)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.levelDB = sample.controlLevelDB
            self.aWeightedLevelDB = sample.aWeightedLevelDB
            self.normalizedLevel = normalized
            self.speechLikeness = sample.speechLikeness
            self.isClipping = sample.isClipping
            self.latestBandLevelsDB = sample.bandLevelsDB

            self.pendingSamples.append(sample)
            if self.pendingSamples.count > self.maxPendingSamples {
                self.pendingSamples.removeFirst(self.pendingSamples.count - self.maxPendingSamples)
            }
        }
    }

    /// Maps the 250 Hz–2 kHz energy share onto 0…1.
    ///
    /// CALIBRATED AGAINST MEASURED DEVICE DATA, NOT GUESSES
    /// ----------------------------------------------------
    /// The first version of this ramp ran 0.25 → 0.55, on the reasoning that
    /// traffic sits near 0.1–0.2 and babble near 0.5–0.6. The traffic figure was
    /// right; the babble figure was badly wrong, and so was the assumption about
    /// where *neutral* noise sits.
    ///
    /// A device log settled it. Broadband pink noise, measured on an iPhone 14
    /// through its own microphone, produces a share of **0.55–0.61** — because
    /// four of the six bands are in the numerator, so any broadband signal starts
    /// over half way up. The old ramp therefore pinned plain pink noise at a
    /// score of **1.00**, which combined with a modulation score of ~0 to put
    /// `speechLikeness` at 0.46 — just past `LombardDamper.engageShare` of 0.45.
    /// ENVO was quietly damping its response to ordinary broadband noise.
    ///
    /// Anchors now in use, from real measurement where available:
    ///
    ///     traffic / ventilation      0.10   (synthetic, LF-dominated)
    ///     broadband pink, measured   0.55 – 0.61
    ///     speech babble              0.90 – 0.98
    ///
    /// So the ramp brackets the gap between neutral and speech-shaped, not
    /// between LF-dominated and neutral.
    ///
    /// The upper anchor is still the weaker of the two — it comes from a
    /// speech-shaped synthetic rather than a room full of people. S2 in
    /// TESTING.md measures it directly. If real babble lands nearer 0.70 than
    /// 0.90 this ramp wants lowering, and note the failure direction is safe
    /// either way: the modulation half of the score carries the detection on its
    /// own, which is exactly why the two are averaged rather than multiplied.
    private func spectralSpeechScore(_ share: Float) -> Float {
        AcousticMath.clamp((share - 0.65) / (0.90 - 0.65), 0, 1)
    }

    // MARK: - Display

    /// Rough dB SPL of the control level, for the on-screen readout.
    var approximateDB: Int {
        guard isMonitoring, levelDB > AcousticMath.silenceDB else { return 0 }
        return Int((levelDB + AudioManager.fullScaleSPL).rounded())
    }

    static func approximateSPL(fromDBFS dbfs: Float) -> Int {
        Int((dbfs + fullScaleSPL).rounded())
    }

    /// dB(A) equivalent of an A-weighted reading — the figure that is
    /// comparable to a sound level meter. Used in the calibration log.
    static func approximateAWeightedSPL(fromDBFS dbfs: Float) -> Int {
        Int((dbfs + aWeightedFullScaleSPL).rounded())
    }
}
