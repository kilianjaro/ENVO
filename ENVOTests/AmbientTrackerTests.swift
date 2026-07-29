import XCTest
@testable import ENVO

/// Exercises the tracker in the configuration the engine actually ships:
/// L90 over up to sixty seconds, fed at 10 Hz.
///
/// The rate matters as much as the percentile. Sampled once per second, the L90
/// of a ten-second window is the single lowest of ten readings — an estimator
/// with several decibels of scatter produced by nothing but which millisecond
/// each reading happened to land on. At 10 Hz the same window carries a hundred.
final class AmbientTrackerTests: XCTestCase {

    private let rate = EnvoEngine.micSamplesPerSecond

    private func tracker() -> AmbientTracker {
        AmbientTracker(percentile: 0.1, minimumSamples: 20, capacity: 600)
    }

    private func window(_ seconds: Int) -> Int { seconds * EnvoEngine.micSamplesPerSecond }

    private func ingest(_ t: inout AmbientTracker, _ level: Float, seconds: Int) {
        for _ in 0..<(seconds * rate) { t.ingest(level) }
    }

    func testNoEstimateBeforeEnoughHistory() {
        var t = tracker()
        for _ in 0..<19 { t.ingest(-60) }
        XCTAssertNil(t.floorDB(overLast: window(30)))
        t.ingest(-60)
        XCTAssertNotNil(t.floorDB(overLast: window(30)))
    }

    func testSteadyLevelReadsAsThatLevel() {
        var t = tracker()
        ingest(&t, -62, seconds: 30)
        XCTAssertEqual(t.floorDB(overLast: window(30))!, -62, accuracy: 0.001)
    }

    /// The property the whole design rests on: with dynamic programme material,
    /// the floor tracks the quiet moments, not the peaks.
    func testFloorTracksTheQuietMomentsOfDynamicMaterial() {
        var t = tracker()
        // A podcast: speech at -30, dropping to the -65 room in the gaps for
        // about a fifth of the time.
        for i in 0..<(30 * rate) {
            t.ingest(i % 5 == 0 ? -65 : -30)
        }
        XCTAssertEqual(t.floorDB(overLast: window(30))!, -65, accuracy: 1.0,
                       "the floor should sit in the gaps, not with the speech")
    }

    /// The honest limit of percentile tracking, stated as a test so nobody has
    /// to rediscover it.
    ///
    /// Heavily limited music has a loudness range of a few decibels — there are
    /// no gaps for the floor to sit in. On a speaker the floor therefore lands
    /// on the *music*, tens of decibels above the room, and rises whenever ENVO
    /// raises the volume. No choice of percentile fixes this; it is why
    /// `SelfCouplingEstimator` exists.
    func testDenseMusicOnASpeakerHidesTheRoomFromTheTrackerAlone() {
        var t = tracker()
        let room: Float = -68
        for i in 0..<(30 * rate) {
            // Mastered pop: ±3 dB around -35, no real gaps.
            let music = -35 + 3 * sinf(Float(i) * 0.7)
            t.ingest(max(music, room))
        }
        let floor = t.floorDB(overLast: window(30))!
        XCTAssertGreaterThan(floor, room + 20,
                             "the floor lands on the music, not the room — by design of the material, not of the tracker")
    }

    func testFloorRisesWhenTheRoomGetsLouder() {
        var t = tracker()
        ingest(&t, -70, seconds: 30)
        let quiet = t.floorDB(overLast: window(30))!
        ingest(&t, -55, seconds: 30)
        let loud = t.floorDB(overLast: window(30))!
        XCTAssertEqual(loud - quiet, 15, accuracy: 1.0)
    }

    func testWindowLimitsHowFarBackItLooks() {
        var t = tracker()
        ingest(&t, -80, seconds: 30)
        ingest(&t, -50, seconds: 10)
        // A short window sees only the recent, louder stretch.
        XCTAssertEqual(t.floorDB(overLast: window(10))!, -50, accuracy: 0.001)
        // A long window still remembers the quiet one.
        XCTAssertEqual(t.floorDB(overLast: window(40))!, -80, accuracy: 0.001)
    }

    /// L90 shrugs off a handful of dead buffers. Anything longer is
    /// `SpikeFilter`'s and `ObstructionDetector`'s problem.
    func testIsolatedDropoutDoesNotDragTheFloorDown() {
        var t = tracker()
        ingest(&t, -55, seconds: 30)
        t.ingest(-120)
        XCTAssertEqual(t.floorDB(overLast: window(30))!, -55, accuracy: 0.001)
    }

    func testNonFiniteSamplesAreIgnored() {
        var t = tracker()
        ingest(&t, -60, seconds: 3)
        t.ingest(.nan)
        t.ingest(.infinity)
        XCTAssertEqual(t.count, 3 * rate)
        XCTAssertEqual(t.floorDB(overLast: window(30))!, -60, accuracy: 0.001)
    }

    func testResetClearsHistory() {
        var t = tracker()
        ingest(&t, -60, seconds: 30)
        t.reset()
        XCTAssertEqual(t.count, 0)
        XCTAssertNil(t.floorDB(overLast: window(30)))
    }

    /// Sixty seconds at 10 Hz is exactly the capacity — the SLOW setting must
    /// not silently see a shorter window than it asks for.
    func testCapacityCoversTheSlowestSetting() {
        var t = tracker()
        ingest(&t, -70, seconds: 60)
        XCTAssertEqual(t.count, 600)
        XCTAssertEqual(t.floorDB(overLast: window(60))!, -70, accuracy: 0.001)
    }

