import Foundation
import AVFoundation
import Combine

/// Stores the result of a calibration session.
/// Maps device volume levels to expected microphone pickup (in normalized 0…1).
struct CalibrationProfile: Codable {
    /// The silence floor: mic level when device volume = 0.
    /// This is pure room ambient noise at calibration time.
    var silenceFloor: Float

    /// Calibration points: (volume, micLevel) pairs sorted by volume.
    var points: [CalibrationPoint]

    /// When this calibration was performed.
    var date: Date

    struct CalibrationPoint: Codable {
        let volume: Float       // Device volume 0…1
        let micLevel: Float     // Measured mic level (normalized 0…1)
    }

    /// Interpolate the expected mic contribution at a given volume.
    /// Returns the mic level the device speaker should produce at this volume.
    /// Safe for empty / single-point profiles and volumes outside the
    /// calibrated range.
    func expectedMicLevel(atVolume volume: Float) -> Float {
        // Empty profile: nothing to interpolate against.
        guard let first = points.first, let last = points.last else {
            return silenceFloor
        }
        if points.count == 1 { return first.micLevel }

        // Clamp to the endpoints rather than force-unwrapping.
        if volume <= first.volume { return first.micLevel }
        if volume >= last.volume { return last.micLevel }

        for i in 0..<(points.count - 1) {
            let lo = points[i]
            let hi = points[i + 1]
            if volume >= lo.volume && volume <= hi.volume {
                let denom = hi.volume - lo.volume
                guard denom > 0 else { return lo.micLevel }
                let t = (volume - lo.volume) / denom
                return lo.micLevel + t * (hi.micLevel - lo.micLevel)
            }
        }

        return silenceFloor
    }

    /// Estimate the ambient noise from a raw mic reading at a known volume.
    /// ambient ≈ raw_mic - device_contribution
    func estimateAmbient(rawMicLevel: Float, atVolume volume: Float) -> Float {
        let deviceContribution = expectedMicLevel(atVolume: volume) - silenceFloor
        let ambient = rawMicLevel - deviceContribution
        return max(ambient, 0.0)
    }
}

// MARK: - Calibration State

enum CalibrationState: Equatable {
    case idle
    case measuringSilence
    case measuringVolume(step: Int, total: Int, volume: Float)
    case finished
    case error(String)

