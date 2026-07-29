import XCTest
@testable import ENVO

final class LombardDamperTests: XCTestCase {

    private let damper = LombardDamper(engageShare: 0.45,
                                       fullEffectShare: 0.85,
                                       maxDampingDB: 3.0)

    // MARK: - Engagement

    func testNonSpeechNoiseIsNotDamped() {
        // Engine drone, HVAC, traffic — the noise ENVO exists to answer.
        let result = damper.damp(ambientDB: -50, voiceShare: 0.2, baselineDB: -60)
        XCTAssertEqual(result, -50, accuracy: 0.0001)
    }

    func testDampingRampsInWithVoiceShare() {
        let quarter = damper.damp(ambientDB: -50, voiceShare: 0.55, baselineDB: -60)
        let half = damper.damp(ambientDB: -50, voiceShare: 0.65, baselineDB: -60)
        let full = damper.damp(ambientDB: -50, voiceShare: 0.85, baselineDB: -60)

        XCTAssertEqual(quarter, -50.75, accuracy: 0.05)
        XCTAssertEqual(half, -51.5, accuracy: 0.05)
        XCTAssertEqual(full, -53.0, accuracy: 0.05)
    }

    func testDampingSaturatesAtItsMaximum() {
        let full = damper.damp(ambientDB: -50, voiceShare: 1.0, baselineDB: -60)
        XCTAssertEqual(full, -53.0, accuracy: 0.05,
                       "a fully speech-dominated room must not exceed the cap")
    }

    // MARK: - Safety properties

    /// The damper may only ever make ENVO do less. It must never push the
    /// estimate below the baseline, or a room full of chatter could drive the
    /// volume *down*.
    func testNeverReadsQuieterThanTheBaseline() {
        for ambient in stride(from: Float(-80), through: -20, by: 2) {
            for share in stride(from: Float(0), through: 1.0, by: 0.05) {
                let baseline: Float = -55
                let result = damper.damp(ambientDB: ambient,
                                         voiceShare: share,
                                         baselineDB: baseline)
                XCTAssertGreaterThanOrEqual(
                    result, min(ambient, baseline) - 0.0001,
                    "damped below the baseline at ambient \(ambient) share \(share)"
                )
            }
        }
    }

    func testNeverIncreasesTheEstimate() {
        for ambient in stride(from: Float(-80), through: -20, by: 2) {
            for share in stride(from: Float(0), through: 1.0, by: 0.05) {
                let result = damper.damp(ambientDB: ambient,
                                         voiceShare: share,
                                         baselineDB: -55)
                XCTAssertLessThanOrEqual(result, ambient + 0.0001,
                                         "damper added upward pressure")
            }
        }
    }

    /// A room already at or below the baseline is not damped at all — there is
    /// no upward pressure to remove.
    func testQuietRoomIsUntouched() {
        let result = damper.damp(ambientDB: -70, voiceShare: 1.0, baselineDB: -55)
        XCTAssertEqual(result, -70, accuracy: 0.0001)
    }

    func testHostileInputsAreReturnedUnchanged() {
        XCTAssertEqual(damper.damp(ambientDB: -50, voiceShare: .nan, baselineDB: -60), -50)
        XCTAssertEqual(damper.damp(ambientDB: -50, voiceShare: 0.9, baselineDB: .nan), -50)
        XCTAssertTrue(damper.damp(ambientDB: .nan, voiceShare: 0.9, baselineDB: -60).isNaN)
    }
}

// MARK: - Floor-aligned voice share

/// Regression cover for the mismatch this rework fixed: the damper used to
/// read `AudioManager.voiceBandShare` directly — a ~140 ms snapshot of the
/// live signal — and apply it to a floor derived from a 10–60 s percentile.
/// Because music is voice-band heavy, a loud passage engaged the damper
/// against a floor that had been measured in the quiet gaps.
final class FloorAlignedVoiceShareTests: XCTestCase {

    private func tracker() -> AmbientTracker {
        AmbientTracker(percentile: 0.2, minimumSamples: 5,
                       capacity: 60, floorToleranceDB: 6.0)
    }

