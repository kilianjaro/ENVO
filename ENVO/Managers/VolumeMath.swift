import Foundation

/// Maps between "how many dB louder/quieter" and "how far to move the iOS
/// volume slider".
///
/// WHY THE PREVIOUS MODEL WAS WRONG
/// --------------------------------
/// The original implementation assumed `outputVolume` is proportional to
/// amplitude, so `+6 dB` became `slider × 2`. It is not. The iOS volume
/// control is a *tapered fader*: its 16 steps span roughly 45–55 dB of
/// acoustic range, so halving the slider is far more than −6 dB. Requesting
/// ±6 dB through the old model produced a slider move that delivered
/// something closer to ±14 dB — the range bound leaked here, not in the
/// engine's clamp (which was correct all along).
///
/// WHAT THIS DOES INSTEAD
/// ----------------------
/// A taper is a monotonic curve `volume → gain in dB`, relative to a full
/// slider. Two sources:
///
///   * `.default` — a linear-in-dB fader spanning `defaultSpanDB`. Used
///     before calibration, and whenever the current output route is not the
///     one that was calibrated.
///   * `.measured(from:)` — built from the calibration sweep, which is a
///     direct acoustic measurement of *this* device's curve. After a good
///     calibration, "±6 dB" means ±6 dB on the user's own hardware.
///
/// BOUND SAFETY
/// ------------
/// `volumeDelta` inverts the taper exactly, so the delivered change equals
/// the requested change **for whatever taper is in use**. The remaining
/// question is only whether the taper is right, and that has one honest
/// answer per state:
///
///   * Calibrated, same route — the taper is measured, so the bound is exact.
///   * Otherwise — the default span is deliberately set at the *steep* end of
///     what any iOS route plausibly does. Assuming a steeper curve than
///     reality means each requested dB maps to a smaller slider move, so ENVO
///     under-delivers. A ±6 dB setting may produce ±4.5 dB on a device whose
///     real curve is shallower. Under-delivering is a disappointment;
///     over-delivering is the bug that was reported.
///
/// It is not possible to both guarantee the bound and deliver the promised
/// amount without measuring the device. Calibration is what buys accuracy.
struct VolumeTaper: Equatable {

    /// Assumed dB per full slider before calibration measures the real curve.
    ///
    /// Set at the steep end on purpose — see BOUND SAFETY above. Published
    /// measurements of iPhone speaker output put the real figure closer to
    /// 45–50 dB, so this errs toward moving the slider less than needed.
    static let defaultSpanDB: Float = 60.0

    /// Unconditional limit on how far ENVO may move the slider, whatever the
    /// taper, the range or the control law say. Enforced again at the point
    /// of application in `VolumeController`, because a limit is only worth
    /// having where it actually touches the hardware.
    static let absoluteMaxDelta: Float = 0.25

    /// Below this the slider is effectively muted and the curve is not
    /// invertible. Clamping here keeps every function total.
    static let minVolume: Float = 1.0 / 32.0

    /// Knots of the curve, sorted by volume with strictly increasing gain.
    /// `gainDB` is relative to a full slider, so `gainDB` at volume 1 is 0
    /// and every other knot is negative.
    private let knots: [Knot]

    struct Knot: Equatable {
        let volume: Float
        let gainDB: Float
    }

    // MARK: - Construction

    static let `default` = VolumeTaper(spanDB: defaultSpanDB)

    /// Linear-in-dB fader with a slope of exactly `spanDB` per full slider.
    init(spanDB: Float) {
        let span = max(6.0, spanDB)
        self.knots = [
            Knot(volume: VolumeTaper.minVolume,
                 gainDB: -span * (1.0 - VolumeTaper.minVolume)),
            Knot(volume: 1.0, gainDB: 0.0)
        ]
    }

    /// Builds a taper from measured (volume, gain-in-dB) pairs.
    ///
    /// Returns `nil` unless the data actually describes a usable curve:
    /// at least two points, strictly increasing in volume, and monotonically
    /// increasing in gain with a total span in a physically sensible range.
    /// A calibration that produced flat or non-monotonic data is a failed
    /// calibration, and silently accepting it would be worse than not
    /// calibrating at all.
    init?(measuredPoints: [(volume: Float, gainDB: Float)]) {
        let sorted = measuredPoints
            .filter { $0.volume.isFinite && $0.gainDB.isFinite }
            .sorted { $0.volume < $1.volume }
        guard sorted.count >= 2 else { return nil }

        // Normalize so the loudest measured point is the 0 dB reference.
        let reference = sorted[sorted.count - 1].gainDB

        var built: [Knot] = []
        for point in sorted {
            let volume = AcousticMath.clamp(point.volume, VolumeTaper.minVolume, 1.0)
            let gain = point.gainDB - reference
            // Strictly increasing in both axes, or the curve is not a
            // function we can invert.
            if let last = built.last {
                guard volume > last.volume + 0.001,
                      gain > last.gainDB + 0.25 else { continue }
            }
            built.append(Knot(volume: volume, gainDB: gain))
        }

        guard built.count >= 2 else { return nil }

        // Sanity-check the implied full-slider span. A sweep that says the
        // slider spans 5 dB, or 120 dB, measured something other than the
        // speaker (masking noise, a dead mic, a route change mid-sweep).
        let first = built[0], last = built[built.count - 1]
        let impliedSpan = (last.gainDB - first.gainDB) / (last.volume - first.volume)
        guard impliedSpan >= 12.0, impliedSpan <= 90.0 else { return nil }

        self.knots = built
    }

    // MARK: - Curve

