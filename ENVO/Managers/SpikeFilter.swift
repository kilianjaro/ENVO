import Foundation

/// Rejects brief amplitude spikes (door slams, claps, etc.) that would
/// otherwise yank the volume hard.
///
/// Strategy: maintain a rolling window of recent samples. If the current
/// sample exceeds the window's median by more than `spikeRatio`× AND the
/// window's IQR is small (i.e. baseline was steady), winsorize the sample
/// to a clamped value rather than passing it through unchanged.
///
/// This is non-destructive: persistent loud noise still drives the offset
/// up because the median catches up after a few seconds. Only short bursts
/// are blunted.
struct SpikeFilter {

    private var window: [Float] = []
    private let windowSize: Int
    private let spikeRatio: Float
    private let minimumMargin: Float

    /// - Parameters:
    ///   - minimumMargin: floor on the spread term, in the same unit as the
    ///     samples. The engine now feeds this filter **decibels**, where the
    ///     old hard-coded 0.02 (tuned for a normalized 0…1 level) was three
    ///     orders of magnitude too small to have any effect — every spike
    ///     passed straight through.
    init(windowSize: Int = 12, spikeRatio: Float = 2.5, minimumMargin: Float = 1.0) {
        self.windowSize = max(3, windowSize)
        self.spikeRatio = max(1.1, spikeRatio)
        self.minimumMargin = max(0.0001, minimumMargin)
    }

    /// Push a sample, return the spike-filtered value.
    mutating func ingest(_ sample: Float) -> Float {
        window.append(sample)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }
        guard window.count >= 5 else { return sample }

        let sorted = window.sorted()
        let median = sorted[sorted.count / 2]
        let q3 = sorted[Int(Float(sorted.count) * 0.75)]
        let q1 = sorted[Int(Float(sorted.count) * 0.25)]
        let iqr = q3 - q1

        let threshold = median + max(minimumMargin, iqr * 1.5) * spikeRatio
        if sample > threshold {
            // Winsorize back to the threshold to absorb the spike but keep
            // signal direction. Also replace the just-pushed sample so the
            // median doesn't get poisoned next tick.
            window[window.count - 1] = threshold
            return threshold
        }
        return sample
    }

    mutating func reset() {
        window.removeAll()
    }
}
