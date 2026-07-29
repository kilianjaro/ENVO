import Foundation

/// Measures how much of the ambient floor is ENVO's own doing, and removes it.
///
/// THE PROBLEM
/// -----------
/// `AmbientTracker` reads the room from the quiet moments of the programme
/// material. That works well for speech: a podcast drops to the room level
/// between sentences, so the low percentile lands on the room and the
/// microphone barely hears the phone. It works far less well for dense modern
/// music played on a speaker. A mastered pop track has a loudness range of
/// three to eight decibels — the whole distribution is narrow, there are no
/// real gaps, and the low percentile lands a few dB under the *music*, not on
/// the room.
///
/// When that happens the loop is partly listening to itself. ENVO raises the
/// volume, the floor it measures rises with it, and it reads its own output as
/// the room getting louder. The loop still converges — the range clamp and a
/// design gain of 0.4 guarantee that — but the effective gain becomes
/// `0.4 / (1 − 0.4) ≈ 0.67` rather than the 0.4 it was tuned for, and the
/// controller is partly steering on its own output.
///
/// THE FIX
/// -------
/// ENVO knows exactly when it moved the volume and by exactly how many
/// decibels. That makes its own adjustment a *probe signal*: step the output by
/// a known amount, watch what the measured floor does, and the ratio between
/// them is how much of the floor is the device rather than the room.
///
///     coupling = Δfloor / Δdelivered
///
/// On headphones the microphone hears none of the playback, the floor does not
/// move, and coupling settles at ~0 — no correction, correctly. On a speaker
/// playing dense music the floor tracks the step almost exactly, coupling
/// settles near 1, and `roomLevelDB` subtracts the device's whole contribution
/// so the control law sees the room again.
///
/// This is ordinary closed-loop system identification with the controller's own
/// step as the excitation.
///
/// WHY THERE IS ALSO A PRIOR
/// -------------------------
/// Identification alone is not enough, and it is worth being blunt about why.
/// ENVO steps rarely — the whole point of the design is that it does — and when
/// it does step during a transient, the next step often arrives before the
/// previous probe has settled, which invalidates it. Simulating the closed loop
/// shows the estimator completing roughly one usable observation per transient
/// and then, once the loop settles, none at all. Worse, the excitation is not
/// independent of the disturbance: ENVO steps *because* the room changed, so a
/// regression over ordinary operation cannot separate the two even in principle
/// without a dither signal, and a dither here would be an audible 3 dB nudge.
///
/// So the measurement is treated as a refinement, not a foundation. The starting
/// value comes from the output route, which is genuinely informative: the
/// built-in speaker is on the same object as the microphone and certainly
/// couples, wired headphones certainly do not. `AudioSessionController` supplies
/// it. A completed observation overrides the prior outright — a direct
/// measurement beats a category guess — and later ones smooth in.
///
/// The ambiguous case is Bluetooth A2DP, where the port type cannot distinguish
/// AirPods (coupling ~0) from a room stereo (coupling ~1). That gets a middle
/// prior, which halves the worst-case gain inflation on a speaker without
/// meaningfully suppressing adaptation on headphones. See the note there.
///
/// SAFETY OF THE FAILURE MODES
/// ---------------------------
/// Both directions of error are benign, which is why the estimate is allowed to
/// act at all:
///
///   * **Under-estimated** coupling leaves some self-listening in place — the
///     behaviour that shipped before this type existed.
///   * **Over-estimated** coupling subtracts more than ENVO contributed, which
///     makes the loop *less* willing to raise the volume. Over-correction is
///     negative feedback on ENVO's own output; it can only damp.
///
/// The estimate starts at zero and stays there until several consistent
/// observations agree, so an unconverged estimator behaves exactly like no
/// estimator.
struct SelfCouplingEstimator: Equatable {

    // MARK: - Tuning

    /// Smallest delivered change worth treating as a probe. One hardware step
    /// is worth roughly 3 dB, so anything under 1 dB is quantisation noise
    /// rather than a step.
    var minStepDB: Float = 1.0

    /// What the output route implies about coupling, before any measurement.
    /// Set by the engine on start and on every route change. See the type
    /// comment for why this exists rather than starting from zero.
    var prior: Float = 0

    /// Ticks to wait after a step before reading the result.
    ///
    /// The floor is a percentile over the response window, so it takes about a
    /// full window to reflect a step. The engine sets this from the current
    /// RESPONSE setting, capped: waiting a full sixty seconds on the SLOW
    /// setting makes an observation almost impossible to complete without a
    /// second step interrupting it. A value shorter than the true settling time
    /// reads the floor before it has finished moving and therefore
    /// *under*-estimates coupling — the safe direction, since under-correction
    /// merely leaves the pre-existing behaviour in place.
    var settleTicks: Int = 20

    /// Ticks averaged either side of the step.
    var windowTicks: Int = 5

    /// An observation is discarded if the floor was already moving this much
    /// before the step, because then the change afterwards cannot be
    /// attributed to the step rather than to the room.
    var maxPreSpreadDB: Float = 2.0

    /// Weight retained from the running estimate per accepted observation after
    /// the first. The first replaces the prior outright.
    var retention: Float = 0.75

