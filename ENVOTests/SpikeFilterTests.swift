import XCTest
@testable import ENVO

final class SpikeFilterTests: XCTestCase {

    func testSteadySignalPassesThroughUnchanged() {
        var filter = SpikeFilter()
        let samples: [Float] = [0.3, 0.31, 0.29, 0.30, 0.32, 0.30, 0.31, 0.30]
        for s in samples {
            let out = filter.ingest(s)
            XCTAssertEqual(out, s, accuracy: 0.0001)
        }
    }

    func testIsolatedSpikeIsBlunted() {
        var filter = SpikeFilter()
        // Establish a steady baseline first.
        for _ in 0..<10 { _ = filter.ingest(0.2) }
        // A massive spike should NOT pass through at full amplitude.
        let outSpike = filter.ingest(0.95)
        XCTAssertLessThan(outSpike, 0.95)
    }

    func testSustainedHigherSignalEventuallyPasses() {
        var filter = SpikeFilter()
        for _ in 0..<10 { _ = filter.ingest(0.2) }
        // Sustained louder reading — the rolling median catches up
        // and the filter stops clipping it.
        var lastOut: Float = 0
        for _ in 0..<30 {
            lastOut = filter.ingest(0.5)
        }
        XCTAssertEqual(lastOut, 0.5, accuracy: 0.05)
    }

    func testResetClearsWindow() {
        var filter = SpikeFilter()
        for _ in 0..<10 { _ = filter.ingest(0.2) }
        filter.reset()
        // Immediately after reset there's no history to compare against,
        // so a high sample should pass straight through.
        let out = filter.ingest(0.9)
        XCTAssertEqual(out, 0.9, accuracy: 0.0001)
    }
}
