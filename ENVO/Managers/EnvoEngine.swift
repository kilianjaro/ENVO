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

    /// Maximum offset in dB (consumed by VolumeMath at apply time).
    var maxOffsetDB: Float {
        switch self {
        case .quiet:  return 3.0
        case .medium: return 6.0
        case .loud:   return 9.0
        }
    }
}

// MARK: - Engine

final class EnvoEngine: ObservableObject {

    // MARK: - Published State (UI-facing)

    @Published var speedMode: SpeedMode = .medium
    @Published var rangeMode: RangeMode = .medium
    @Published var isActive: Bool = false

    @Published var allowIncrease: Bool = true
    @Published var allowDecrease: Bool = true

    @Published private(set) var currentOffset: Float = 0.0
    @Published private(set) var levelHistory: [Float] = []
    @Published private(set) var estimatedAmbient: Float = 0.0
    @Published private(set) var gapDetected: Bool = false

    /// True when the live silence-floor reading deviates significantly
    /// from the calibrated silenceFloor (room has changed materially).
    /// UI surfaces this as a "recalibrate?" hint.
    @Published private(set) var calibrationStale: Bool = false

    // MARK: - Dependencies (injected)

    let audioManager: AudioManager
    let volumeController: VolumeController
    let calibrationStore: CalibrationStore
    let settings: SettingsStore

    /// Convenience for the UI / status row.
    var isCalibrated: Bool { calibrationStore.isCalibrated }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var engineTimer: Timer?

    private var ambientSamples: [Float] = []
    private let maxSampleCount: Int = 600
    private var baselineAmbient: Float = 0.0
    private var hasBaseline: Bool = false
    private var lastGapAmbient: Float?
    private var lastGapTime: Date = .distantPast
    /// How long a gap-derived ambient reading stays authoritative. Beyond
    /// this the room may have changed without another playback gap, so the
    /// estimate falls back to the calibration-subtraction path alone.
    private let gapAmbientTTL: TimeInterval = 120
    private var recentMicLevels: [Float] = []
    private let gapWindowSize: Int = 5
    private let gapThreshold: Float = 1.4
    private let sampleInterval: TimeInterval = 1.0
    private var lastAppliedOffset: Float = 0.0
    private let offsetChangeThreshold: Float = 0.004

    /// DELIBERATE dead-band. Because the zero-snap runs on the smoothed
    /// per-tick step, an offset only starts moving from zero when the
    /// intended offset exceeds zeroHysteresis / (1 − smoothing) — about
    /// ±1 dB calibrated, ±1.7 dB uncalibrated at 50% base volume. Ambient
    /// shifts below that are ignored entirely instead of micro-nudging
    /// the volume. Tune together with the smoothing constants.
    private let zeroHysteresis: Float = 0.008

    /// Maximum |Δoffset| per second on the 0–1 slider scale.
    /// At 1s tick rate this also caps the per-tick change.
    let maxOffsetRatePerSecond: Float = 0.04

    /// Hard ceiling for the resulting volume. ENVO never pushes the
    /// system volume above this regardless of ambient noise (A6).
    let safetyCeiling: Float = 0.92

    private var spikeFilter = SpikeFilter()

    private var uncalibratedSmoothing: Float = 0.92
    private var calibratedSmoothing: Float = 0.85

    private var runGeneration: UInt64 = 0

    // MARK: - Lifecycle

