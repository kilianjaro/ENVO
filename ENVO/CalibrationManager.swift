import Foundation
import AVFoundation
import Combine

// CalibrationProfile now lives in Managers/CalibrationProfile.swift.

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

/// Runs the calibration sweep:
///   1. Measure the room at volume 0 — the silence floor.
///   2. Play a broadband test noise at several volumes.
///   3. At each, measure the mic level after the level has settled.
///   4. Validate, then save the curve.
///
/// WHY THE PREVIOUS SWEEP MEASURED NOTHING
/// ---------------------------------------
/// Three faults compounded, and together they made everything below ~75%
/// volume both inaudible and unmeasurable:
///
///  * The generated pink noise sat around −20 dBFS. Nothing normalized it,
///    so the source itself was already quiet before any volume scaling.
///  * The session ran in `mode: .measurement`, which bypasses the output
///    processing chain and drops speaker output further.
///  * Samples were taken from `normalizedLevel`, which clamped everything
///    below −60 dBFS to exactly 0 — covering the entire range a quiet room
///    and a quiet speaker occupy.
///
/// So the sweep played a quiet noise through an attenuated path and recorded
/// the result with an instrument whose scale started above the signal. It
/// then saved that as a valid profile, which switched the engine into
/// calibrated mode where every ambient estimate came from subtracting zero.
final class CalibrationManager: ObservableObject {

    /// True while a run is in progress. Main-thread only. Checked by
    /// `EnvoEngine.start()` so lock-screen play or a Shortcut cannot launch
    /// the engine into a running volume sweep.
    static private(set) var isCalibrating = false

    // MARK: - Published

    @Published private(set) var state: CalibrationState = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var progress: Float = 0.0

    private var isRunning: Bool {
        switch state {
        case .measuringSilence, .measuringVolume: return true
        default: return false
        }
    }

    // MARK: - Private

    private var audioManager: AudioManager?
    private var volumeController: VolumeController?
    private var calibrationStore: CalibrationStore?
    private var tonePlayer: AVAudioPlayer?

    /// Slider positions to measure.
    ///
    /// Spread across the upper range rather than starting at 15%. On a real
    /// taper, 15% is roughly 40 dB below full — below the noise floor of most
    /// rooms, so it yields no information about the speaker while taking six
    /// seconds to measure. Points that still turn out to be unmeasurable are
    /// detected and reported rather than silently recorded as data.
    private let volumeSteps: [Float] = [0.25, 0.40, 0.55, 0.70, 0.85, 1.0]

    private let stabilizationTime: TimeInterval = 3.0
    private let sampleTime: TimeInterval = 2.0

    /// A measured step must sit at least this far above the silence floor to
    /// count as a real observation of the speaker.
    private let minimumMeasurableHeadroomDB: Float = 3.0

    private var currentSamplesDB: [Float] = []
    private var sampleTimer: Timer?
    private var calibrationPoints: [CalibrationProfile.CalibrationPoint] = []
    private var silenceFloorDB: Float = AcousticMath.silenceDB
    private var savedVolume: Float = 0.5
    private var micDropouts = 0

    private var runGeneration: UInt64 = 0

    private var interruptionToken: NSObjectProtocol?
    private var routeChangeToken: NSObjectProtocol?

    // MARK: - Lifecycle

    init() {}

    deinit {
        if let token = interruptionToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = routeChangeToken {
            NotificationCenter.default.removeObserver(token)
        }
        // A dismissed sheet can drop the manager mid-run; never leave the
        // engine permanently blocked or the session permanently held.
        if CalibrationManager.isCalibrating {
            DispatchQueue.main.async {
                CalibrationManager.isCalibrating = false
                AudioSessionController.shared.release(.calibration)
            }
        }
    }