    /// Gain in dB at a slider position, relative to a full slider.
    /// Extrapolates beyond the measured endpoints using the end segment's
    /// slope, so an uncalibrated corner of the range still behaves sanely.
    func gainDB(atVolume volume: Float) -> Float {
        let v = AcousticMath.clamp(volume, VolumeTaper.minVolume, 1.0)

        if v <= knots[0].volume {
            let a = knots[0], b = knots[1]
            let slope = (b.gainDB - a.gainDB) / (b.volume - a.volume)
            return a.gainDB + slope * (v - a.volume)
        }
        for i in 0..<(knots.count - 1) {
            let a = knots[i], b = knots[i + 1]
            if v <= b.volume {
                let t = (v - a.volume) / (b.volume - a.volume)
                return a.gainDB + t * (b.gainDB - a.gainDB)
            }
        }
        let a = knots[knots.count - 2], b = knots[knots.count - 1]
        let slope = (b.gainDB - a.gainDB) / (b.volume - a.volume)
        return b.gainDB + slope * (v - b.volume)
    }

    /// Inverse of `gainDB(atVolume:)`, clamped into `[minVolume, 1]`.
    func volume(forGainDB gain: Float) -> Float {
        if gain <= knots[0].gainDB {
            let a = knots[0], b = knots[1]
            let slope = (b.volume - a.volume) / (b.gainDB - a.gainDB)
            return AcousticMath.clamp(a.volume + slope * (gain - a.gainDB),
                                      VolumeTaper.minVolume, 1.0)
        }
        for i in 0..<(knots.count - 1) {
            let a = knots[i], b = knots[i + 1]
            if gain <= b.gainDB {
                let t = (gain - a.gainDB) / (b.gainDB - a.gainDB)
                return AcousticMath.clamp(a.volume + t * (b.volume - a.volume),
                                          VolumeTaper.minVolume, 1.0)
            }
        }
        let a = knots[knots.count - 2], b = knots[knots.count - 1]
        let slope = (b.volume - a.volume) / (b.gainDB - a.gainDB)
        return AcousticMath.clamp(b.volume + slope * (gain - b.gainDB),
                                  VolumeTaper.minVolume, 1.0)
    }

    /// Average slope in dB per full slider, for diagnostics and logging.
    var spanDB: Float {
        let first = knots[0], last = knots[knots.count - 1]
        return (last.gainDB - first.gainDB) / (last.volume - first.volume)
    }

    // MARK: - Engine-facing API

    /// The largest slider movement this taper ever assigns to `rangeDB`,
    /// sampled across the whole curve and capped at `absoluteMaxDelta`.
    ///
    /// A real curve is shallower at the top of the slider than at the bottom,
    /// so the travel needed for a given dB varies with position. Taking the
    /// worst case means this never clips a legitimate move while still
    /// bounding every move.
    func maxSliderDelta(forRangeDB rangeDB: Float) -> Float {
        let range = abs(rangeDB)
        guard range > 0 else { return 0 }

        var worst: Float = 0
        var v: Float = VolumeTaper.minVolume
        while v <= 1.0 {
            let here = gainDB(atVolume: v)
            let up = volume(forGainDB: here + range) - v
            let down = v - volume(forGainDB: here - range)
            worst = max(worst, max(up, down))
            v += 0.05
        }
        return min(worst, VolumeTaper.absoluteMaxDelta)
    }

    /// The slider delta that, added to `base`, delivers `dB` of change.
    ///
    /// Bounded four ways, all of which hold simultaneously:
    ///   1. the request itself is clamped to ±`rangeDB`;
    ///   2. the resulting slider position never exceeds `ceiling`;
    ///   3. the resulting slider position stays within `[0, 1]`;
    ///   4. the movement never exceeds `maxSliderDelta(forRangeDB:)`, which
    ///      is itself capped at `absoluteMaxDelta`.
    ///
    /// `rangeDB` is the user's selected range, not the requested dB — the cap
    /// is a property of the setting, so a series of small requests can never
    /// walk past it either.
    func volumeDelta(forDB dB: Float,
                     atBase base: Float,
                     rangeDB: Float,
                     ceiling: Float = 1.0) -> Float {
        guard dB.isFinite, base.isFinite else { return 0 }

        let safeBase = AcousticMath.clamp(base, 0.0, 1.0)
        let requested = AcousticMath.clamp(dB, -abs(rangeDB), abs(rangeDB))

        let baseGain = gainDB(atVolume: safeBase)
        var target = volume(forGainDB: baseGain + requested)

        // The ceiling limits ENVO's own upward contribution; it must never
        // drag the volume BELOW where the user put it. A user who chooses 95%
        // has chosen 95%, and pulling them down to 92% for their own good is
        // the same class of behaviour as re-applying an offset over a manual
        // adjustment.
        let effectiveCeiling = max(AcousticMath.clamp(ceiling, 0.0, 1.0), safeBase)
        target = min(target, effectiveCeiling)
        target = AcousticMath.clamp(target, 0.0, 1.0)

        let cap = maxSliderDelta(forRangeDB: rangeDB)
        return AcousticMath.clamp(target - safeBase, -cap, cap)
    }

    /// The dB change a slider delta actually delivers. This is what the UI
    /// shows the user — the honest number, not the slider percentage.
    func deliveredDB(forDelta delta: Float, atBase base: Float) -> Float {
        let safeBase = AcousticMath.clamp(base, 0.0, 1.0)
        let target = AcousticMath.clamp(safeBase + delta, 0.0, 1.0)
        return gainDB(atVolume: target) - gainDB(atVolume: safeBase)
    }
}
