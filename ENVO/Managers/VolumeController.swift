import Foundation
import MediaPlayer
import UIKit
import AVFoundation

/// Controls the iOS system output volume.
///
/// DESIGN PRINCIPLE: User volume changes ALWAYS take priority.
/// ENVO only nudges the volume when there's a meaningful change to make.
/// The user can adjust volume at any time — in-app, backgrounded, locked,
/// active or standby — and ENVO will respect that as the new baseline.
///
/// Call setup() ONLY after the UI window exists.
final class VolumeController: ObservableObject {

    // MARK: - Published State

    /// The user's chosen base volume. Updated whenever the user presses
    /// hardware buttons or uses Control Center. This is ALWAYS respected.
    @Published private(set) var baseVolume: Float = 0.5

    /// The actual system volume right now.
    @Published private(set) var currentVolume: Float = 0.5

    // MARK: - Private

    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var volumeObservation: NSKeyValueObservation?
    private var isSetUp = false

    /// Timestamp of the last volume change made by ENVO.
    /// Any system volume change within `envoWindow` of this is ours.
    private var lastEnvoChangeTime: Date = .distantPast

    /// The exact value we last told the slider to set.
    private var lastEnvoTarget: Float?

    /// The KVO value that was already accepted as our own echo. The echo
    /// match is one-shot — otherwise a real user button press landing
    /// within `envoWindow` and `envoMatchThreshold` of our target gets
    /// swallowed and ENVO fights the user on the next tick. Duplicate
    /// deliveries of the SAME value still match here (a user press always
    /// differs by ≥ one hardware step ≈ 0.0625, far above the epsilon).
    private var consumedEnvoEcho: Float?

    /// Time window: changes within this period after an ENVO set = ours.
    /// Increased from 0.3s to comfortably cover main-thread back-pressure
    /// and the KVO round-trip on heavily-loaded devices.
    private let envoWindow: TimeInterval = 0.8

    /// Proximity threshold for "matches what ENVO requested".
    /// MUST be ≥ one iOS hardware volume step (1/16 ≈ 0.0625), otherwise
    /// the system's quantization of our requested target gets misclassified
    /// as a user gesture, and `baseVolume` drifts every time ENVO nudges.
    private let envoMatchThreshold: Float = 0.08

    /// Minimum offset change worth applying (avoids constant micro-nudges).
    private let minimumChangeThreshold: Float = 0.004

    /// The offset ENVO is currently applying.
    private var appliedOffset: Float = 0.0

    // MARK: - Lifecycle

    init() {}

    deinit {
        volumeObservation?.invalidate()
        volumeView?.removeFromSuperview()
    }

    // MARK: - Deferred Setup