    func testNoShareBeforeEnoughHistory() {
        var t = tracker()
        for _ in 0..<4 { t.ingest(-60, voiceShare: 0.9) }
        XCTAssertNil(t.voiceShareAtFloor(overLast: 30))
    }

    func testSteadySignalReportsItsOwnShare() {
        var t = tracker()
        for _ in 0..<30 { t.ingest(-60, voiceShare: 0.7) }
        XCTAssertEqual(t.voiceShareAtFloor(overLast: 30)!, 0.7, accuracy: 0.01)
    }

    /// The case that motivated the change. Voice-band-heavy music at the peaks,
    /// a genuinely non-speech room in the dips. The share that matters is the
    /// one in the dips.
    func testMusicAtThePeaksDoesNotContributeToTheFloorShare() {
        var t = tracker()
        for i in 0..<40 {
            if i % 4 == 0 {
                t.ingest(-68, voiceShare: 0.15)   // quiet room: machinery, traffic
            } else {
                t.ingest(-35, voiceShare: 0.88)   // music: voice-band heavy
            }
        }

        let share = t.voiceShareAtFloor(overLast: 40)!
        XCTAssertEqual(share, 0.15, accuracy: 0.02,
                       "the music's spectral character leaked into the floor share")

        // And therefore the damper leaves the reading alone.
        let damper = LombardDamper()
        let floor = t.floorDB(overLast: 40)!
        XCTAssertEqual(damper.damp(ambientDB: floor, voiceShare: share, baselineDB: -75),
                       floor, accuracy: 0.0001)
    }

    /// The genuine Lombard case must still be caught: when the *quiet moments*
    /// are themselves speech, the damper should engage.
    func testSpeechInTheQuietMomentsStillEngagesTheDamper() {
        var t = tracker()
        for i in 0..<40 {
            if i % 4 == 0 {
                t.ingest(-55, voiceShare: 0.9)    // a room of talkers
            } else {
                t.ingest(-35, voiceShare: 0.9)
            }
        }

        let share = t.voiceShareAtFloor(overLast: 40)!
        XCTAssertEqual(share, 0.9, accuracy: 0.02)

        let damper = LombardDamper()
        let floor = t.floorDB(overLast: 40)!
        XCTAssertLessThan(damper.damp(ambientDB: floor, voiceShare: share, baselineDB: -70),
                          floor, "a speech-dominated floor must still be damped")
    }

    func testToleranceBoundsWhichSamplesCount() {
        var t = tracker()
        // Floor at -70; -66 is inside the 6 dB tolerance, -50 is well outside.
        for _ in 0..<10 { t.ingest(-70, voiceShare: 0.1) }
        for _ in 0..<10 { t.ingest(-66, voiceShare: 0.3) }
        for _ in 0..<10 { t.ingest(-50, voiceShare: 0.9) }

        let share = t.voiceShareAtFloor(overLast: 30)!
        XCTAssertEqual(share, 0.2, accuracy: 0.02,
                       "only readings within the tolerance of the floor should count")
    }

    func testResetClearsSharesAlongsideLevels() {
        var t = tracker()
        for _ in 0..<30 { t.ingest(-60, voiceShare: 0.8) }
        t.reset()
        XCTAssertNil(t.voiceShareAtFloor(overLast: 30))
    }

    /// Levels and shares must stay index-aligned as the buffer rolls over.
    func testSeriesStayAlignedPastCapacity() {
        var t = tracker()
        for _ in 0..<80 { t.ingest(-30, voiceShare: 0.9) }   // evicted
        for _ in 0..<60 { t.ingest(-70, voiceShare: 0.1) }   // fills capacity
        XCTAssertEqual(t.count, 60)
        XCTAssertEqual(t.voiceShareAtFloor(overLast: 60)!, 0.1, accuracy: 0.01)
    }

    func testNonFiniteShareIsStoredAsZeroNotPropagated() {
        var t = tracker()
        for _ in 0..<10 { t.ingest(-60, voiceShare: .nan) }
        XCTAssertEqual(t.voiceShareAtFloor(overLast: 30)!, 0, accuracy: 0.0001)
    }
}
