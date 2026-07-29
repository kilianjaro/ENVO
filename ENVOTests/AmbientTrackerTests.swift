import XCTest
@testable import ENVO

final class AmbientTrackerTests: XCTestCase {

    private func tracker() -> AmbientTracker {
        AmbientTracker(percentile: 0.2, minimumSamples: 5, capacity: 60)
    }

    func testNoEstimateBeforeEnoughHistory() {
        var t = tracker()
        for _ in 0..<4 { t.ingest(-60) }
        XCTAssertNil(t.floorDB(overLast: 30))
        t.ingest(-60)
        XCTAssertNotNil(t.floorDB(overLast: 30))
    }

    func testSteadyLevelReadsAsThatLevel() {
        var t = tracker()
        for _ in 0..<30 { t.ingest(-62) }
        XCTAssertEqual(t.floorDB(overLast: 30)!, -62, accuracy: 0.001)
    }

    /// The property the whole design rests on: with dynamic program material,
    /// the floor tracks the quiet moments, not the peaks.
    func testFloorTracksTheQuietMomentsOfDynamicMaterial() {
        var t = tracker()
        // Music peaking at -30, dipping to the -65 room between beats.
        for i in 0..<40 {
            t.ingest(i % 4 == 0 ? -65 : -30)
        }
        let floor = t.floorDB(overLast: 40)!
        XCTAssertEqual(floor, -65, accuracy: 1.0,
                       "the floor should sit in the dips, not with the music")
    }

    func testFloorRisesWhenTheRoomGetsLouder() {
        var t = tracker()
        for _ in 0..<30 { t.ingest(-70) }
        let quiet = t.floorDB(overLast: 30)!
        for _ in 0..<30 { t.ingest(-55) }
        let loud = t.floorDB(overLast: 30)!
        XCTAssertEqual(loud - quiet, 15, accuracy: 1.0)
    }

    func testWindowLimitsHowFarBackItLooks() {
        var t = tracker()
        for _ in 0..<30 { t.ingest(-80) }
        for _ in 0..<10 { t.ingest(-50) }
        // A short window sees only the recent, louder stretch.
        XCTAssertEqual(t.floorDB(overLast: 10)!, -50, accuracy: 0.001)
        // A long window still remembers the quiet one.
        XCTAssertEqual(t.floorDB(overLast: 40)!, -80, accuracy: 0.001)
    }

    func testIsolatedDropoutDoesNotDragTheFloorDown() {
        var t = tracker()
        for _ in 0..<29 { t.ingest(-55) }
        t.ingest(-120)   // one dead buffer
        XCTAssertEqual(t.floorDB(overLast: 30)!, -55, accuracy: 0.001)
    }

    func testNonFiniteSamplesAreIgnored() {
        var t = tracker()
        for _ in 0..<10 { t.ingest(-60) }
        t.ingest(.nan)
        t.ingest(.infinity)
        XCTAssertEqual(t.count, 10)
        XCTAssertEqual(t.floorDB(overLast: 30)!, -60, accuracy: 0.001)
    }

    func testResetClearsHistory() {
        var t = tracker()
        for _ in 0..<30 { t.ingest(-60) }
        t.reset()
        XCTAssertEqual(t.count, 0)
        XCTAssertNil(t.floorDB(overLast: 30))
    }
}

// MARK: - End-to-end regression

/// Reproduces the reported device failure: the room changed substantially and
/// the adjustment stayed at 0.0 dB for the entire session.
///
/// The cause was `CalibrationProfile.estimateAmbientDB`, which subtracted the
/// speaker level recorded during the calibration sweep. That figure describes
/// the speaker playing the test noise, so at runtime the live reading sat far
/// below it, every tick reported the room as masked, and the ambient estimate
/// never updated. These tests run the tracker and the control law together —
/// the same two types the engine tick uses — over a changing room.
final class AmbientToOffsetIntegrationTests: XCTestCase {

