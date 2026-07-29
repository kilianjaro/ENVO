import Foundation

/// Power-domain arithmetic for acoustic levels.
///
/// WHY THIS EXISTS
/// ---------------
/// Every level ENVO measures is a decibel value. Decibels are logarithmic,
/// which means the intuitive operations are wrong:
///
///   * Two sounds of 60 dB together are 63 dB, not 120 dB.
///   * Removing a 60 dB source from a 63 dB mix leaves 60 dB, not 3 dB.
///   * "40% louder" is not `level * 1.4` — it is `level + 1.5 dB`.
///
/// The pre-existing code did all three of those wrong: it treated the
/// normalized 0…1 mic level (which is linear in dB) as if it were linear in
/// amplitude, then multiplied, divided and subtracted it directly. That is
/// the root of the calibration and gap-detection misbehaviour.
///
/// The rule enforced from here on: **convert to power, combine, convert
/// back.** All functions are pure and total — no NaN, no Inf, no traps.
enum AcousticMath {

    /// Levels at or below this are treated as digital silence. Chosen well
    /// below the noise floor of any iOS microphone so it never clips a real
    /// measurement, while still keeping `power(fromDB:)` in a sane range.
    static let silenceDB: Float = -120.0

    // MARK: - Conversions

    /// Relative power for a level in dB. `dB` here is a *power* decibel
    /// (10·log10), matching how RMS levels are compared.
    static func power(fromDB dB: Float) -> Float {
        guard dB.isFinite else { return 0 }
        return powf(10.0, min(dB, 40.0) / 10.0)
    }

    /// Inverse of `power(fromDB:)`, floored at `silenceDB` so a zero or
    /// negative power can never produce -Inf.
    static func dB(fromPower power: Float) -> Float {
        guard power.isFinite, power > 0 else { return silenceDB }
        return max(10.0 * log10f(power), silenceDB)
    }

    // MARK: - Combination

    /// Energetic sum: the level of two incoherent sources heard together.
    static func addDB(_ a: Float, _ b: Float) -> Float {
        dB(fromPower: power(fromDB: a) + power(fromDB: b))
    }

    /// Energetic difference: the level that remains after removing
    /// `component` from `total`.
    ///
    /// This is the operation calibration needs — "the mic hears 58 dB and
    /// we know 56 dB of that is our own speaker, so the room is 53.7 dB."
    ///
    /// When `component` is at or above `total` the remainder is unmeasurable
    /// (the device output is masking the room entirely), and the result is
    /// `silenceDB`. Callers decide what to do with that; they must not
    /// treat it as a real reading.
    static func subtractDB(_ total: Float, _ component: Float) -> Float {
        let remaining = power(fromDB: total) - power(fromDB: component)
        guard remaining > 0 else { return silenceDB }
        return dB(fromPower: remaining)
    }

    // MARK: - Averaging

    /// Energy-weighted mean of a set of dB levels. Averaging decibels
    /// arithmetically under-weights the loud samples; this does not.
    static func meanDB(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return silenceDB }
        var sum: Float = 0
        for level in levels { sum += power(fromDB: level) }
        return dB(fromPower: sum / Float(levels.count))
    }

    /// One step of an exponential moving average in the power domain.
    /// `retention` is the weight kept from `current` (0…1).
    static func emaDB(current: Float, sample: Float, retention: Float) -> Float {
        let r = min(max(retention, 0.0), 1.0)
        let blended = r * power(fromDB: current) + (1.0 - r) * power(fromDB: sample)
        return dB(fromPower: blended)
    }

    // MARK: - Helpers

    static func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(value, lo), hi)
    }
}