    init(audioManager: AudioManager,
         volumeController: VolumeController,
         calibrationStore: CalibrationStore,
         settings: SettingsStore) {
        self.audioManager = audioManager
        self.volumeController = volumeController
        self.calibrationStore = calibrationStore
        self.settings = settings

        // Seed published state from persisted settings.
        self.speedMode      = settings.speedMode
        self.rangeMode      = settings.rangeMode
        self.allowIncrease  = settings.allowIncrease
        self.allowDecrease  = settings.allowDecrease

        // Republish calibration changes so views observing the engine refresh.
        // A fresh profile also clears the "calibration stale" warning.
        calibrationStore.$profile
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.calibrationStale = false
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Mirror engine prefs back into the settings store so they persist.
        $speedMode
            .dropFirst()
            .sink { [weak settings] v in settings?.speedMode = v }
            .store(in: &cancellables)
        $rangeMode
            .dropFirst()
            .sink { [weak settings] v in settings?.rangeMode = v }
            .store(in: &cancellables)
        $allowIncrease
            .dropFirst()
            .sink { [weak settings] v in settings?.allowIncrease = v }
            .store(in: &cancellables)
        $allowDecrease
            .dropFirst()
            .sink { [weak settings] v in settings?.allowDecrease = v }
            .store(in: &cancellables)

        // Track active-state for auto-resume support.
        $isActive
            .dropFirst()
            .sink { [weak settings] v in settings?.wasActive = v }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func start() {
        guard !isActive else { return }

        // Without mic access the loop would run on all-zero readings and
        // still nudge the volume. Callers that can prompt (ContentView)
        // resolve permission BEFORE calling start(); indirect callers
        // (Siri intents, lock-screen play, auto-resume) must no-op.
        guard audioManager.permissionGranted else { return }

        runGeneration &+= 1
        let myGeneration = runGeneration

        BackgroundAudioHandler.shared.enableBackgroundAudio()
        volumeController.captureBaseVolume()
        audioManager.startMonitoring()

        ambientSamples.removeAll()
        recentMicLevels.removeAll()
        spikeFilter.reset()
        lastGapAmbient = nil
        lastGapTime = .distantPast
        currentOffset = 0.0
        lastAppliedOffset = 0.0
        baselineAmbient = 0.0
        hasBaseline = false

        var warmupSamples: [Float] = []
        let warmupCount = 5
        for step in 1...warmupCount {
            let delay = Double(step) * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                guard self.runGeneration == myGeneration, self.isActive else { return }

                let raw = self.audioManager.normalizedLevel
                let vol = self.volumeController.currentVolume
                let ambient = self.estimateAmbientNoise(rawMicLevel: raw, atVolume: vol)
                warmupSamples.append(ambient)

                if step == warmupCount {
                    let avg = warmupSamples.reduce(0, +) / Float(warmupSamples.count)
                    self.baselineAmbient = avg
                    self.hasBaseline = true
                }
            }
        }

        engineTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = engineTimer {
            RunLoop.main.add(t, forMode: .common)
        }

        isActive = true
    }

    func stop() {
        runGeneration &+= 1

        engineTimer?.invalidate()
        engineTimer = nil
        audioManager.stopMonitoring()
        ambientSamples.removeAll()
        recentMicLevels.removeAll()
        hasBaseline = false
        baselineAmbient = 0.0

        volumeController.clearOffset()
        BackgroundAudioHandler.shared.disableBackgroundAudio()

        isActive = false
        currentOffset = 0.0
        lastAppliedOffset = 0.0
        levelHistory = []
        estimatedAmbient = 0.0
        gapDetected = false
        calibrationStale = false
    }

    // MARK: - Engine Loop

    private func tick() {
        guard isActive else { return }

        let rawMicLevel = audioManager.normalizedLevel
        let currentVol = volumeController.currentVolume

        checkForGap(rawMicLevel: rawMicLevel, currentVol: currentVol)

        // A1 Lombard mitigation + A2 spike rejection live inside
        // estimateAmbientNoise so calibrated/uncalibrated paths share them.
        let ambient = estimateAmbientNoise(rawMicLevel: rawMicLevel, atVolume: currentVol)
        estimatedAmbient = ambient

        ambientSamples.append(ambient)
        if ambientSamples.count > maxSampleCount {
            ambientSamples.removeFirst(ambientSamples.count - maxSampleCount)
        }

        levelHistory = Array(ambientSamples.suffix(60))

        guard hasBaseline else { return }

        let windowSamples = max(3, Int(speedMode.windowSeconds / sampleInterval))
        let relevantSamples = Array(ambientSamples.suffix(windowSamples))
        guard relevantSamples.count >= 3 else { return }

        let windowAverage = relevantSamples.reduce(0, +) / Float(relevantSamples.count)
        let noiseDelta = windowAverage - baselineAmbient

        // ── A3+A4 perceptual dB intent ──
        // Treat the user's RANGE as a dB ceiling on the engine's "intent",
        // then convert to a base-relative volume delta via VolumeMath so
        // the same intent produces the same perceived dB change at any
        // base volume.
        let intentScale: Float = isCalibrated ? 2.0 : 1.2
        let cappedRangeDB = isCalibrated
            ? rangeMode.maxOffsetDB
            : min(rangeMode.maxOffsetDB, 6.0)
        var intendedDB = noiseDelta * intentScale * cappedRangeDB
        intendedDB = clamp(intendedDB, -cappedRangeDB, cappedRangeDB)

        // Direction filter in dB space (same semantics as before).
        if !allowIncrease && intendedDB > 0 { intendedDB = 0 }
        if !allowDecrease && intendedDB < 0 { intendedDB = 0 }

        let baseVol = volumeController.baseVolume
        let intendedOffset = VolumeMath.volumeDelta(
            forDB: intendedDB,
            atBase: baseVol,
            ceiling: safetyCeiling   // A6 safety cap is enforced inside the math.
        )

        // Smooth offset over time.
        let smoothing = isCalibrated ? calibratedSmoothing : uncalibratedSmoothing
        var smoothedOffset = smoothing * currentOffset + (1.0 - smoothing) * intendedOffset

        // Zero-hysteresis (carryover from prior fix).
        if abs(smoothedOffset) < zeroHysteresis {
            smoothedOffset = 0.0
        }

        // A5 rate limiter on the applied offset.
        let maxStep = maxOffsetRatePerSecond * Float(sampleInterval)
        smoothedOffset = clamp(smoothedOffset,
                               currentOffset - maxStep,
                               currentOffset + maxStep)

        // A6 safety ceiling double-check on the projected target.
        let projected = baseVol + smoothedOffset
        if projected > safetyCeiling {
            smoothedOffset = safetyCeiling - baseVol
        }

        currentOffset = smoothedOffset

        if abs(smoothedOffset - lastAppliedOffset) >= offsetChangeThreshold {
            lastAppliedOffset = smoothedOffset
            volumeController.applyOffset(smoothedOffset)
        }
    }