    static func == (lhs: CalibrationState, rhs: CalibrationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.measuringSilence, .measuringSilence),
             (.finished, .finished):
            return true
        case (.measuringVolume(let a, _, _), .measuringVolume(let b, _, _)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Manager

/// Handles the calibration process:
/// 1. Measure silence (volume = 0) to get the room's noise floor.
/// 2. Play a test tone at several volume levels.
/// 3. At each level, measure the mic pickup after stabilization.
/// 4. Save the calibration curve.
final class CalibrationManager: ObservableObject {

    // MARK: - Published

    @Published private(set) var state: CalibrationState = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var progress: Float = 0.0

    // MARK: - Private

    private var audioManager: AudioManager?
    private var volumeController: VolumeController?
    private var calibrationStore: CalibrationStore?
    private var tonePlayer: AVAudioPlayer?

    /// Volume steps to test during calibration.
    private let volumeSteps: [Float] = [0.15, 0.30, 0.50, 0.70, 0.85, 1.0]

    /// How long to wait at each volume for the mic reading to stabilize (seconds).
    private let stabilizationTime: TimeInterval = 3.0

    /// How long to sample after stabilization (seconds).
    private let sampleTime: TimeInterval = 2.0

    /// Samples collected during the current measurement.
    private var currentSamples: [Float] = []
    private var sampleTimer: Timer?
    private var calibrationPoints: [CalibrationProfile.CalibrationPoint] = []
    private var silenceFloor: Float = 0.0
    private var savedVolume: Float = 0.5

    /// Invalidates in-flight async continuations when a run is cancelled or
    /// restarted. Every asyncAfter/timer callback checks it before acting,
    /// otherwise a cancelled calibration keeps stepping the volume and
    /// replaying the test tone. Same pattern as EnvoEngine.runGeneration.
    private var runGeneration: UInt64 = 0

    // MARK: - Lifecycle

    init() {}

    // MARK: - Setup

    func attach(audioManager: AudioManager,
                volumeController: VolumeController,
                calibrationStore: CalibrationStore) {
        self.audioManager = audioManager
        self.volumeController = volumeController
        self.calibrationStore = calibrationStore
    }

    // MARK: - Calibration Process

    func startCalibration() {
        guard let audioManager = audioManager,
              let vc = volumeController else {
            state = .error("Managers not attached")
            return
        }

        // Without mic access we'd record zeros and save a useless profile.
        guard audioManager.permissionGranted else {
            state = .error("Microphone access required")
            return
        }

        _ = vc  // Silence unused-var warning; capture is intentional.

        runGeneration &+= 1

        // Reset state.
        logLines = []
        calibrationPoints = []
        currentSamples = []
        silenceFloor = 0.0
        progress = 0.0

        // Save the user's current volume to restore later.
        savedVolume = AVAudioSession.sharedInstance().outputVolume

        log("─── ENVO CALIBRATION ───")
        log("Room setup calibration started.")
        log("This will take about \(Int((stabilizationTime + sampleTime) * Double(volumeSteps.count + 1))) seconds.")
        log("")

        // Ensure mic is running.
        if !audioManager.isMonitoring {
            audioManager.startMonitoring()
        }

        // Step 1: Measure silence.
        measureSilence()
    }

    /// Silence-only recalibration: measures the room floor and patches the
    /// existing profile without replaying the full volume sweep.
    /// Falls back to a full calibration if no profile exists yet.
    func startQuickRecalibration() {
        guard let audioManager = audioManager,
              let vc = volumeController,
              let store = calibrationStore else {
            state = .error("Managers not attached")
            return
        }
        guard audioManager.permissionGranted else {
            state = .error("Microphone access required")
            return
        }
        guard let existing = store.profile else {
            // No profile to patch — fall through to the full flow.
            startCalibration()
            return
        }

        runGeneration &+= 1
        let gen = runGeneration

        logLines = []
        currentSamples = []
        progress = 0.0
        savedVolume = AVAudioSession.sharedInstance().outputVolume

        log("─── QUICK RECALIBRATION ───")
        log("Refreshing silence floor only.")
        log("This will take about 5 seconds.")
        log("")

        if !audioManager.isMonitoring {
            audioManager.startMonitoring()
        }

        state = .measuringSilence
        log("STEP 1/1: Measuring silence floor")
        vc.setVolumeImmediate(0.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationTime) { [weak self] in
            guard let self = self, self.runGeneration == gen else { return }
            self.log("Sampling room silence...")
            self.collectSamples(generation: gen) { [weak self] avg in
                guard let self = self, self.runGeneration == gen else { return }
                self.log("Silence floor: \(String(format: "%.4f", avg))")
                self.log("")

                // Patch the existing profile in place.
                let patched = CalibrationProfile(
                    silenceFloor: avg,
                    points: existing.points,
                    date: Date()
                )
                self.calibrationStore?.save(patched)

                // Restore user's volume.
                self.volumeController?.setVolumeImmediate(self.savedVolume)
                self.progress = 1.0
                self.state = .finished

                self.log("─── QUICK RECALIBRATION COMPLETE ───")
                self.log("Volume restored to \(Int(self.savedVolume * 100))%.")
            }
        }
    }

    func cancelCalibration() {
        runGeneration &+= 1
        sampleTimer?.invalidate()
        sampleTimer = nil
        tonePlayer?.stop()
        tonePlayer = nil

        // Restore volume.
        volumeController?.setVolumeImmediate(savedVolume)

        // Drop partial work so a subsequent start isn't poisoned.
        calibrationPoints = []
        currentSamples = []
        silenceFloor = 0.0
        progress = 0.0

        state = .idle
        log("")
        log("Calibration cancelled.")
    }

    // MARK: - Step 1: Silence

    private func measureSilence() {
        let gen = runGeneration
        state = .measuringSilence
        log("STEP 1: Measuring silence floor")
        log("Setting device volume to 0%...")

        // Set volume to zero.
        volumeController?.setVolumeImmediate(0.0)

        // Wait for stabilization, then sample.
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationTime) { [weak self] in
            guard let self = self, self.runGeneration == gen else { return }
            self.log("Sampling room silence...")
            self.collectSamples(generation: gen) { [weak self] avg in
                guard let self = self, self.runGeneration == gen else { return }
                self.silenceFloor = avg
                self.log("Silence floor: \(String(format: "%.4f", avg))")
                self.log("")
                self.progress = 1.0 / Float(self.volumeSteps.count + 1)

                // Proceed to volume steps.
                self.measureVolumeStep(index: 0)
            }
        }
    }

    // MARK: - Step 2…N: Volume Levels

    private func measureVolumeStep(index: Int) {
        let gen = runGeneration
        guard index < volumeSteps.count else {
            finishCalibration()
            return
        }

        let vol = volumeSteps[index]
        let pct = Int(vol * 100)
        state = .measuringVolume(step: index + 1, total: volumeSteps.count, volume: vol)

        log("STEP \(index + 2): Testing at \(pct)% volume")

        // Set volume.
        volumeController?.setVolumeImmediate(vol)

        // Start playing test tone.
        startTestTone()

        log("Playing test tone at \(pct)%...")
        log("Stabilizing...")

        // Wait, then sample.
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationTime) { [weak self] in
            guard let self = self, self.runGeneration == gen else { return }
            self.log("Sampling mic level...")

            self.collectSamples(generation: gen) { [weak self] avg in
                guard let self = self, self.runGeneration == gen else { return }

                let point = CalibrationProfile.CalibrationPoint(volume: vol, micLevel: avg)
                self.calibrationPoints.append(point)

                let contribution = avg - self.silenceFloor
                self.log("Mic level: \(String(format: "%.4f", avg))  |  Device contribution: \(String(format: "%.4f", max(contribution, 0)))")
                self.log("")

                self.progress = Float(index + 2) / Float(self.volumeSteps.count + 1)

                // Stop tone before next step.
                self.tonePlayer?.stop()

                // Next step.
                self.measureVolumeStep(index: index + 1)
            }
        }
    }

