import XCTest
@testable import ENVO

/// The filter now sees decibels, not a normalized 0…1 level. The old tests
/// fed it values around 0.2–0.9, where the hard-coded `max(0.02, …)` spread
/// floor was small enough to be irrelevant — so the tests passed while the
/// filter was effectively inert on the data it actually received.
final class SpikeFilterTests: XCTestCase {

    private func filter() -> SpikeFilter {
        SpikeFilter(windowSize: 31, spikeRatio: 2.5, minimumMargin: 1.0)
    }

    func testSteadySignalPassesThroughUnchanged() {
        var f = filter()
        let samples: [Float] = [-60, -59.5, -60.5, -60, -59.8, -60.2, -60, -59.9]
        for s in samples {
            XCTAssertEqual(f.ingest(s), s, accuracy: 0.0001)
        }
    }

    /// A door slam: 25 dB above a steady room, for one sample.
    func testIsolatedSpikeIsBlunted() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-60) }
        let out = f.ingest(-35)
        XCTAssertLessThan(out, -35, "the spike passed through unblunted")
        XCTAssertLessThan(out, -50, "the spike was barely attenuated")
    }

    /// A spike must not poison the window and depress later readings.
    func testWindowRecoversAfterASpike() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-60) }
        _ = f.ingest(-35)
        for _ in 0..<5 { _ = f.ingest(-60) }
        XCTAssertEqual(f.ingest(-60), -60, accuracy: 0.0001)
    }

    /// A room that genuinely got louder must not be suppressed forever —
    /// that would defeat the whole app.
    func testSustainedIncreaseEventuallyPasses() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-60) }
        var last: Float = 0
        for _ in 0..<30 { last = f.ingest(-48) }
        XCTAssertEqual(last, -48, accuracy: 0.5)
    }

    /// Downward excursions pass through untouched, and must.
    ///
    /// This looks like the wrong asymmetry — `AmbientTracker` reads a low
    /// percentile, so it is samples arriving *low* that move the floor. But the
    /// floor is found in the gaps of the programme material, and to a
    /// median-and-spread rule a speech gap is indistinguishable from a dropout:
    /// both sit far below a median that is up with the speech. Clipping downward
    /// would clip the gaps, and ENVO would stop being able to hear the room at
    /// all. Downward protection lives in `ObstructionDetector` (sustained,
    /// separated spectrally) and in L90-at-10 Hz plus the control law's time
    /// constants (brief).
    func testDownwardExcursionPassesThrough() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-50) }
        XCTAssertEqual(f.ingest(-75), -75, accuracy: 0.0001)
    }

    /// The case that would break if this filter ever became symmetric: speech
    /// with the room showing through in the gaps, a fifth of the time.
    func testProgrammeMaterialGapsSurvive() {
        var f = filter()
        var lastGap: Float = 0
        for i in 0..<200 {
            let level: Float = i % 5 == 0 ? -68 : -35
            let out = f.ingest(level)
            if i % 5 == 0 { lastGap = out }
        }
        XCTAssertEqual(lastGap, -68, accuracy: 0.0001,
                       "clipping the gaps would blind the floor estimator")
    }

    func testResetClearsWindow() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-60) }
        f.reset()
        XCTAssertEqual(f.ingest(-30), -30, accuracy: 0.0001)
    }
}
