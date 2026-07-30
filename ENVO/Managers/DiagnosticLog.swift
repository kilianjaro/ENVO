import Foundation
import AVFoundation
import UIKit

/// Records one row per control tick to a CSV file, so a listening session can
/// be reconstructed afterwards and compared against what the listener actually
/// perceived.
///
/// WHY A FILE AND NOT JUST os_log
/// ------------------------------
/// Both, in fact — every line goes to `Log.diag` as well, so Console.app on a
/// tethered Mac shows the session live. But a file is the artifact worth
/// reasoning about: an hour of testing is 3600 rows, Console truncates and
/// interleaves other subsystems, and the interesting questions ("did the offset
/// creep over twenty minutes", "was the damper engaged when it felt wrong") are
/// questions about a column over time, not about a single line.
///
/// WHAT IS AND IS NOT IN HERE
/// --------------------------
/// Levels, scores and control state. **No audio, ever** — the same guarantee the
/// rest of the app makes. Nothing leaves the device unless the user explicitly
/// shares the file.
///
/// SHIPPING BUILDS
/// ---------------
/// The whole implementation is `#if DEBUG`. Release builds — which is what
/// `Archive` produces, and therefore what goes to TestFlight and the App Store —
/// get the no-op stub at the bottom of this file instead: same API, empty
/// bodies, `isEnabled` permanently false. The optimiser removes the calls.
///
/// It is done that way rather than with `#if DEBUG` at each call site because
/// there are twenty-two of them across four files, and peppering the engine with
/// conditional compilation to hide a diagnostic would make the control loop
/// harder to read than the thing it is diagnosing.
///
/// FORMAT
/// ------
/// Lines beginning with `#` are metadata or discrete events. Everything else is
/// a fixed-width CSV row matching `Self.header`. Filtering out `#` gives a
/// rectangular table that opens directly in Numbers or a dataframe; keeping them
/// gives the event timeline interleaved in the right places.
#if DEBUG

final class DiagnosticLog {

    static let shared = DiagnosticLog()

    /// Off by default. Writing costs almost nothing, but a diagnostic that runs
    /// unasked is a diagnostic nobody trusts.
    var isEnabled = false

    private(set) var currentFileURL: URL?
    private var handle: FileHandle?
    private var buffer: [String] = []
    private var tickCount = 0
    private var sessionStart = Date()

    /// Rows held before touching the filesystem. Small enough that a crash
    /// loses at most a couple of seconds.
    private let flushThreshold = 20

    private init() {}

    // MARK: - Column layout

    /// Keep in step with `row(from:)`. Order matters to anyone parsing this.
    static let header = [
        "t_s",                  // seconds since START
        "tick",
        "ctrl_dbfs",            // masking-weighted control level, mean over tick
        "ctrl_spl_est",         // …as an approximate SPL figure
        "aweight_dbfs",         // A-weighted broadband
        "aweight_spl_est",      // …as approximate dB(A) — THIS is what an SPL app should match
        "b125", "b250", "b500", "b1k", "b2k", "b4k",
        "floor_dbfs",           // L90 over the response window, before any correction
        "coupling",             // 0…1 share of the floor attributed to our own playback
        "coupling_measured",    // 0 = route prior, 1 = measured
        "delivered_db",         // what the hardware is actually delivering vs baseline
        "room_dbfs",            // floor with our own contribution removed
        "damped_dbfs",          // …after the Lombard damper
        "baseline_dbfs",
        "noise_delta_db",       // damped room minus baseline — the control law's input
        "speech_at_floor",      // combined 0…1 score, sampled at the floor
        "spectral_score",       // spectral half, live mean over the tick
        "mod_depth_db",         // temporal half, live mean over the tick
        "offset_intent_db",     // what the control law wants
        "base_vol",             // user's baseline slider position
        "sys_vol",             // actual system volume right now
        "slider_offset",
        "obstructed",
        "clipping",
        "playback_idle",
        "speed",
        "range_db"
    ].joined(separator: ",")

    // MARK: - Session lifecycle

