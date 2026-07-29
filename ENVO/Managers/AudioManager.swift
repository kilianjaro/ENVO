import Foundation
import AVFoundation
import Accelerate
import Combine

/// Manages microphone input for ambient noise level measurement.
/// IMPORTANT: No audio data is recorded or stored. Only instantaneous
/// power levels are read from the audio engine's input node.
final class AudioManager: ObservableObject {

    // MARK: - Published State

    /// Smoothed input level in dBFS. **This is the engine's primary signal.**
    /// Everything that reasons about loudness works in dB from here on; the
    /// normalized 0…1 value below is for drawing only.
    @Published private(set) var levelDB: Float = AcousticMath.silenceDB

    /// Deprecated alias kept for the visualizer's history buffer.
    @Published private(set) var currentLevel: Float = AcousticMath.silenceDB

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

    /// Share of total energy in the 300–3000 Hz voice band, smoothed.
    /// Used by the engine for anti-Lombard correction so people talking
    /// over the music doesn't drive the offset upward.
    @Published private(set) var voiceBandShare: Float = 0.0

    // MARK: - Private

    private var audioEngine: AVAudioEngine?

    /// Synchronous flag separate from the @Published isMonitoring.
    /// Prevents double-start races where two callers pass the guard
    /// before the main-async @Published write lands.
    private let stateQueue = DispatchQueue(label: "envo.audiomanager.state")
    private var isStarting: Bool = false

    /// Weight retained from the previous sample when smoothing, applied in
    /// the power domain (see AcousticMath.emaDB).
    private let smoothingFactor: Float = 0.3

    /// Display range for `normalizedLevel`.
    ///
    /// The old floor of −60 dBFS was the single most damaging constant in
    /// the app: a quiet room measures −65…−80 dBFS on an iPhone mic, so
    /// every reading in a quiet room clamped to exactly 0. Calibration then
    /// recorded a silence floor of zero and zero device contribution for the
    /// lower volume steps, and gap detection fired on every tick.
    static let displayFloorDB: Float = -80.0
    static let displayCeilingDB: Float = -10.0

    /// Approximate dB(A) SPL of a full-scale reading on the built-in mic.
    ///
    /// Turning dBFS into an SPL figure requires knowing the microphone's
    /// absolute sensitivity, which iOS does not expose and which varies by
    /// device and by route. **This constant is an estimate, not a
    /// calibration**, and the displayed number should be read as
    /// "approximately", ±10 dB.
    ///
    /// Lowered from 120: with the old value a normal room read around 70 dB
    /// SPL, which is nearer a busy street than a living room. What the readout
    /// can be trusted for is *change* — it is 1:1 in dB, so a room that gets
    /// 10 dB louder moves the number by 10.
    static let fullScaleSPL: Float = 105.0

    /// Rebuilt whenever the input sample rate changes (route change, engine
    /// rebuild). Audio-thread-only.
    private var aWeighting: AWeightingFilter?

    private var smoothedLevel: Float = AcousticMath.silenceDB
    private var hasSeededLevel = false
    private var smoothedVoiceShare: Float = 0.0
    private let voiceShareSmoothing: Float = 0.85

    /// Wall-clock time of the last buffer delivered by the input tap.
    /// `AVAudioEngine.isRunning` can report true while no buffers arrive;
    /// this is the signal that actually proves the mic is alive.
    private var lastBufferTime: CFAbsoluteTime = 0