    // MARK: - Finish

    private func finishCalibration() {
        tonePlayer?.stop()
        tonePlayer = nil

        // Restore user's volume.
        volumeController?.setVolumeImmediate(savedVolume)

        // If somehow no points were captured, surface an error instead of
        // saving an unusable profile that would break later runs.
        guard !calibrationPoints.isEmpty else {
            state = .error("No calibration data captured")
            log("")
            log("Calibration failed: no usable measurements.")
            return
        }

        // Build and save profile.
        let profile = CalibrationProfile(
            silenceFloor: silenceFloor,
            points: calibrationPoints.sorted(by: { $0.volume < $1.volume }),
            date: Date()
        )
        calibrationStore?.save(profile)

        progress = 1.0
        state = .finished

        log("─── CALIBRATION COMPLETE ───")
        log("")
        log("Profile saved with \(calibrationPoints.count) measurement points.")
        log("Silence floor: \(String(format: "%.4f", silenceFloor))")
        log("")
        log("Calibration curve:")
        for p in profile.points {
            let barLength = max(0, min(40, Int(p.micLevel * 40)))
            let bar = String(repeating: "█", count: barLength)
            log("  \(String(format: "%3d", Int(p.volume * 100)))%  \(bar)  \(String(format: "%.4f", p.micLevel))")
        }
        log("")
        log("ENVO will now subtract estimated device")
        log("output from mic readings to isolate ambient noise.")
        log("Volume restored to \(Int(savedVolume * 100))%.")
    }

    // MARK: - Sampling

    /// Collects mic samples for `sampleTime` seconds and returns the average.
    /// `generation` invalidates the collection if the run was cancelled or
    /// restarted while sampling.
    private func collectSamples(generation: UInt64, completion: @escaping (Float) -> Void) {
        currentSamples = []

        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let am = self.audioManager else { return }
            self.currentSamples.append(am.normalizedLevel)
        }
        // Keep sampling steady while SwiftUI tracks touches (sheet drags etc.).
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + sampleTime) { [weak self] in
            guard let self = self, self.runGeneration == generation else { return }
            self.sampleTimer?.invalidate()
            self.sampleTimer = nil

            let avg: Float
            if self.currentSamples.isEmpty {
                avg = 0.0
            } else {
                avg = self.currentSamples.reduce(0, +) / Float(self.currentSamples.count)
            }
            completion(avg)
        }
    }

    // MARK: - Test Tone

    /// Generates a pink-noise-like test tone in memory and plays it.
    private func startTestTone() {
        guard tonePlayer == nil || !(tonePlayer?.isPlaying ?? false) else { return }

        // Generate a 2-second WAV of broadband noise.
        let sampleRate: Int = 44100
        let duration: Double = 2.0
        let numSamples = Int(Double(sampleRate) * duration)

        var samples = [Float](repeating: 0, count: numSamples)

        // White noise with simple low-pass to approximate pink noise.
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var b3: Float = 0, b4: Float = 0, b5: Float = 0

        for i in 0..<numSamples {
            let white = Float.random(in: -1.0...1.0)

            // Paul Kellet's pink noise filter.
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980

            let pink = (b0 + b1 + b2 + b3 + b4 + b5 + white * 0.5362) * 0.11
            samples[i] = pink
        }

        // Build WAV data.
        let wavData = buildWAV(samples: samples, sampleRate: sampleRate)

        do {
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1  // Loop forever.
            player.volume = 1.0        // Max (device volume controls actual loudness).
            player.play()
            tonePlayer = player
        } catch {
            log("Warning: Could not play test tone: \(error.localizedDescription)")
        }
    }

    private func buildWAV(samples: [Float], sampleRate: Int) -> Data {
        let bitsPerSample: Int = 16
        let numChannels: Int = 1
        let dataSize = samples.count * 2  // 16-bit = 2 bytes per sample

        var wav = Data()

        // RIFF header.
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: uint32LE(UInt32(36 + dataSize)))
        wav.append(contentsOf: Array("WAVE".utf8))

        // fmt chunk.
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: uint32LE(16))
        wav.append(contentsOf: uint16LE(1))  // PCM
        wav.append(contentsOf: uint16LE(UInt16(numChannels)))
        wav.append(contentsOf: uint32LE(UInt32(sampleRate)))
        wav.append(contentsOf: uint32LE(UInt32(sampleRate * numChannels * bitsPerSample / 8)))
        wav.append(contentsOf: uint16LE(UInt16(numChannels * bitsPerSample / 8)))
        wav.append(contentsOf: uint16LE(UInt16(bitsPerSample)))

        // data chunk.
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: uint32LE(UInt32(dataSize)))

        for sample in samples {
            let clamped = min(max(sample, -1.0), 1.0)
            let int16 = Int16(clamped * 32767)
            wav.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        return wav
    }

    // MARK: - Helpers

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logLines.append(message)
        }
    }

    private func uint32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func uint16LE(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
}
