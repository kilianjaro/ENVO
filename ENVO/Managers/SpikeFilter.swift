import Foundation

/// Rejects brief *upward* excursions — door slams, claps, a dropped tray, a
/// cough — that would otherwise yank the volume.
///
/// Strategy: maintain a rolling window of recent samples. If the current sample
/// exceeds the window median by more than `spikeRatio ×` the window spread,
/// winsorize it back to that threshold rather than passing it through. This is
/// non-destructive: persistent loud noise still drives the offset up, because
/// the median catches up within a few seconds. Only short bursts are blunted.
///
/// WHY THIS IS DELIBERATELY ONE-SIDED
/// ----------------------------------
/// The obvious criticism of this filter is that it guards the wrong direction.
/// The statistic it protects is `AmbientTracker`'s L90, and a low percentile is
/// inherently robust against samples arriving *high* — a loud transient sorts to
/// the top of the window and never comes near the 10th percentile — while being
/// maximally exposed to samples arriving low, which is exactly where it reads.
/// A phone going into a pocket puts a run of samples 20 dB down and the floor
/// follows them.
///
/// That criticism is right about the exposure and wrong about the remedy.
/// Winsorizing downward here breaks the mechanism the whole design rests on:
/// the floor is found *in the gaps* of the programme material. A podcast spends
/// a fifth of its time near the room level, twenty to thirty decibels below the
/// speech. To a median-and-spread rule those gaps are indistinguishable from
/// dropouts — they are far below the median, and because the median sits with
/// the speech, a symmetric threshold clips every one of them. The floor can
/// then never fall more than a couple of decibels below the programme material,
/// and ENVO stops measuring the room at all. That is a worse failure than the
/// one being defended against, and it is silent.
///
/// The two cases genuinely cannot be separated on magnitude — a speech gap and
/// a covered microphone are both "far below the median" — so downward
/// protection is handled where the distinction actually exists:
///
///   * **Sustained** drops (a pocket, a bag, face-down) are separated
///     spectrally rather than by level: covering a microphone low-passes it,
///     and a room that merely went quiet does not change shape. See
///     `ObstructionDetector`.
///   * **Brief** drops are absorbed twice over. L90 at 10 Hz needs a tenth of
///     the window to be low before the percentile moves at all — a second of
///     dropout in a thirty-second window is 3% of it — and anything that does
///     get through meets a control law with a 0.75 dB/s rate limit and a ~7 s
///     smoothing constant, which cannot translate a two-second excursion into
///     even one 3 dB hardware step.
struct SpikeFilter {

    private var window: [Float] = []
    private let windowSize: Int
    private let spikeRatio: Float
    private let minimumMargin: Float

    /// - Parameters:
    ///   - windowSize: samples retained. The engine feeds this at 10 Hz, so the
    ///     default spans about three seconds — long enough that a half-second
    ///     transient cannot move the median, short enough that a real change is
    ///     honoured within a few seconds.
    ///   - minimumMargin: floor on the spread term, in the same unit as the
    ///     samples. The engine feeds this filter **decibels**, where the
    ///     original hard-coded 0.02 (tuned for a normalized 0…1 level) was three
    ///     orders of magnitude too small to have any effect — every spike passed
    ///     straight through.
    init(windowSize: Int = 31, spikeRatio: Float = 2.5, minimumMargin: Float = 1.0) {
        self.windowSize = max(5, windowSize)
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