    private let law = ControlLaw(gain: 0.40,
                                 smoothing: 0.85,
                                 zeroHysteresisDB: 0.5,
                                 maxRateDBPerSecond: 0.75)

    /// Mirrors `EnvoEngine.tick`: ingest a reading, take the floor, anchor a
    /// baseline after warmup, then run the control law on the difference.
    private func simulate(levels: [Float],
                          rangeDB: Float = 6,
                          windowSamples: Int = 30,
                          warmup: Int = 8) -> [Float] {
        var tracker = AmbientTracker(percentile: 0.2, minimumSamples: 5, capacity: 60)
        var spike = SpikeFilter(windowSize: 12, spikeRatio: 2.5, minimumMargin: 1.0)
        var baseline: Float?
        var warmupTicks = 0
        var offset: Float = 0
        var offsets: [Float] = []

        for level in levels {
            tracker.ingest(spike.ingest(level))
            guard let floor = tracker.floorDB(overLast: windowSamples) else {
                offsets.append(offset)
                continue
            }
            guard let anchored = baseline else {
                warmupTicks += 1
                if warmupTicks >= warmup { baseline = floor }
                offsets.append(offset)
                continue
            }
            offset = law.nextOffsetDB(currentOffsetDB: offset,
                                      noiseDeltaDB: floor - anchored,
                                      rangeDB: rangeDB,
                                      allowIncrease: true,
                                      allowDecrease: true)
            offsets.append(offset)
        }
        return offsets
    }

    /// The regression itself. A quiet room, then a substantially louder one.
    func testLouderRoomProducesAPositiveAdjustment() {
        let levels = [Float](repeating: -70, count: 20)
                   + [Float](repeating: -52, count: 120)
        let offsets = simulate(levels: levels)

        XCTAssertGreaterThan(offsets.last!, 3.0,
                             "an 18 dB louder room must move the adjustment off zero")
        XCTAssertLessThanOrEqual(offsets.last!, 6.0001)
    }

    func testQuieterRoomProducesANegativeAdjustment() {
        let levels = [Float](repeating: -52, count: 20)
                   + [Float](repeating: -70, count: 120)
        let offsets = simulate(levels: levels)
        XCTAssertLessThan(offsets.last!, -3.0)
        XCTAssertGreaterThanOrEqual(offsets.last!, -6.0001)
    }

    /// A modest but real change must also register — not just extreme ones.
    func testModestRoomChangeStillRegisters() {
        let levels = [Float](repeating: -65, count: 20)
                   + [Float](repeating: -59, count: 120)
        let offsets = simulate(levels: levels)
        XCTAssertEqual(offsets.last!, 2.4, accuracy: 0.3)
    }

    /// With music playing over a changing room, the floor still follows the
    /// room. This is the case the subtraction model could not handle at all.
    func testWorksWithMusicPlayingOverTheRoom() {
        var levels: [Float] = []
        for i in 0..<20 { levels.append(i % 4 == 0 ? -68 : -35) }   // quiet room
        for i in 0..<140 { levels.append(i % 4 == 0 ? -50 : -33) }  // louder room
        let offsets = simulate(levels: levels)

        XCTAssertGreaterThan(offsets.last!, 3.0,
                             "the room change must register through the music")
    }

    func testUnchangingRoomLeavesTheAdjustmentAtZero() {
        let offsets = simulate(levels: [Float](repeating: -60, count: 150))
        XCTAssertEqual(offsets.last!, 0, accuracy: 0.0001)
    }

    /// Nothing in the loop may breach the range, whatever the room does.
    func testRangeHoldsAcrossAViolentRoom() {
        var levels: [Float] = []
        for i in 0..<600 {
            levels.append(i % 40 < 20 ? -80 : -30)
        }
        for range in [Float(3), 6, 9] {
            for offset in simulate(levels: levels, rangeDB: range) {
                XCTAssertLessThanOrEqual(abs(offset), range + 0.0001)
            }
        }
    }
}
