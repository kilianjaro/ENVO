import Foundation
import AVFoundation
import Accelerate
import Combine

/// Manages microphone input for ambient noise level measurement.
/// IMPORTANT: No audio data is recorded or stored. Only instantaneous
/// power levels are read from the audio engine's input node.
final class AudioManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentLevel: Float = -160.0
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

    private let smoothingFactor: Float = 0.3
    private let dbFloor: Float = -60.0
    private let dbCeiling: Float = -5.0
    private var smoothedLevel: Float = -160.0
    private var smoothedVoiceShare: Float = 0.0
    private let voiceShareSmoothing: Float = 0.85

    // MARK: - Lifecycle

    init() {}

    deinit {
        // Only the synchronous teardown here. stopMonitoring() dispatches
        // async closures that capture self — illegal during deinit.
        tearDownEngine()
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
                self.currentLevel = -160.0
                self.normalizedLevel = 0.0
                self.voiceBandShare = 0.0
            }
        }
    }

    /// Synchronous, idempotent engine teardown. Safe to call from deinit.
    private func tearDownEngine() {
        guard let engine = audioEngine else { return }
        // Remove tap first so no more buffers arrive after teardown.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        smoothedLevel = -160.0
        smoothedVoiceShare = 0.0
    }

    // MARK: - Audio Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var rms: Float = 0.0
        vDSP_rmsqv(channelDataValue, 1, &rms, vDSP_Length(frameLength))

        // Guard against NaN/Inf that can arise on the very first buffer.
        guard rms.isFinite else { return }

        let db: Float = rms > 0 ? 20.0 * log10f(rms) : -160.0
        guard db.isFinite else { return }

        smoothedLevel = smoothingFactor * smoothedLevel + (1.0 - smoothingFactor) * db

        let clamped = min(max(smoothedLevel, dbFloor), dbCeiling)
        let normalized = (clamped - dbFloor) / (dbCeiling - dbFloor)
        let dbSnapshot = smoothedLevel

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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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

    var approximateDB: Int {
        let mapped = 30.0 + normalizedLevel * 80.0
        return Int(mapped)
    }
}