    func setup() {
        guard !isSetUp else { return }
        isSetUp = true

        let realVolume = AVAudioSession.sharedInstance().outputVolume
        baseVolume = realVolume
        currentVolume = realVolume

        let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        vv.alpha = 0.01
        vv.showsVolumeSlider = true

        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            let window: UIWindow?
            if #available(iOS 15.0, *) {
                window = scene.keyWindow ?? scene.windows.first
            } else {
                window = scene.windows.first
            }
            window?.addSubview(vv)
        }

        findSlider(in: vv, retries: 15)
        self.volumeView = vv

        // Observe ALL system volume changes.
        let session = AVAudioSession.sharedInstance()
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self = self, let newVolume = change.newValue else { return }
            DispatchQueue.main.async {
                self.handleVolumeChange(newVolume)
            }
        }
    }

    private func findSlider(in vv: MPVolumeView, retries: Int) {
        for subview in vv.subviews {
            if let slider = subview as? UISlider {
                self.volumeSlider = slider
                return
            }
        }
        if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak vv] in
                guard let self = self, let vv = vv else { return }
                self.findSlider(in: vv, retries: retries - 1)
            }
        }
    }

    // MARK: - Volume Change Detection

    private func handleVolumeChange(_ newVolume: Float) {
        currentVolume = newVolume

        // Was this change made by ENVO?
        let timeSinceEnvoChange = Date().timeIntervalSince(lastEnvoChangeTime)
        var wasEnvo = false

        if timeSinceEnvoChange < envoWindow {
            if let target = lastEnvoTarget,
               abs(newVolume - target) < envoMatchThreshold {
                // First (possibly route-quantized) echo of our own write.
                // Consume the target so a user press later in the window
                // is not mistaken for another echo.
                wasEnvo = true
                lastEnvoTarget = nil
                consumedEnvoEcho = newVolume
            } else if let echo = consumedEnvoEcho,
                      abs(newVolume - echo) < 0.001 {
                // Duplicate KVO delivery of the same echo value.
                wasEnvo = true
            }
        }

        if !wasEnvo {
            // USER changed the volume. This is the new baseline — always respect it.
            // Reset appliedOffset so the next applyOffset() is computed against
            // the fresh baseline, not the old one.
            baseVolume = newVolume
            appliedOffset = 0.0
            lastEnvoTarget = nil
            consumedEnvoEcho = nil
        }
    }

    // MARK: - Public API

    /// Apply an offset relative to the user's base volume.
    /// Only actually changes the system volume if the resulting target
    /// is meaningfully different from what's already set.
    func applyOffset(_ offset: Float) {
        guard isSetUp else { return }

        // Is this offset meaningfully different from what's already applied?
        let diff = abs(offset - appliedOffset)
        guard diff >= minimumChangeThreshold else { return }

        appliedOffset = offset
        let target = clamp(baseVolume + offset)

        // Is the target meaningfully different from the current volume?
        let currentSystemVol = AVAudioSession.sharedInstance().outputVolume
        guard abs(target - currentSystemVol) >= minimumChangeThreshold else { return }

        // Apply it. Mark the timestamp BEFORE the slider write so the KVO
        // callback fires while we're still inside the envoWindow.
        lastEnvoTarget = target
        lastEnvoChangeTime = Date()

        DispatchQueue.main.async { [weak self] in
            self?.volumeSlider?.value = target
            self?.volumeSlider?.sendActions(for: .valueChanged)
            self?.currentVolume = target
        }
    }

    /// Remove the ENVO offset entirely.
    /// Writes the slider synchronously when called from the main thread so
    /// a subsequent captureBaseVolume() reads the restored value rather
    /// than the still-offset one.
    func clearOffset() {
        guard isSetUp else { return }
        appliedOffset = 0.0

        let target = baseVolume
        let currentSystemVol = AVAudioSession.sharedInstance().outputVolume
        guard abs(target - currentSystemVol) >= minimumChangeThreshold else { return }

        lastEnvoTarget = target
        lastEnvoChangeTime = Date()

        let write: () -> Void = { [weak self] in
            self?.volumeSlider?.value = target
            self?.volumeSlider?.sendActions(for: .valueChanged)
            self?.currentVolume = target
        }
        if Thread.isMainThread {
            write()
        } else {
            DispatchQueue.main.async(execute: write)
        }
    }

    /// Snapshot the current system volume as the new baseline.
    func captureBaseVolume() {
        let vol = AVAudioSession.sharedInstance().outputVolume
        baseVolume = vol
        currentVolume = vol
        appliedOffset = 0.0
        lastEnvoTarget = nil
        consumedEnvoEcho = nil
    }

    /// Set volume immediately (used by calibration only).
    func setVolumeImmediate(_ volume: Float) {
        guard isSetUp else { return }
        let clamped = clamp(volume)
        lastEnvoTarget = clamped
        lastEnvoChangeTime = Date()

        DispatchQueue.main.async { [weak self] in
            self?.volumeSlider?.value = clamped
            self?.volumeSlider?.sendActions(for: .valueChanged)
            self?.currentVolume = clamped
        }
    }

    private func clamp(_ value: Float) -> Float {
        return min(max(value, 0.0), 1.0)
    }
}
