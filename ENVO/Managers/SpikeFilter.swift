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

    init(windowSize: Int = 12, spikeRatio: Float = 2.5) {
        self.windowSize = max(3, windowSize)
        self.spikeRatio = max(1.1, spikeRatio)
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

        let threshold = median + max(0.02, iqr * 1.5) * spikeRatio
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