    // MARK: - State

    private var preWindow: [Float] = []
    private var postWindow: [Float] = []
    private var lastDeliveredDB: Float = 0
    private var hasDelivered = false

    private var pendingPreFloor: Float?
    private var pendingStepDB: Float = 0
    private var pendingDeliveredAfter: Float = 0
    private var ticksSinceStep = 0

    private var smoothed: Float?
    private(set) var observationCount: Int = 0

    /// How much of the measured floor is ENVO's own output, 0…1.
    /// The route-implied prior until something has actually been measured.
    var coupling: Float {
        AcousticMath.clamp(smoothed ?? prior, 0, 1)
    }

    /// True once this rests on a measurement rather than on the route category.
    var isMeasured: Bool { smoothed != nil }

    init() {}

    // MARK: - Use

    /// The room level, with ENVO's own contribution removed.
    ///
    /// `deliveredDB` is what the hardware actually produced relative to the
    /// user's baseline — not what the control law asked for. The two differ by
    /// up to half a hardware step, and using the request would attribute a
    /// contribution ENVO never made.
    func roomLevelDB(fromFloorDB floorDB: Float, deliveredDB: Float) -> Float {
        guard floorDB.isFinite, deliveredDB.isFinite else { return floorDB }
        return floorDB - coupling * deliveredDB
    }

    /// One tick of observation. Call once per engine tick, always — the state
    /// machine needs to see the ticks where nothing happened too.
    mutating func ingest(floorDB: Float, deliveredDB: Float) {
        guard floorDB.isFinite, deliveredDB.isFinite else { return }

        defer {
            lastDeliveredDB = deliveredDB
            hasDelivered = true
        }

        guard hasDelivered else {
            append(&preWindow, floorDB)
            return
        }

        let stepDB = deliveredDB - lastDeliveredDB

        if pendingPreFloor == nil {
            // Idle: keep a rolling picture of the floor before any step, and
            // watch for one.
            if abs(stepDB) >= minStepDB, preWindow.count >= windowTicks,
               spread(preWindow) <= maxPreSpreadDB {
                pendingPreFloor = mean(preWindow)
                pendingStepDB = stepDB
                pendingDeliveredAfter = deliveredDB
                ticksSinceStep = 0
                postWindow.removeAll(keepingCapacity: true)
            } else {
                append(&preWindow, floorDB)
            }
            return
        }

        // An observation is in flight. A second step before it finishes makes
        // the result unattributable — abandon rather than guess.
        if abs(deliveredDB - pendingDeliveredAfter) >= minStepDB {
            abandonPending(restartingFrom: floorDB)
            return
        }

        ticksSinceStep += 1
        guard ticksSinceStep > settleTicks else { return }

        postWindow.append(floorDB)
        guard postWindow.count >= windowTicks else { return }

        if let pre = pendingPreFloor, abs(pendingStepDB) >= minStepDB {
            let observed = (mean(postWindow) - pre) / pendingStepDB
            // Clamp before smoothing: a wild single observation (the room
            // changed during the probe) must not be able to drag the estimate
            // somewhere the physics does not allow.
            let bounded = AcousticMath.clamp(observed, 0, 1.2)
            // The first measurement replaces the route-implied guess outright;
            // afterwards they smooth together.
            smoothed = smoothed.map { retention * $0 + (1 - retention) * bounded }
                ?? bounded
            observationCount += 1
        }

        abandonPending(restartingFrom: floorDB)
    }

    mutating func reset() {
        preWindow.removeAll()
        postWindow.removeAll()
        lastDeliveredDB = 0
        hasDelivered = false
        pendingPreFloor = nil
        pendingStepDB = 0
        pendingDeliveredAfter = 0
        ticksSinceStep = 0
        smoothed = nil
        observationCount = 0
    }

    /// Throw away an observation in flight but keep what has been learned.
    ///
    /// Used when the baseline is re-anchored — a manual volume change resets
    /// `deliveredDB` to zero, which looks exactly like a step ENVO made but is
    /// not one, and attributing the floor's subsequent behaviour to it would
    /// poison the estimate. The coupling itself is a property of the route and
    /// the programme material, neither of which a re-anchor changes, so it is
    /// worth keeping.
    mutating func discardObservationInProgress() {
        pendingPreFloor = nil
        pendingStepDB = 0
        ticksSinceStep = 0
        postWindow.removeAll()
        preWindow.removeAll()
        hasDelivered = false
    }

    // MARK: - Helpers

    private mutating func abandonPending(restartingFrom floorDB: Float) {
        pendingPreFloor = nil
        pendingStepDB = 0
        ticksSinceStep = 0
        postWindow.removeAll(keepingCapacity: true)
        preWindow.removeAll(keepingCapacity: true)
        append(&preWindow, floorDB)
    }

    private func append(_ buffer: inout [Float], _ value: Float) {
        buffer.append(value)
        if buffer.count > windowTicks {
            buffer.removeFirst(buffer.count - windowTicks)
        }
    }

    private func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    private func spread(_ values: [Float]) -> Float {
        guard let lo = values.min(), let hi = values.max() else { return .infinity }
        return hi - lo
    }
}
