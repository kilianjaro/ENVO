import Foundation

/// Pure conversions between dB intent and iOS volume-slider deltas.
///
/// iOS `outputVolume` is roughly proportional to amplitude; dB is
/// `20·log10(amplitude)`. To deliver a perceptually consistent "+X dB"
/// at any base volume, we scale the base rather than apply a fixed
/// linear delta:
///
///     target_amp = base_amp · 10^(dB / 20)
///     delta      = target_amp − base_amp
///
/// This makes "+3 dB" feel like +3 dB whether the user is at 20% or 80%.
enum VolumeMath {

    /// Returns the additive delta on the 0…1 slider scale that, applied to
    /// `base`, lands at the requested dB offset. Honors a hard `ceiling` so
    /// the resulting target never exceeds it.
    static func volumeDelta(forDB dB: Float,
                            atBase base: Float,
                            ceiling: Float = 1.0) -> Float {
        let safeBase = max(0.001, base)  // log10 below this gets silly
        let factor = powf(10.0, dB / 20.0)
        var target = safeBase * factor
        target = min(target, ceiling)
        target = max(target, 0.0)
        return target - base
    }

    /// Inverse: the dB offset implied by a (base, delta) pair.
    /// Used in tests and diagnostics.
    static func dB(forDelta delta: Float, atBase base: Float) -> Float {
        let safeBase = max(0.001, base)
        let target = max(0.001, base + delta)
        return 20.0 * log10f(target / safeBase)
    }
}
