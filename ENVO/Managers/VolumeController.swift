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

    /// Bumped every time the USER changes the volume (hardware buttons,
    /// Control Center, another app's slider) rather than ENVO.
    ///
    /// The engine subscribes to this and zeroes its offset. Without it,
    /// ENVO's accumulated offset survived a manual adjustment and was
    /// re-applied on top of the new baseline on the very next tick — so
    /// turning the volume down by hand produced an immediate shove back up.
    /// A manual adjustment is the user restating what "normal" means; the
    /// only correct response is to start again from zero.
    @Published private(set) var userAdjustmentCount: Int = 0

    /// True while ENVO can actually move the output level.
    ///
    /// Some routes do not give the app a system volume to move at all. AirPlay
    /// to a receiver, HDMI and many external DACs keep their own level and iOS
    /// responds by removing the slider from `MPVolumeView` entirely — at which
    /// point every write ENVO makes is a silent no-op while the UI cheerfully
    /// reports an adjustment. A controller that cannot tell the user it is
    /// powerless is worse than one that does nothing.
    @Published private(set) var isVolumeControlAvailable: Bool = true

    /// The step the hardware actually quantizes to, measured rather than
    /// assumed. See `VolumeController.defaultVolumeStep`.
    @Published private(set) var volumeStep: Float = VolumeController.defaultVolumeStep

    /// The offset the hardware actually settled on, as opposed to the one
    /// ENVO requested. These differ whenever the system quantizes the volume
    /// to discrete steps. This is the ground truth for "what did ENVO actually
    /// do", and `SelfCouplingEstimator` needs exactly that: attributing a
    /// contribution ENVO merely *asked* for would corrupt the estimate by up to
    /// half a step every time.
    var achievedOffset: Float {
        AVAudioSession.sharedInstance().outputVolume - baseVolume
    }

    /// Hard limit on how far ENVO may ever move the slider from the user's
    /// baseline, regardless of what the engine asks for. A last line of
    /// defence independent of the taper, the range setting and the rate
    /// limiter — all of which are also enforced upstream.
    ///
    static let maxAbsoluteOffset: Float = 0.25

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

    /// Starting assumption for the granularity of the iOS system volume.
    ///
    /// Measured on one device and one route: logging requested-vs-achieved for
    /// every write produced only the values 0.50, 0.55 and 0.60 — round-to-
    /// nearest on a 0.05 grid, twenty steps.
    ///
    /// That is *not* universal. Headphone and Bluetooth routes commonly use
    /// sixteen steps (0.0625), and hard-coding the wrong one has two concrete
    /// consequences: the post-snap guard below (half a step) silently discards
    /// writes that land between the assumed grid and the real one, and the echo
    /// threshold can drift close enough to a real step to swallow a genuine
    /// user press. So this is only the starting value — `observeStepFrom`
    /// narrows it to whatever the hardware is actually doing.
    ///
    /// A single step is worth roughly 3 dB of actual loudness, which is the
    /// entire ±3 dB range setting, so getting it right matters.
    static let defaultVolumeStep: Float = 0.05

    /// Grids iOS is known to use. The probe snaps to the nearest of these
    /// rather than believing an arbitrary measured difference, because two
    /// user presses in quick succession can look like one large step.
    private static let knownStepGrids: [Float] = [1.0 / 16.0, 0.05]

    /// Smallest genuine inter-step difference seen so far this session.
    private var smallestObservedDelta: Float = .greatestFiniteMagnitude

    /// Consecutive ENVO writes that never showed up on the output.
    private var failedWriteStreak = 0
    private let failedWriteLimit = 3

    /// Proximity threshold for "matches what ENVO requested".
    ///
    /// Must be BELOW one volume step, or a user pressing the volume button
    /// once within `envoWindow` of an ENVO write looks exactly like our own
    /// echo — and "the user always wins" quietly stops being true. It must
    /// also stay above our own worst-case snapping error, which is ~0 now
    /// that targets are pre-snapped to the grid.
    private let envoMatchThreshold: Float = 0.03

    /// How far the desired volume must sit from the current one before ENVO
    /// moves to a different step, as a fraction of one step.
    ///
    /// Without this, an intent hovering near a step boundary flips the output
    /// back and forth by a whole step — about 3 dB — every few seconds. A real
    /// 25-second sample showed three such transitions, which is audible pumping
    /// produced entirely by quantization rather than by the room.
    /// Round-to-nearest alone switches at half a step, which is no protection
    /// at all; anything above 0.5 buys a dead zone either side of every boundary.
    ///
    /// **This is the responsiveness dial, and it is the one to revert first.**
    /// It sets how much the room has to change before ENVO does anything:
    ///
    ///     0.75  →  the room must rise ~5.8 dB before the first step
    ///     0.60  →  ~4.6 dB, with a 1.5 dB dead zone remaining
    ///     0.50  →  ~3.8 dB, and no dead zone whatsoever — chatter returns
    ///
    /// 0.60 is a deliberate trade: noticeably more willing to act, at the cost
    /// of a narrower guard than the pumping incident originally called for. It
    /// is defensible now only because the measurement underneath is far steadier
    /// than it was then — the floor is an L90 over hundreds of samples rather
    /// than a percentile over ten — so the intent no longer jitters across
    /// boundaries on its own.
    ///
    /// If a session log shows repeated `volume-step` events alternating up and
    /// down within a few seconds, that is this constant. Put it back to 0.75.
    private let stepHysteresis: Float = 0.60

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
        guard !isSetUp else {
            // Called again on every scene activation: if the first setup ran
            // before any window existed, the MPVolumeView has no superview
            // and every slider write is a silent no-op. Re-attach now.
            attachToWindowIfNeeded()
            return
        }
        isSetUp = true

        let realVolume = AVAudioSession.sharedInstance().outputVolume
        baseVolume = realVolume
        currentVolume = realVolume

        let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        vv.alpha = 0.01
        vv.showsVolumeSlider = true
        self.volumeView = vv

        attachToWindowIfNeeded()
        findSlider(in: vv, retries: 15)

        // Observe ALL system volume changes.
        let session = AVAudioSession.sharedInstance()
        setupVolumeObservation(session)
    }

    private func attachToWindowIfNeeded() {
        guard let vv = volumeView, vv.window == nil else { return }
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
    }

    private func setupVolumeObservation(_ session: AVAudioSession) {
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
                refreshAvailability()
                return
            }
        }
        if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak vv] in
                guard let self = self, let vv = vv else { return }
                self.findSlider(in: vv, retries: retries - 1)
            }
        } else {
            // MPVolumeView never produced a slider. On routes that own their own
            // level there is nothing to produce.
            Log.volume.error("No system volume slider available on this route; ENVO cannot change the level.")
            isVolumeControlAvailable = false
        }
    }

    // MARK: - Availability

    /// Re-evaluate whether ENVO can move this route's level. Called on setup and
    /// whenever the route changes.
    func refreshAvailability() {
        failedWriteStreak = 0

        guard volumeSlider != nil else {
            isVolumeControlAvailable = false
            return
        }

        // AirPlay to a receiver, and anything behind it, keeps its own volume.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let ownsItsOwnLevel = outputs.contains { output in
            output.portType == .airPlay || output.portType == .HDMI
        }
        isVolumeControlAvailable = !ownsItsOwnLevel
    }

    // MARK: - Step probing

    /// Learn the hardware's real volume quantum from the changes it reports.
    ///
    /// Only user-driven changes are used. ENVO's own writes are pre-snapped to
    /// whatever grid is currently believed, so feeding them back in would just
    /// confirm the existing guess.
    private func observeStepFrom(_ delta: Float) {
        let magnitude = abs(delta)
        // Below 0.02 is float noise; above 0.15 is a Control Center drag or
        // several presses, which says nothing about the quantum.
        guard magnitude >= 0.02, magnitude <= 0.15 else { return }
        guard magnitude < smallestObservedDelta else { return }
        smallestObservedDelta = magnitude

        // Snap to the nearest grid iOS is known to use rather than trusting the
        // raw number: two quick presses look like one double-size step.
        var best = VolumeController.knownStepGrids[0]
        var bestError = Float.greatestFiniteMagnitude
        for grid in VolumeController.knownStepGrids {
            // A genuine observation is an integer multiple of the grid.
            let multiples = (magnitude / grid).rounded()
            guard multiples >= 1 else { continue }
            let error = abs(magnitude - multiples * grid)
            if error < bestError {
                bestError = error
                best = grid
            }
        }

        guard bestError < 0.01, abs(best - volumeStep) > 0.0001 else { return }
        Log.volume.info("System volume quantum measured as \(best, format: .fixed(precision: 4)) (was \(self.volumeStep, format: .fixed(precision: 4))).")
        DiagnosticLog.shared.event("volume-quantum-measured", String(
            format: "%.4f (was %.4f, from an observed delta of %.4f)", best, volumeStep, magnitude))
        volumeStep = best
    }

    // MARK: - Volume Change Detection

    private func handleVolumeChange(_ newVolume: Float) {
        let previousVolume = currentVolume
        currentVolume = newVolume

        // Any change at all proves the route responds to volume, which is the
        // strongest possible evidence that control is available.
        failedWriteStreak = 0

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

                // What the hardware ACTUALLY did, which is not necessarily what
                // we asked for: the system quantizes to discrete steps, so a
                // requested target lands on the nearest one. Everything upstream
                // reasons about a continuous slider, so this is the only place
                // the difference is visible — and `achievedOffset` above is what
                // the self-coupling estimator reads rather than the request.
                let error = newVolume - target
                if abs(error) > 0.002 {
                    Log.volume.info(
                        "Volume write requested \(target, format: .fixed(precision: 4)) → achieved \(newVolume, format: .fixed(precision: 4)) (error \(error, format: .fixed(precision: 4)))"
                    )
                }
            } else if let echo = consumedEnvoEcho,
                      abs(newVolume - echo) < 0.001 {
                // Duplicate KVO delivery of the same echo value.
                wasEnvo = true
            }
        }

        if !wasEnvo {
            // USER changed the volume. This is the new baseline — always respect it.
            // Their presses are also the only honest sample of the hardware's
            // quantum, since ENVO's own writes are pre-snapped to the current
            // guess and would only confirm it.
            observeStepFrom(newVolume - previousVolume)
            DiagnosticLog.shared.event("user-volume-change", String(
                format: "%.3f -> %.3f (%+.1f steps); baseline re-anchored",
                previousVolume, newVolume, (newVolume - previousVolume) / volumeStep))

            baseVolume = newVolume
            appliedOffset = 0.0
            lastEnvoTarget = nil
            consumedEnvoEcho = nil
            // Tell the engine to drop its accumulated offset too, or it will
            // re-apply the old one against this new baseline next tick.
            userAdjustmentCount &+= 1
        }
    }

    // MARK: - Public API

    /// Apply an offset relative to the user's base volume.
    /// Only actually changes the system volume if the resulting target
    /// is meaningfully different from what's already set.
    func applyOffset(_ offset: Float) {
        guard isSetUp, offset.isFinite else { return }

        // Final, taper-independent safety clamp. Everything upstream already
        // bounds this; that is the point — a bound worth having is a bound
        // enforced at the place that actually touches the hardware.
        let bounded = clamp(offset,
                            -VolumeController.maxAbsoluteOffset,
                            VolumeController.maxAbsoluteOffset)

        appliedOffset = bounded

        let desired = clamp(baseVolume + bounded)
        let currentSystemVol = AVAudioSession.sharedInstance().outputVolume

        // Hysteresis at the quantizer. The hardware can only sit on discrete
        // steps, so writing every small change means the output flips between
        // steps whenever the intent drifts across a boundary — a ~3 dB jump
        // caused by rounding, not by the room.
        guard abs(desired - currentSystemVol)
                >= volumeStep * stepHysteresis else { return }

        // Pre-snap to the grid the hardware will round to anyway. This makes
        // the KVO echo an exact match rather than an approximate one, which is
        // what lets the echo threshold sit safely below one step.
        let target = snappedToStep(desired)
        guard abs(target - currentSystemVol) >= volumeStep * 0.5 else { return }

        // Apply it. Mark the timestamp BEFORE the slider write so the KVO
        // callback fires while we're still inside the envoWindow.
        lastEnvoTarget = target
        lastEnvoChangeTime = Date()

        // The single most informative line in a tuning session: every discrete
        // step the listener could actually hear, with the intent that caused it.
        DiagnosticLog.shared.event("volume-step", String(
            format: "%.3f -> %.3f (base %.3f, offset %+.3f, %+.1f steps)",
            currentSystemVol, target, baseVolume, bounded,
            (target - currentSystemVol) / volumeStep))

        DispatchQueue.main.async { [weak self] in
            self?.volumeSlider?.value = target
            self?.volumeSlider?.sendActions(for: .valueChanged)
            self?.currentVolume = target
        }

        verifyWriteLanded(target: target)
    }

    /// Check, shortly after a write, that the output actually moved.
    ///
    /// On a route that owns its own level the slider write succeeds silently and
    /// changes nothing. Without this, ENVO reports adjustments it never made for
    /// as long as the user stays on that route — and the readout is the only
    /// thing they have to judge the app by.
    private func verifyWriteLanded(target: Float) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            if abs(actual - target) <= self.volumeStep * 0.75 {
                self.failedWriteStreak = 0
                if !self.isVolumeControlAvailable { self.refreshAvailability() }
                return
            }
            self.failedWriteStreak += 1
            if self.failedWriteStreak >= self.failedWriteLimit, self.isVolumeControlAvailable {
                Log.volume.error("Volume writes are not landing on this route; marking control unavailable.")
                DiagnosticLog.shared.event("volume-control-unavailable", String(
                    format: "%d writes did not land; last target %.3f, actual %.3f",
                    self.failedWriteStreak, target, actual))
                self.isVolumeControlAvailable = false
            }
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
        refreshAvailability()
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

    /// Restore a volume captured before calibration and re-anchor the
    /// baseline to it. `setVolumeImmediate` alone leaves `baseVolume` holding
    /// whatever the sweep last wrote, so the VOL readout stayed wrong after
    /// calibration finished.
    func restoreVolume(_ volume: Float) {
        setVolumeImmediate(volume)
        let clamped = clamp(volume)
        baseVolume = clamped
        currentVolume = clamped
        appliedOffset = 0.0
    }

    /// Round to the nearest achievable system-volume step.
    func snappedToStep(_ value: Float) -> Float {
        let step = volumeStep
        return clamp((value / step).rounded() * step)
    }

    private func clamp(_ value: Float) -> Float {
        return min(max(value, 0.0), 1.0)
    }

    private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        return min(max(value, lo), hi)
    }
}