    // MARK: - Ambient Noise Estimation

    private func estimateAmbientNoise(rawMicLevel: Float, atVolume volume: Float) -> Float {
        // A2: clip brief spikes (door slam, clap) before they reach
        // the long-window average.
        let despiked = spikeFilter.ingest(rawMicLevel)

        let baseEstimate: Float
        if let profile = calibrationStore.profile {
            var estimated = profile.estimateAmbient(rawMicLevel: despiked, atVolume: volume)
            if let gapAmbient = lastGapAmbient,
               Date().timeIntervalSince(lastGapTime) < gapAmbientTTL {
                estimated = 0.3 * estimated + 0.7 * gapAmbient
            }
            baseEstimate = max(estimated, 0.0)
        } else {
            baseEstimate = despiked
        }

        // A1: anti-Lombard. When the mic is dominated by speech, discount
        // the ambient estimate so people raising their voice doesn't get
        // misread as "the room is louder, raise volume." Smoothly ramps
        // in above 45% voice-band share, full effect by ~85%.
        //
        // Voice-band share is measured on the RAW signal, which includes
        // our own playback — and music is voice-band heavy. When a
        // calibration profile exists we know how much of the raw level is
        // the device's own output, so we scale the damping by the ambient
        // fraction: music-dominated signal → voice share is mostly music,
        // damping fades out; speech-dominated signal → damping applies.
        // Uncalibrated, full damping is kept — there it also serves as a
        // brake on the playback feedback loop.
        let voiceShare = audioManager.voiceBandShare
        if voiceShare > 0.45 {
            var speechWeight: Float = 1.0
            if let profile = calibrationStore.profile {
                let device = max(profile.expectedMicLevel(atVolume: volume) - profile.silenceFloor, 0.0)
                let ambientFraction = (despiked - device) / max(despiked, 0.001)
                speechWeight = clamp(ambientFraction, 0.0, 1.0)
            }
            let t = clamp((voiceShare - 0.45) / 0.4, 0.0, 1.0)
            let dampen: Float = 0.8 * t * speechWeight
            let damped = baseEstimate * (1.0 - dampen)
            // Damping may only remove UPWARD pressure. Floored at the
            // baseline so a voice-heavy signal can never read as "quieter
            // than baseline" and drag the volume down.
            let floor = hasBaseline ? min(baseEstimate, baselineAmbient) : 0.0
            return max(damped, floor)
        }
        return baseEstimate
    }

    // MARK: - Gap Detection

    private func checkForGap(rawMicLevel: Float, currentVol: Float) {
        guard let profile = calibrationStore.profile else { return }

        recentMicLevels.append(rawMicLevel)
        if recentMicLevels.count > gapWindowSize {
            recentMicLevels.removeFirst()
        }

        guard recentMicLevels.count >= gapWindowSize else { return }

        let recentMax = recentMicLevels.max() ?? 0
        let threshold = profile.silenceFloor * gapThreshold

        if recentMax <= threshold && threshold > 0 {
            let rawGap = recentMicLevels.reduce(0, +) / Float(recentMicLevels.count)
            let ambientGap = profile.estimateAmbient(rawMicLevel: rawGap, atVolume: currentVol)
            lastGapAmbient = ambientGap
            lastGapTime = Date()

            let adaptRate: Float = 0.1
            baselineAmbient = (1.0 - adaptRate) * baselineAmbient + adaptRate * ambientGap

            // B8 validity check: compare live floor against calibrated floor.
            // Flag as stale when the live floor has drifted by > 40% of the
            // calibrated value (in either direction).
            let referenceFloor = max(profile.silenceFloor, 0.001)
            let drift = abs(rawGap - profile.silenceFloor) / referenceFloor
            calibrationStale = drift > 0.4

            gapDetected = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.gapDetected = false
            }
        }
    }

    // MARK: - Display Accessors

    var displayOffset: String {
        let pct = Int((currentOffset * 100).rounded())
        if pct > 0 { return "+\(pct)" }
        if pct < 0 { return "\(pct)" }
        return "0"
    }

    var displayAmbient: Int {
        let mapped = 30.0 + Float(estimatedAmbient) * 80.0
        return Int(mapped)
    }

    // MARK: - Helpers

    private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        return min(max(value, lo), hi)
    }
}