    // MARK: - Speech likeness at the floor

    /// The reason the share is stored per-sample rather than read live: the
    /// damper must judge the readings the floor actually came from, where our
    /// own playback is quiet, not whatever is arriving during a loud passage.
    func testSpeechLikenessIsTakenFromTheReadingsAtTheFloor() {
        var t = tracker()
        for i in 0..<(30 * rate) {
            let atFloor = i % 5 == 0
            t.ingest(atFloor ? -65 : -30, voiceShare: atFloor ? 0.9 : 0.1)
        }
        XCTAssertEqual(t.voiceShareAtFloor(overLast: window(30))!, 0.9, accuracy: 0.05)
    }
}

// MARK: - End-to-end regression

/// Runs the shipping tracker, spike filter and control law together over a
/// changing room, at the rates the engine uses: measurements at 10 Hz, one
/// control decision per second.
final class AmbientToOffsetIntegrationTests: XCTestCase {

    private let law = ControlLaw(gain: 0.40,
                                 smoothing: 0.85,
                                 zeroHysteresisDB: 0.5,
                                 maxRateDBPerSecond: 0.75)

    private let rate = EnvoEngine.micSamplesPerSecond

    private func seconds(_ level: Float, _ count: Int) -> [Float] {
        [Float](repeating: level, count: count * EnvoEngine.micSamplesPerSecond)
    }

    /// Mirrors `EnvoEngine.tick`: ingest ten readings, take the floor, anchor a
    /// baseline after warmup, then run the control law once.
    private func simulate(levels: [Float],
                          rangeDB: Float = 6,
                          windowSeconds: Int = 30,
                          warmup: Int = 8) -> [Float] {
        var tracker = AmbientTracker(percentile: 0.1, minimumSamples: 20, capacity: 600)
        var spike = SpikeFilter(windowSize: 31, spikeRatio: 2.5, minimumMargin: 1.0)
        var baseline: Float?
        var warmupTicks = 0
        var offset: Float = 0
        var offsets: [Float] = []

        for (index, level) in levels.enumerated() {
            tracker.ingest(spike.ingest(level))
            guard (index + 1) % rate == 0 else { continue }

            guard let floor = tracker.floorDB(overLast: windowSeconds * rate) else {
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

    /// The original regression: a quiet room, then a substantially louder one.
    func testLouderRoomProducesAPositiveAdjustment() {
        let offsets = simulate(levels: seconds(-70, 20) + seconds(-52, 120))
        XCTAssertGreaterThan(offsets.last!, 3.0,
                             "an 18 dB louder room must move the adjustment off zero")
        XCTAssertLessThanOrEqual(offsets.last!, 6.0001)
    }

    func testQuieterRoomProducesANegativeAdjustment() {
        let offsets = simulate(levels: seconds(-52, 20) + seconds(-70, 120))
        XCTAssertLessThan(offsets.last!, -3.0)
        XCTAssertGreaterThanOrEqual(offsets.last!, -6.0001)
    }

    /// A modest but real change must also register — not just extreme ones.
    func testModestRoomChangeStillRegisters() {
        let offsets = simulate(levels: seconds(-65, 20) + seconds(-59, 120))
        XCTAssertEqual(offsets.last!, 2.4, accuracy: 0.3)
    }

    /// With speech playing over a changing room, the floor still follows the
    /// room. This is the case the old subtraction model could not handle at all.
    func testWorksWithSpeechPlayingOverTheRoom() {
        var levels: [Float] = []
        for i in 0..<(20 * rate) { levels.append(i % 5 == 0 ? -68 : -35) }   // quiet room
        for i in 0..<(140 * rate) { levels.append(i % 5 == 0 ? -50 : -33) }  // louder room
        let offsets = simulate(levels: levels)
        XCTAssertGreaterThan(offsets.last!, 3.0,
                             "the room change must register through the programme material")
    }

    func testUnchangingRoomLeavesTheAdjustmentAtZero() {
        let offsets = simulate(levels: seconds(-60, 150))
        XCTAssertEqual(offsets.last!, 0, accuracy: 0.0001)
    }

    /// Nothing in the loop may breach the range, whatever the room does.
    func testRangeHoldsAcrossAViolentRoom() {
        var levels: [Float] = []
        for i in 0..<(600 * rate) {
            levels.append((i / rate) % 40 < 20 ? -80 : -30)
        }
        for range in [Float(3), 6, 9] {
            for offset in simulate(levels: levels, rangeDB: range) {
                XCTAssertLessThanOrEqual(abs(offset), range + 0.0001)
            }
        }
    }

    /// A one-second dropout — a hand across the microphone, a dead buffer run —
    /// must not push the volume down. Before the spike filter became two-sided
    /// this went straight into the floor.
    func testABriefDropoutDoesNotPushTheVolumeDown() {
        var levels = seconds(-55, 60)
        // One second of the microphone reading 20 dB low, well into the session.
        for i in 0..<rate { levels[40 * rate + i] = -75 }
        let offsets = simulate(levels: levels)
        XCTAssertEqual(offsets.last!, 0, accuracy: 0.5,
                       "a transient dropout is not the room going quiet")
    }
}
