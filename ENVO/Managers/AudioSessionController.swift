import Foundation
import AVFoundation

/// Single owner of the shared `AVAudioSession` configuration and activation.
///
/// WHY THIS EXISTS
/// ---------------
/// Previously three places configured the session — the app coordinator at
/// launch, the background-audio handler on start, and implicitly the
/// calibration tone player — and nothing owned deactivation. Two concrete
/// user-visible bugs came out of that:
///
///  1. **Launching the app made everything quieter.** The coordinator
///     activated a `.playAndRecord` session in `mode: .measurement` during
///     `onAppear`, before the user had done anything. Measurement mode
///     deliberately bypasses the output processing chain (speaker EQ and
///     dynamic-range compression) for the *whole route*, so every app's
///     playback dropped the moment ENVO was opened, and nothing ever
///     restored it.
///
///  2. Calibration and the engine could tear down each other's session.
///
/// The rules now: the session is untouched until something actually needs
/// the microphone, ownership is reference-counted, and the last client out
/// deactivates and hands the route back to whatever else is playing.
///
/// ON `mode`
/// ---------
/// `.default` rather than `.measurement`. Measurement mode gives a cleaner
/// input signal (no processing) but costs route-wide output attenuation,
/// which is unacceptable for an app whose entire job is managing how loud
/// music sounds. ENVO measures *relative* level changes against a baseline
/// captured through the same path, so input processing affects both the
/// baseline and the reading and largely cancels.
///
/// ON `.mixWithOthers`
/// -------------------
/// Mandatory. Without it, activating a record-capable session interrupts
/// whatever the user is listening to.
/// Main-thread only, like the rest of ENVO's manager layer.
final class AudioSessionController {

    static let shared = AudioSessionController()

    /// Everything that can hold the session open. Reference counting is by
    /// identity rather than an integer so a double-acquire or a double-release
    /// from a retry path cannot unbalance the count.
    enum Client: String, CaseIterable {
        case engine
        case calibration
    }

    private(set) var clients: Set<Client> = []
    private(set) var isSessionActive = false

    private var mediaResetToken: NSObjectProtocol?

    private init() {
        mediaResetToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.clients.isEmpty else { return }
            // Every session setting is gone; re-apply from scratch.
            self.isSessionActive = false
            self.applyConfiguration()
        }
    }

    // MARK: - Ownership

    /// Take a reference on the session, configuring and activating it if this
    /// is the first client. Returns false if the session could not be
    /// activated — callers must treat that as "do not proceed".
    @discardableResult
    func acquire(_ client: Client) -> Bool {
        clients.insert(client)
        return applyConfiguration()
    }

    /// Drop a reference. When the last client leaves, the session is
    /// deactivated and other apps are notified so their playback can return
    /// to its normal level and routing.
    func release(_ client: Client) {
        clients.remove(client)
        guard clients.isEmpty, isSessionActive else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            isSessionActive = false
            Log.session.info("Audio session deactivated; route returned to other apps.")
        } catch {
            // Another component may still hold it; the next acquire will
            // reconcile. Not fatal.
            Log.session.error("Session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-apply configuration after an interruption ends. No-op when nothing
    /// holds the session.
    @discardableResult
    func reactivateIfNeeded() -> Bool {
        guard !clients.isEmpty else { return false }
        isSessionActive = false
        return applyConfiguration()
    }

    // MARK: - Configuration

    @discardableResult
    private func applyConfiguration() -> Bool {
        guard !clients.isEmpty else { return false }
        if isSessionActive { return true }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)
            isSessionActive = true
            Log.session.info("Audio session active for \(self.clients.map(\.rawValue).joined(separator: ","), privacy: .public)")
            return true
        } catch {
            Log.session.error("Audio session configuration failed: \(error.localizedDescription, privacy: .public)")
            isSessionActive = false
            return false
        }
    }

    // MARK: - Diagnostics

    /// Human-readable current output route, for the calibration warning and
    /// for deciding whether a calibrated taper still applies.
    var currentOutputPortType: AVAudioSession.Port? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
    }

    var currentOutputName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "unknown"
    }

    /// What the current output route implies about how much of ENVO's own
    /// playback the built-in microphone will hear — the starting value for
    /// `SelfCouplingEstimator` before it has measured anything.
    ///
    /// Erring high is the safe direction: over-estimating coupling makes ENVO
    /// subtract more of its own output than it contributed, which makes the loop
    /// *less* willing to raise the volume. Under-estimating leaves the loop
    /// partly steering on itself, which is the fault being fixed.
    var selfCouplingPrior: Float {
        guard let port = currentOutputPortType else { return 0.35 }
        switch port {
        case .builtInSpeaker:
            // Speaker and microphone are the same object, a few centimetres
            // apart. It hears itself; the only question is how much.
            return 0.75

        case .headphones, .builtInReceiver, .bluetoothHFP, .bluetoothLE, .headsetMic:
            // Sealed or held to the ear. Essentially nothing reaches the mic.
            return 0.0

        case .bluetoothA2DP, .airPlay, .HDMI, .usbAudio, .carAudio, .lineOut:
            // Genuinely ambiguous, and not resolvable from the port type: A2DP
            // is AirPods and a room stereo alike. A middle value roughly halves
            // the worst-case gain inflation on a speaker while costing a
            // headphone listener about 12% of their compensation — and a single
            // completed observation replaces it with the truth either way.
            return 0.35

        default:
            return 0.35
        }
    }

    /// True when audio is going somewhere other than the phone's own speaker.
    var isExternalOutputRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }
}