    private func registerRunGuards() {
        if interruptionToken == nil {
            interruptionToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self = self, self.isRunning,
                      let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
                self.abortRun(reason: "Audio was interrupted (call, Siri, or alarm).")
            }
        }
        if routeChangeToken == nil {
            routeChangeToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self, self.isRunning,
                      let info = notification.userInfo,
                      let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                switch reason {
                case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
                    self.abortRun(reason: "The audio route changed during calibration.")
                default:
                    break
                }
            }
        }
    }

    private func abortRun(reason: String) {
        runGeneration &+= 1
        teardownRun()

        volumeController?.restoreVolume(savedVolume)

        calibrationPoints = []
        currentSamplesDB = []
        silenceFloorDB = AcousticMath.silenceDB
        progress = 0.0

        state = .error(reason)
        log("")
        log("Calibration aborted: \(reason)")
        log("Volume restored. Please run calibration again.")
    }

    /// Everything that must be released however a run ends.
    private func teardownRun() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        tonePlayer?.stop()
        tonePlayer = nil
        CalibrationManager.isCalibrating = false
        AudioSessionController.shared.release(.calibration)
    }

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
        guard let audioManager = audioManager, volumeController != nil else {
            state = .error("Managers not attached")
            return
        }
        guard !CalibrationManager.isCalibrating else { return }
        guard audioManager.permissionGranted else {
            state = .error("Microphone access required")
            return
        }
        guard AudioSessionController.shared.acquire(.calibration) else {
            state = .error("Could not start the audio session")
            return
        }

        runGeneration &+= 1
        CalibrationManager.isCalibrating = true
        registerRunGuards()

        logLines = []
        calibrationPoints = []
        currentSamplesDB = []
        silenceFloorDB = AcousticMath.silenceDB
        progress = 0.0
        micDropouts = 0

        savedVolume = AVAudioSession.sharedInstance().outputVolume

        let seconds = Int((stabilizationTime + sampleTime) * Double(volumeSteps.count + 1))
        log("─── ENVO CALIBRATION ───")
        log("Room setup calibration started.")
        log("Output route: \(AudioSessionController.shared.currentOutputName)")
        log("This will take about \(seconds) seconds.")
        log("")

        if !audioManager.isMonitoring {
            audioManager.startMonitoring()
        }

        // The mic needs a moment to actually start delivering buffers; running
        // the silence measurement before that recorded digital silence as the
        // room's floor.
        waitForMicrophone(generation: runGeneration) { [weak self] ready in
            guard let self = self else { return }
            guard ready else {
                self.abortRun(reason: "The microphone did not start delivering audio.")
                return
            }
            self.measureSilence()
        }
    }

    /// Quick recalibration: refresh the room floor only, keeping the measured
    /// speaker curve.
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
        guard let existing = store.profile, existing.isUsable else {
            startCalibration()
            return
        }
        guard !CalibrationManager.isCalibrating else { return }
        guard AudioSessionController.shared.acquire(.calibration) else {
            state = .error("Could not start the audio session")
            return
        }

        runGeneration &+= 1
        let gen = runGeneration
        CalibrationManager.isCalibrating = true
        registerRunGuards()

        logLines = []
        currentSamplesDB = []
        progress = 0.0
        micDropouts = 0
        savedVolume = AVAudioSession.sharedInstance().outputVolume

        log("─── QUICK RECALIBRATION ───")
        log("Refreshing silence floor only.")
        log("")

        if !audioManager.isMonitoring {
            audioManager.startMonitoring()
        }

        state = .measuringSilence
        log("STEP 1/1: Measuring silence floor")
        vc.setVolumeImmediate(0.0)

        waitForMicrophone(generation: gen) { [weak self] ready in
            guard let self = self, self.runGeneration == gen else { return }
            guard ready else {
                self.abortRun(reason: "The microphone did not start delivering audio.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.stabilizationTime) { [weak self] in
                guard let self = self, self.runGeneration == gen else { return }
                self.log("Sampling room silence...")
                self.collectSamples(generation: gen) { [weak self] avgDB in
                    guard let self = self, self.runGeneration == gen else { return }

                    guard let avgDB = avgDB else {
                        self.abortRun(reason: "Lost microphone input while sampling.")
                        return
                    }

                    self.log("Silence floor: \(Self.fmt(avgDB)) dBFS  (~\(AudioManager.approximateSPL(fromDBFS: avgDB)) dB SPL)")
                    self.log("")

                    let patched = CalibrationProfile(
                        version: CalibrationProfile.currentVersion,
                        silenceFloorDB: avgDB,
                        points: existing.points,
                        date: Date(),
                        routePortType: existing.routePortType
                    )

                    guard patched.isUsable else {
                        self.abortRun(reason: "The refreshed floor is louder than the measured speaker curve. Run a full calibration.")
                        return
                    }

                    self.calibrationStore?.save(patched)
                    self.volumeController?.restoreVolume(self.savedVolume)
                    self.progress = 1.0
                    self.teardownRun()
                    self.state = .finished

                    self.log("─── QUICK RECALIBRATION COMPLETE ───")
                    self.log("Volume restored to \(Int(self.savedVolume * 100))%.")
                }
            }
        }
    }

    func cancelCalibration() {
        runGeneration &+= 1
        teardownRun()

        volumeController?.restoreVolume(savedVolume)

        calibrationPoints = []
        currentSamplesDB = []
        silenceFloorDB = AcousticMath.silenceDB
        progress = 0.0

        state = .idle
        log("")
        log("Calibration cancelled.")
    }

    // MARK: - Microphone readiness

    /// Polls until the input tap is actually delivering buffers, or gives up.
    /// `AVAudioEngine.isRunning` turning true is not the same thing.
    private func waitForMicrophone(generation: UInt64,
                                   attemptsRemaining: Int = 20,
                                   completion: @escaping (Bool) -> Void) {
        guard runGeneration == generation else { return }
        if audioManager?.isReceivingAudio(within: 1.0) == true {
            completion(true)
            return
        }
        guard attemptsRemaining > 0 else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, self.runGeneration == generation else { return }
            self.waitForMicrophone(generation: generation,
                                   attemptsRemaining: attemptsRemaining - 1,
                                   completion: completion)
        }
    }

    // MARK: - Step 1: Silence

    private func measureSilence() {
        let gen = runGeneration
        state = .measuringSilence
        log("STEP 1: Measuring silence floor")
        log("Setting device volume to 0%...")

        volumeController?.setVolumeImmediate(0.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationTime) { [weak self] in
            guard let self = self, self.runGeneration == gen else { return }
            self.log("Sampling room silence...")
            self.collectSamples(generation: gen) { [weak self] avgDB in
                guard let self = self, self.runGeneration == gen else { return }
                guard let avgDB = avgDB else {
                    self.abortRun(reason: "Lost microphone input while sampling.")
                    return
                }
                self.silenceFloorDB = avgDB
                self.log("Silence floor: \(Self.fmt(avgDB)) dBFS  (~\(AudioManager.approximateSPL(fromDBFS: avgDB)) dB masking-weighted)")
                // The A-weighted figure is the one that is directly comparable
                // to a dB(A) sound level meter, which the masking-weighted
                // control level deliberately is not. Logged so the numbers can
                // be checked against any SPL app.
                if let am = self.audioManager {
                    self.log("Room, A-weighted: ~\(AudioManager.approximateAWeightedSPL(fromDBFS: am.aWeightedLevelDB)) dB(A)")
                }
                self.log("")
                self.progress = 1.0 / Float(self.volumeSteps.count + 1)
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

        volumeController?.setVolumeImmediate(vol)
        startTestTone()

        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationTime) { [weak self] in
            guard let self = self, self.runGeneration == gen else { return }
            self.collectSamples(generation: gen) { [weak self] avgDB in
                guard let self = self, self.runGeneration == gen else { return }
                guard let avgDB = avgDB else {
                    self.abortRun(reason: "Lost microphone input while sampling.")
                    return
                }

                self.calibrationPoints.append(
                    .init(volume: vol, micLevelDB: avgDB)
                )

                let headroom = avgDB - self.silenceFloorDB
                if headroom >= self.minimumMeasurableHeadroomDB {
                    let device = AcousticMath.subtractDB(avgDB, self.silenceFloorDB)
                    self.log("Mic \(Self.fmt(avgDB)) dBFS  |  speaker \(Self.fmt(device)) dBFS")
                } else {
                    self.log("Mic \(Self.fmt(avgDB)) dBFS  |  speaker below room floor — not measurable here")
                }
                self.log("")

                self.progress = Float(index + 2) / Float(self.volumeSteps.count + 1)
                self.tonePlayer?.stop()
                self.measureVolumeStep(index: index + 1)
            }
        }
    }

    // MARK: - Finish

    private func finishCalibration() {
        let restoreTo = savedVolume
        teardownRun()
        volumeController?.restoreVolume(restoreTo)

        let profile = CalibrationProfile(
            version: CalibrationProfile.currentVersion,
            silenceFloorDB: silenceFloorDB,
            points: calibrationPoints.sorted(by: { $0.volume < $1.volume }),
            date: Date(),
            routePortType: AudioSessionController.shared.currentOutputPortType?.rawValue
        )

        // Refuse to save a profile that recorded nothing. Saving one is worse
        // than having none: it flips the engine into calibrated mode, where
        // the ambient estimate comes from a subtraction that cannot work.
        guard profile.isUsable else {
            state = .error("No usable measurements")
            log("")
            log("─── CALIBRATION FAILED ───")
            log("The microphone never heard the test noise clearly above the")
            log("room. Usual causes: the room was too loud, the phone was")
            log("face-down or covered, or output is routed to a device the")
            log("built-in mic cannot hear.")
            log("")
            log("Volume restored to \(Int(restoreTo * 100))%.")
            return
        }

        calibrationStore?.save(profile)
        progress = 1.0
        state = .finished

        log("─── CALIBRATION COMPLETE ───")
        log("")
        log("Silence floor: \(Self.fmt(silenceFloorDB)) dBFS")
        log("")
        log("Speaker output vs volume:")
        for p in profile.points {
            let device = profile.deviceContributionDB(atVolume: p.volume)
            let measurable = p.micLevelDB - silenceFloorDB >= minimumMeasurableHeadroomDB
            let barLength = measurable
                ? max(0, min(40, Int((device - AudioManager.displayFloorDB) / 2)))
                : 0
            let bar = String(repeating: "█", count: barLength)
            let value = measurable ? "\(Self.fmt(device)) dBFS" : "—"
            log("  \(String(format: "%3d", Int(p.volume * 100)))%  \(bar)  \(value)")
        }
        log("")

        if let taper = profile.measuredTaper {
            log("Measured volume curve: \(Self.fmt(taper.spanDB)) dB per full slider.")
            log("Assumed before calibration: \(Self.fmt(VolumeTaper.defaultSpanDB)) dB.")
            log("ENVO will now use the measured curve, so your")
            log("range setting means real decibels on this device.")
        } else {
            log("Not enough measurable steps to derive the volume curve;")
            log("ENVO will use its default curve. Ambient separation still")
            log("works from the measurements above.")
        }
        log("")
        log("Volume restored to \(Int(restoreTo * 100))%.")
    }

    // MARK: - Sampling

    /// Collects mic levels for `sampleTime` and returns their energy-weighted
    /// mean in dBFS, or nil if the microphone stopped delivering audio.
    private func collectSamples(generation: UInt64, completion: @escaping (Float?) -> Void) {
        currentSamplesDB = []
        micDropouts = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let am = self.audioManager else { return }
            // Only record while the mic is verifiably alive. A frozen reading
            // repeated twenty times looks exactly like a steady measurement.
            if am.isReceivingAudio(within: 0.5) {
                self.currentSamplesDB.append(am.levelDB)
            } else {
                self.micDropouts += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + sampleTime) { [weak self] in
            guard let self = self, self.runGeneration == generation else { return }
            self.sampleTimer?.invalidate()
            self.sampleTimer = nil

            // Require most of the window to be real samples.
            let expected = Int(self.sampleTime / 0.1)
            guard self.currentSamplesDB.count >= expected / 2 else {
                completion(nil)
                return
            }
            completion(AcousticMath.meanDB(self.currentSamplesDB))
        }
    }

    // MARK: - Test Tone

    /// Generates broadband (pink-ish) noise and plays it on loop.
    ///
    /// Normalized to a known RMS. The previous version applied a fixed 0.11
    /// scale factor to the filter output and never measured the result, which
    /// left the source roughly 20 dB quieter than it should have been — the
    /// first of the three reasons the low volume steps were inaudible.
    private func startTestTone() {
        guard tonePlayer == nil || !(tonePlayer?.isPlaying ?? false) else { return }

        let sampleRate = 44100
        let duration = 2.0
        let numSamples = Int(Double(sampleRate) * duration)

        var samples = [Float](repeating: 0, count: numSamples)

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
            samples[i] = b0 + b1 + b2 + b3 + b4 + b5 + white * 0.5362
        }

        // Normalize to a target RMS, then guard the peaks. −14 dBFS RMS is a
        // typical mastered-music level, so the sweep exercises the speaker at
        // the same sort of level the user's actual audio will.
        let targetRMS: Float = 0.2
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = sqrtf(sumSquares / Float(max(numSamples, 1)))
        if rms > 0.00001 {
            let scale = targetRMS / rms
            var peak: Float = 0
            for i in 0..<numSamples {
                samples[i] *= scale
                peak = max(peak, abs(samples[i]))
            }
            // Pink noise has a high crest factor; keep headroom rather than
            // clipping, which would change the spectrum we are measuring.
            if peak > 0.95 {
                let trim = 0.95 / peak
                for i in 0..<numSamples { samples[i] *= trim }
            }
        }

        let wavData = buildWAV(samples: samples, sampleRate: sampleRate)

        do {
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 1.0   // Device volume is what we are measuring.
            player.play()
            tonePlayer = player
        } catch {
            log("Warning: Could not play test tone: \(error.localizedDescription)")
        }
    }

    private func buildWAV(samples: [Float], sampleRate: Int) -> Data {
        let bitsPerSample = 16
        let numChannels = 1
        let dataSize = samples.count * 2

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: uint32LE(UInt32(36 + dataSize)))
        wav.append(contentsOf: Array("WAVE".utf8))

        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: uint32LE(16))
        wav.append(contentsOf: uint16LE(1))  // PCM
        wav.append(contentsOf: uint16LE(UInt16(numChannels)))
        wav.append(contentsOf: uint32LE(UInt32(sampleRate)))
        wav.append(contentsOf: uint32LE(UInt32(sampleRate * numChannels * bitsPerSample / 8)))
        wav.append(contentsOf: uint16LE(UInt16(numChannels * bitsPerSample / 8)))
        wav.append(contentsOf: uint16LE(UInt16(bitsPerSample)))

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

    private static func fmt(_ value: Float) -> String {
        String(format: "%.1f", value)
    }

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