    /// Open a new log. Safe to call when disabled — it simply does nothing.
    func startSession(engine: EnvoEngine) {
        guard isEnabled else { return }
        endSession(reason: "superseded")

        sessionStart = Date()
        tickCount = 0

        let stamp = DiagnosticLog.fileStampFormatter.string(from: sessionStart)
        let url = DiagnosticLog.documentsDirectory
            .appendingPathComponent("envo-diag-\(stamp).csv")

        FileManager.default.createFile(atPath: url.path)
        guard let h = try? FileHandle(forWritingTo: url) else {
            Log.diag.error("Could not open diagnostic log at \(url.lastPathComponent, privacy: .public)")
            return
        }
        handle = h
        currentFileURL = url

        for line in metadataLines(engine: engine) { append("# " + line) }
        append(DiagnosticLog.header)
        flush()

        Log.diag.info("Diagnostic log started: \(url.lastPathComponent, privacy: .public)")
    }

    func endSession(reason: String = "stopped") {
        guard handle != nil else { return }
        event("session-end", reason)
        flush()
        try? handle?.close()
        handle = nil
        if let url = currentFileURL {
            Log.diag.info("Diagnostic log closed: \(url.lastPathComponent, privacy: .public) (\(self.tickCount) ticks)")
        }
    }

