import XCTest
@testable import ENVO

/// The filter now sees decibels, not a normalized 0…1 level. The old tests
/// fed it values around 0.2–0.9, where the hard-coded `max(0.02, …)` spread
/// floor was small enough to be irrelevant — so the tests passed while the
/// filter was effectively inert on the data it actually received.
final class SpikeFilterTests: XCTestCase {

    private func filter() -> SpikeFilter {
        SpikeFilter(windowSize: 12, spikeRatio: 2.5, minimumMargin: 1.0)
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

    /// Only upward spikes are blunted; a sudden drop is real information.
    func testDownwardExcursionPassesThrough() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-50) }
        XCTAssertEqual(f.ingest(-75), -75, accuracy: 0.0001)
    }

    func testResetClearsWindow() {
        var f = filter()
        for _ in 0..<10 { _ = f.ingest(-60) }
        f.reset()
        XCTAssertEqual(f.ingest(-30), -30, accuracy: 0.0001)
    }
}