    /// Audio-thread-only. Gates the main-thread @Published writes to
    /// ~10 Hz — plenty for the 1 Hz engine and the 30 fps visualizer
    /// (which has its own decay smoothing), instead of publishing at
    /// buffer rate (~40 Hz) even while backgrounded.
    private var lastPublishTime: CFAbsoluteTime = 0
    private let publishInterval: CFAbsoluteTime = 0.09

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
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
                self.currentLevel = AcousticMath.silenceDB
                self.normalizedLevel = 0.0
                self.voiceBandShare = 0.0
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
        // Remove tap first so no more buffers arrive after teardown.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        aWeighting = nil
        smoothedLevel = AcousticMath.silenceDB
        hasSeededLevel = false
        smoothedVoiceShare = 0.0
        lastBufferTime = 0
    }

    // MARK: - Audio Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // A-weight before measuring. Unweighted RMS is dominated by
        // low-frequency energy — traffic rumble, ventilation, the body of a
        // bus — which contributes little to whether speech or music is
        // audible, but a great deal to the number. Weighting is what makes the
        // reading track *perceived* loudness, and what makes it comparable to
        // a dB(A) sound level meter. Goertzel voice-band detection below
        // deliberately stays on the unweighted signal, since it is a ratio
        // between bands and weighting would bias it.
        let sampleRateNow = buffer.format.sampleRate
        if aWeighting == nil || aWeighting?.sampleRate != sampleRateNow, sampleRateNow > 0 {
            aWeighting = AWeightingFilter(sampleRate: sampleRateNow)
        }

        var rms: Float = 0.0
        if aWeighting != nil {
            // Accumulate in place rather than filtering into a scratch buffer:
            // no allocation on the audio thread.
            var sumSquares: Float = 0
            for i in 0..<frameLength {
                let weighted = aWeighting!.process(channelDataValue[i])
                sumSquares += weighted * weighted
            }
            rms = (sumSquares / Float(frameLength)).squareRoot()
        } else {
            vDSP_rmsqv(channelDataValue, 1, &rms, vDSP_Length(frameLength))
        }

        // Guard against NaN/Inf that can arise on the very first buffer.
        guard rms.isFinite else { return }

        lastBufferTime = CFAbsoluteTimeGetCurrent()

        let db: Float = rms > 0 ? max(20.0 * log10f(rms), AcousticMath.silenceDB)
                                : AcousticMath.silenceDB
        guard db.isFinite else { return }

        // Seed rather than ramp: starting the average at digital silence
        // meant the first readings after every start (and after every mic
        // rebuild) were artificially low.
        if !hasSeededLevel {
            smoothedLevel = db
            hasSeededLevel = true
        } else {
            smoothedLevel = AcousticMath.emaDB(current: smoothedLevel,
                                               sample: db,
                                               retention: smoothingFactor)
        }

        let dbSnapshot = smoothedLevel
        let clamped = min(max(smoothedLevel,
                              AudioManager.displayFloorDB),
                          AudioManager.displayCeilingDB)
        let normalized = (clamped - AudioManager.displayFloorDB)
            / (AudioManager.displayCeilingDB - AudioManager.displayFloorDB)

        // Voice-band energy via Goertzel at four frequencies spanning
        // the typical speech fundamental + first formant range.
        // Cheaper than a full FFT and runs comfortably per-buffer.
        let sampleRate = Float(buffer.format.sampleRate)
        if rms > 0.0005, sampleRate > 0 {
            let voiceFreqs: [Float] = [350, 800, 1500, 2400]
            let nonVoiceFreqs: [Float] = [80, 5000, 8000]
            var voiceEnergy: Float = 0
            for f in voiceFreqs {
                voiceEnergy += AudioManager.goertzelPower(
                    samples: channelDataValue,
                    count: frameLength,
                    frequency: f,
                    sampleRate: sampleRate
                )
            }
            var nonVoiceEnergy: Float = 0
            for f in nonVoiceFreqs {
                nonVoiceEnergy += AudioManager.goertzelPower(
                    samples: channelDataValue,
                    count: frameLength,
                    frequency: f,
                    sampleRate: sampleRate
                )
            }
            let total = voiceEnergy + nonVoiceEnergy
            let share: Float = total > 0 ? voiceEnergy / total : 0
            smoothedVoiceShare = voiceShareSmoothing * smoothedVoiceShare
                + (1.0 - voiceShareSmoothing) * share
        } else {
            // Near-silent buffer: drift toward zero.
            smoothedVoiceShare *= voiceShareSmoothing
        }
        let voiceShareSnapshot = smoothedVoiceShare

        // Smoothing state above updates on every buffer; only the
        // main-thread publish is rate-limited.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublishTime >= publishInterval else { return }
        lastPublishTime = now

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.levelDB = dbSnapshot
            self.currentLevel = dbSnapshot
            self.normalizedLevel = normalized
            self.voiceBandShare = voiceShareSnapshot
        }
    }

    /// Single-frequency Goertzel power estimate. Pure, threadsafe.
    private static func goertzelPower(samples: UnsafePointer<Float>,
                                      count: Int,
                                      frequency: Float,
                                      sampleRate: Float) -> Float {
        let omega = 2.0 * Float.pi * frequency / sampleRate
        let coeff = 2.0 * cosf(omega)
        var s0: Float = 0, s1: Float = 0, s2: Float = 0
        for i in 0..<count {
            s0 = samples[i] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(0, power)
    }

    /// Rough dB SPL for the on-screen readout.
    ///
    /// The previous version mapped the normalized level onto 30…110, i.e. it
    /// stretched 55 dB of measured range across 80 dB of displayed range —
    /// every change was shown ~45% larger than it was. This is a straight
    /// dBFS→SPL offset, so displayed changes match real ones even though the
    /// absolute value is only an estimate.
    var approximateDB: Int {
        guard isMonitoring, levelDB > AcousticMath.silenceDB else { return 0 }
        return Int((levelDB + AudioManager.fullScaleSPL).rounded())
    }

    static func approximateSPL(fromDBFS dbfs: Float) -> Int {
        Int((dbfs + fullScaleSPL).rounded())
    }
}