    /// Everything needed to interpret the rows that follow. Absolute levels mean
    /// nothing without the route, the taper and the SPL constants in force.
    private func metadataLines(engine: EnvoEngine) -> [String] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.first
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        return [
            "ENVO diagnostic log — levels and control state only, no audio.",
            "started=\(ISO8601DateFormatter().string(from: sessionStart))",
            "app=\(version) (\(build))  device=\(model)  ios=\(UIDevice.current.systemVersion)",
            "output_route=\(route?.portName ?? "unknown")  port_type=\(route?.portType.rawValue ?? "unknown")",
            "input_route=\(session.currentRoute.inputs.first?.portName ?? "unknown")",
            "session_mode=\(session.mode.rawValue)  sample_rate=\(session.sampleRate)",
            "calibrated=\(engine.isCalibrated)  taper_span_db=\(String(format: "%.1f", engine.activeTaper.spanDB))",
            "coupling_prior=\(String(format: "%.2f", AudioSessionController.shared.selfCouplingPrior))",
            "speed=\(engine.speedMode.rawValue)  range_db=\(engine.rangeMode.maxOffsetDB)  up=\(engine.allowIncrease)  down=\(engine.allowDecrease)",
            "base_volume=\(String(format: "%.3f", engine.volumeController.baseVolume))  volume_step=\(String(format: "%.4f", engine.volumeController.volumeStep))",
            "volume_control_available=\(engine.volumeController.isVolumeControlAvailable)",
            "ctrl_spl_offset=\(AudioManager.fullScaleSPL)  aweight_spl_offset=\(AudioManager.aWeightedFullScaleSPL)",
            "NOTE: ctrl_* is masking-weighted and is NOT dB(A). Compare an SPL meter against aweight_spl_est.",
            "NOTE: *_spl_est figures carry an uncalibrated offset, +/-10 dB. Differences are trustworthy; absolutes are not."
        ]
    }

    // MARK: - Per-tick row

    func tick(_ s: DiagnosticTick) {
        guard isEnabled, handle != nil else { return }
        tickCount += 1

        func f(_ v: Float, _ p: Int = 2) -> String { String(format: "%.\(p)f", v) }
        let bands = (0..<6).map { i in
            i < s.bandLevelsDB.count ? f(s.bandLevelsDB[i], 1) : ""
        }

        let row = [
            f(Float(Date().timeIntervalSince(sessionStart)), 1),
            "\(tickCount)",
            f(s.controlLevelDB, 1),
            "\(AudioManager.approximateSPL(fromDBFS: s.controlLevelDB))",
            f(s.aWeightedLevelDB, 1),
            "\(AudioManager.approximateAWeightedSPL(fromDBFS: s.aWeightedLevelDB))"
        ] + bands + [
            f(s.floorDB, 1),
            f(s.coupling, 3),
            s.couplingIsMeasured ? "1" : "0",
            f(s.deliveredDB),
            f(s.roomDB, 1),
            f(s.dampedRoomDB, 1),
            f(s.baselineDB, 1),
            f(s.noiseDeltaDB),
            f(s.speechAtFloor, 3),
            f(s.spectralScore, 3),
            f(s.modulationDepthDB, 2),
            f(s.offsetIntentDB),
            f(s.baseVolume, 3),
            f(s.systemVolume, 3),
            f(s.sliderOffset, 3),
            s.obstructed ? "1" : "0",
            s.clipping ? "1" : "0",
            s.playbackIdle ? "1" : "0",
            s.speed,
            f(s.rangeDB, 1)
        ]

        append(row.joined(separator: ","))
        if buffer.count >= flushThreshold { flush() }
    }

    // MARK: - Discrete events

    /// Anything that happens between ticks and would otherwise be invisible in a
    /// column of numbers: a step written to the hardware, a re-anchor, a
    /// coupling observation being accepted or rejected.
    func event(_ label: String, _ detail: String = "") {
        guard isEnabled else { return }
        let t = String(format: "%.1f", Date().timeIntervalSince(sessionStart))
        let line = "# EVENT t=\(t) \(label)\(detail.isEmpty ? "" : " — " + detail)"
        Log.diag.info("\(line, privacy: .public)")
        guard handle != nil else { return }
        buffer.append(line)
        flush()
    }

    /// A note the listener adds from the UI, so their perception lands in the
    /// same timeline as the numbers. This is the column no amount of telemetry
    /// can replace.
    func mark(_ note: String) {
        event("LISTENER-MARK", note)
    }

    // MARK: - Files

    /// Newest first. The UI offers the most recent for sharing.
    func existingLogs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: DiagnosticLog.documentsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("envo-diag-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    func deleteAllLogs() {
        endSession(reason: "logs deleted")
        for url in existingLogs() { try? FileManager.default.removeItem(at: url) }
        currentFileURL = nil
    }

    // MARK: - Writing

    private func append(_ line: String) {
        buffer.append(line)
        Log.diag.debug("\(line, privacy: .public)")
    }

    private func flush() {
        guard let handle, !buffer.isEmpty else { return }
        let text = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

#else

/// Release build: the same API, doing nothing.
///
/// Every `DiagnosticLog.shared.…` call in the engine compiles against this and
/// costs nothing — `isEnabled` is a constant `false`, so the guards around the
/// expensive work fold away entirely.
final class DiagnosticLog {

    static let shared = DiagnosticLog()
    private init() {}

    var isEnabled: Bool {
        get { false }
        set { }
    }

    var currentFileURL: URL? { nil }

    func startSession(engine: EnvoEngine) {}
    func endSession(reason: String = "stopped") {}
    func tick(_ sample: DiagnosticTick) {}
    func event(_ label: String, _ detail: String = "") {}
    func mark(_ note: String) {}
    func existingLogs() -> [URL] { [] }
    func deleteAllLogs() {}
}

#endif

/// One tick's worth of everything worth knowing. A struct rather than a long
/// parameter list so the call site in `EnvoEngine.tick` stays readable and a
/// reordered column cannot silently transpose two values.
struct DiagnosticTick {
    var controlLevelDB: Float
    var aWeightedLevelDB: Float
    var bandLevelsDB: [Float]
    var floorDB: Float
    var coupling: Float
    var couplingIsMeasured: Bool
    var deliveredDB: Float
    var roomDB: Float
    var dampedRoomDB: Float
    var baselineDB: Float
    var noiseDeltaDB: Float
    var speechAtFloor: Float
    var spectralScore: Float
    var modulationDepthDB: Float
    var offsetIntentDB: Float
    var baseVolume: Float
    var systemVolume: Float
    var sliderOffset: Float
    var obstructed: Bool
    var clipping: Bool
    var playbackIdle: Bool
    var speed: String
    var rangeDB: Float
}

private extension FileManager {
    func createFile(atPath path: String) {
        if !fileExists(atPath: path) {
            createFile(atPath: path, contents: nil)
        }
    }
}
