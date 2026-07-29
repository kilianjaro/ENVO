import Foundation

/// The adjustment decision, as a pure function.
///
/// Extracted from `EnvoEngine.tick` so it can be exercised directly by
/// tests across thousands of scenarios. This matters: the previous safety
/// argument rested on a hand-written simulation that *replicated* the tick
/// logic, which means it could agree with itself while disagreeing with the
/// shipping code. Tests now drive the same code the app runs.
///
/// Everything here is decibels. Turning decibels into slider movement is
/// `VolumeTaper`'s job and happens after this.
struct ControlLaw: Equatable {

    /// dB of volume change per dB of ambient change. Partial by design —
    /// see EnvoEngine.calibratedGain.
    var gain: Float

    /// Weight retained from the previous offset each tick.
    var smoothing: Float

    /// Adjustments smaller than this are treated as zero.
    var zeroHysteresisDB: Float

    /// Maximum rate of change of the adjustment.
    var maxRateDBPerSecond: Float

    init(gain: Float,
         smoothing: Float,
         zeroHysteresisDB: Float,
         maxRateDBPerSecond: Float) {
        self.gain = gain
        self.smoothing = smoothing
        self.zeroHysteresisDB = zeroHysteresisDB
        self.maxRateDBPerSecond = maxRateDBPerSecond
    }

    /// One tick of the loop.
    ///
    /// - Parameters:
    ///   - currentOffsetDB: the adjustment currently in force.
    ///   - noiseDeltaDB: how far the room is above (+) or below (−) the
    ///     baseline captured at START.
    ///   - rangeDB: the user's range setting — a hard limit, not a gain.
    /// - Returns: the new adjustment, guaranteed to satisfy
    ///   `abs(result) <= rangeDB` and
    ///   `abs(result - currentOffsetDB) <= maxRateDBPerSecond * dt`,
    ///   for any finite inputs.
    func nextOffsetDB(currentOffsetDB: Float,
                      noiseDeltaDB: Float,
                      rangeDB: Float,
                      allowIncrease: Bool,
                      allowDecrease: Bool,
                      dt: Float = 1.0) -> Float {
        let limit = abs(rangeDB)
        let current = currentOffsetDB.isFinite
            ? AcousticMath.clamp(currentOffsetDB, -limit, limit)
            : 0

        // An unusable reading must HOLD the current adjustment, not reset it.
        // Resetting would step the volume on exactly the ticks where we know
        // least about the room.
        guard noiseDeltaDB.isFinite else { return current }

        var intended = AcousticMath.clamp(noiseDeltaDB * gain, -limit, limit)

        // Direction filter. Note this zeroes the *intent*, so a disallowed
        // direction decays the existing offset back toward zero through the
        // smoothing term rather than freezing it in place.
        if !allowIncrease && intended > 0 { intended = 0 }
        if !allowDecrease && intended < 0 { intended = 0 }

        // Dead band, applied to the INTENT.
        //
        // Applying it to the smoothed step instead is a trap that silently
        // disables the whole app: the smoothed step approaches the intent by
        // `1 - smoothing` per tick, so from a standing start it is only
        // `0.15 × intent`. Any intent below `zeroHysteresisDB / (1 - smoothing)`
        // — 3.3 dB here, i.e. an 8 dB room change — is snapped back to zero
        // every tick and the offset can never leave the origin. That is
        // precisely the "ADJ stayed 0.0 the whole session" failure.
        //
        // Schmitt trigger rather than a plain threshold: once ENVO is
        // adjusting, it keeps adjusting until the intent falls to half the
        // engage threshold, so a room hovering at the boundary cannot chatter
        // the offset on and off.
        let isEngaged = abs(current) > 0.0001
        let deadBand = isEngaged ? zeroHysteresisDB * 0.5 : zeroHysteresisDB
        if abs(intended) < deadBand { intended = 0 }

        var next = smoothing * current + (1.0 - smoothing) * intended

        // Land exactly on zero rather than decaying toward it forever.
        if intended == 0 && abs(next) < 0.05 { next = 0 }

        let maxStep = abs(maxRateDBPerSecond * dt)
        next = AcousticMath.clamp(next, current - maxStep, current + maxStep)

        return AcousticMath.clamp(next, -limit, limit)
    }
}
