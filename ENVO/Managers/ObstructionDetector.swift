import Foundation

/// Detects that the microphone has been covered — pocket, bag, face-down on a
/// table, a hand over the bottom edge — so the engine can hold its adjustment
/// instead of steering on a measurement of fabric.
///
/// WHY THIS IS NECESSARY
/// ---------------------
/// The ambient floor is a low percentile of recent levels. That statistic is
/// robust against things getting briefly *louder* — which is what `SpikeFilter`
/// was originally built for — and maximally fragile against things getting
/// quieter, because a low percentile follows the bottom of the distribution
/// directly. Sliding the phone into a pocket drops the measured level by 15–25
/// dB in a second or two. Nothing else in the loop can tell that apart from the
/// room falling silent, so ENVO would conclude the room went quiet and turn the
/// volume down — the opposite of what the listener needs, since a pocketed
/// phone usually means they just started walking somewhere noisy.
///
/// HOW IT TELLS THE TWO APART
/// --------------------------
/// Level alone cannot distinguish them. Spectrum can. Anything covering a
/// microphone is a low-pass filter: cloth, foam, a table top and a hand all
/// attenuate 2–4 kHz far harder than 125–250 Hz. So an obstruction shows up as
/// a large level drop *accompanied by* a collapse in the high-frequency share,
/// while a room that genuinely got quieter keeps its spectral shape as it goes.
/// Requiring both conditions is what keeps this from firing every time someone
/// turns off a fan.
///
/// The reference the drop is measured against is frozen while obstructed, so a
/// long stretch in a pocket cannot slowly redefine "normal" as muffled and
/// thereby hide the obstruction from itself.
struct ObstructionDetector: Equatable {

    // MARK: - Tuning

    /// Level drop below the clear-air reference required to suspect covering.
    /// A pocket is 15–25 dB; 8 dB is comfortably inside that and comfortably
    /// above a room merely quietening.
    var dropThresholdDB: Float = 8.0

    /// The high-frequency share must also fall to this fraction of its
    /// clear-air value. This is the condition that does the actual
    /// discrimination.
    var highFrequencyCollapseRatio: Float = 0.5

    /// Level must come back to within this much of the reference to clear.
    /// Deliberately tighter than `dropThresholdDB`, so the state has hysteresis
    /// and cannot chatter while the phone is being handled.
    var clearThresholdDB: Float = 4.0

    var highFrequencyRecoveryRatio: Float = 0.75

    /// Seconds of continuous evidence before the state flips, in each direction.
    var confirmSeconds: Float = 3.0
    var clearSeconds: Float = 2.0

    /// Seconds of clear-air history needed before the detector will report
    /// anything at all.
    var warmupSeconds: Float = 5.0

    /// Time constant of the clear-air reference. Long, because it should track
    /// the room over minutes and not follow the event we are trying to catch.
    var referenceTimeConstant: Float = 20.0

    // MARK: - State

    private(set) var isObstructed = false

    private var referenceLevelDB: Float = 0
    private var referenceHighShare: Float = 0
    private var seeded = false
    private var clearAirSeconds: Float = 0
    private var candidateSeconds: Float = 0
    private var recoverySeconds: Float = 0

    init() {}

    /// Feed one reading. Call at the sample rate the engine drains at (10 Hz),
    /// not once per tick — three seconds of evidence at 1 Hz is three samples,
    /// which is not evidence.
    ///
    /// - Returns: whether the microphone is currently believed to be obstructed.
    @discardableResult
    mutating func ingest(levelDB: Float, highFrequencyShare: Float, dt: Float) -> Bool {
        guard levelDB.isFinite, highFrequencyShare.isFinite, dt > 0, dt < 5 else {
            return isObstructed
        }
        let share = AcousticMath.clamp(highFrequencyShare, 0, 1)

        guard seeded else {
            referenceLevelDB = levelDB
            referenceHighShare = share
            seeded = true
            clearAirSeconds = dt
            return false
        }

        if isObstructed {
            let levelRecovered = levelDB >= referenceLevelDB - clearThresholdDB
            let spectrumRecovered = share >= referenceHighShare * highFrequencyRecoveryRatio

            if levelRecovered || spectrumRecovered {
                recoverySeconds += dt
                if recoverySeconds >= clearSeconds {
                    isObstructed = false
                    candidateSeconds = 0
                    recoverySeconds = 0
                    // Do not resume adapting the reference instantly: let it
                    // re-seed from clear air rather than from the moment of
                    // uncovering, which is still transitional.
                    clearAirSeconds = 0
                }
            } else {
                recoverySeconds = 0
            }
            // Reference stays frozen while obstructed, deliberately.
            return isObstructed
        }

        let levelDropped = levelDB <= referenceLevelDB - dropThresholdDB
        let spectrumCollapsed = share <= referenceHighShare * highFrequencyCollapseRatio

        if levelDropped && spectrumCollapsed {
            candidateSeconds += dt
            if clearAirSeconds >= warmupSeconds, candidateSeconds >= confirmSeconds {
                isObstructed = true
                recoverySeconds = 0
            }
            // Do not fold a suspected obstruction into the reference.
            return isObstructed
        }

        candidateSeconds = 0
        clearAirSeconds += dt

        let alpha = expf(-dt / max(referenceTimeConstant, 0.1))
        referenceLevelDB = alpha * referenceLevelDB + (1 - alpha) * levelDB
        referenceHighShare = alpha * referenceHighShare + (1 - alpha) * share

        return false
    }

    mutating func reset() {
        isObstructed = false
        seeded = false
        referenceLevelDB = 0
        referenceHighShare = 0
        clearAirSeconds = 0
        candidateSeconds = 0
        recoverySeconds = 0
    }
}
