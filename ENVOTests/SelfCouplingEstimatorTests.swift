import XCTest
@testable import ENVO

/// The fix for the loop partly listening to itself.
///
/// `AmbientTracker` reads the room from the quiet moments of the programme
/// material. Speech has real gaps, so the floor lands on the room. Heavily
/// limited music does not — the distribution is only a few decibels wide — so on
/// a speaker the floor lands on the music, rises whenever ENVO raises the
/// volume, and the loop reads its own output as the room getting louder.
final class SelfCouplingEstimatorTests: XCTestCase {

    private func estimator() -> SelfCouplingEstimator {
        var e = SelfCouplingEstimator()
        e.settleTicks = 3
        e.windowTicks = 3
        return e
    }

    /// Feed `ticks` observations of a floor that sits `coupling ×` the delivered
    /// offset above the room.
    private func feed(_ e: inout SelfCouplingEstimator,
                      ticks: Int,
                      roomDB: Float,
                      deliveredDB: Float,
                      trueCoupling: Float) {
        for _ in 0..<ticks {
            e.ingest(floorDB: roomDB + trueCoupling * deliveredDB,
                     deliveredDB: deliveredDB)
        }
    }

    // MARK: - Learning

    /// Dense music on a speaker: the floor follows ENVO's own output exactly.
    func testLearnsFullCouplingWhenTheFloorFollowsTheOutput() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 1.0)
        XCTAssertEqual(e.coupling, 1.0, accuracy: 0.15)
    }

    /// Headphones: the microphone hears none of the playback, so there is
    /// nothing to remove and the estimator must stay out of the way.
    func testLearnsZeroCouplingOnAnIsolatedRoute() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 0)
        XCTAssertEqual(e.coupling, 0, accuracy: 0.05)
    }

    /// A podcast on a speaker: the floor sits in the gaps, so only a fraction of
    /// the output survives into it.
    func testLearnsPartialCoupling() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 0.5)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 0.5)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 0.5)
        XCTAssertEqual(e.coupling, 0.5, accuracy: 0.15)
    }

    // MARK: - Conservatism

    /// Before anything has been measured, the route's implication is all there
    /// is — and it is genuinely informative, so it is used.
    func testUsesTheRouteImpliedPriorUntilSomethingIsMeasured() {
        var e = estimator()
        e.prior = 0.75                                   // built-in speaker
        XCTAssertFalse(e.isMeasured)
        XCTAssertEqual(e.coupling, 0.75, accuracy: 0.0001)

        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 0)
        XCTAssertEqual(e.coupling, 0.75, accuracy: 0.0001,
                       "ticks without a step are not evidence")
    }

    /// A measurement beats a category guess outright. This matters most in the
    /// case the route cannot resolve: Bluetooth A2DP is AirPods and a room
    /// stereo alike, and only observation can tell them apart.
    func testAMeasurementOverridesThePrior() {
        var e = estimator()
        e.prior = 0.35                                   // ambiguous A2DP
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)

        XCTAssertTrue(e.isMeasured)
        XCTAssertEqual(e.coupling, 1.0, accuracy: 0.1,
                       "one clean observation should displace the guess")
    }

    /// …and in the other direction: AirPods behind the same ambiguous prior.
    func testAMeasurementCanAlsoOverrideDownward() {
        var e = estimator()
        e.prior = 0.35
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 0)
        XCTAssertEqual(e.coupling, 0, accuracy: 0.05)
    }

    /// The estimate can never exceed 1: ENVO cannot contribute more than the
    /// whole of what it delivered.
    func testCouplingIsBounded() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 4.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 4.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 4.0)
        XCTAssertLessThanOrEqual(e.coupling, 1.0)
        XCTAssertGreaterThanOrEqual(e.coupling, 0.0)
    }

    /// A room that changes on its own during the probe must not be attributed to
    /// the probe. The pre-window stability check is what rejects it.
    func testARestlessRoomDoesNotProduceAnObservation() {
        var e = estimator()
        // Floor swinging 8 dB tick to tick before the step.
        for i in 0..<8 {
            e.ingest(floorDB: i % 2 == 0 ? -44 : -36, deliveredDB: 0)
        }
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)
        XCTAssertEqual(e.observationCount, 0,
                       "an unstable pre-window is not a usable baseline")
    }

    /// A second step mid-probe makes the result unattributable.
    func testAStepDuringAProbeAbandonsIt() {
        var e = estimator()
        feed(&e, ticks: 6, roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        e.ingest(floorDB: -37, deliveredDB: 3)
        e.ingest(floorDB: -37, deliveredDB: 3)
        e.ingest(floorDB: -34, deliveredDB: 6)      // second step, mid-probe
        feed(&e, ticks: 4, roomDB: -40, deliveredDB: 6, trueCoupling: 1.0)
        XCTAssertEqual(e.observationCount, 0)
    }

    // MARK: - Application

    /// The point of the whole type: recover the room from a floor that is
    /// carrying ENVO's own output.
    func testRoomLevelRemovesTheDeviceContribution() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 1.0)

        // The floor reads -34 because ENVO is 6 dB up; the room is still -40.
        XCTAssertEqual(e.roomLevelDB(fromFloorDB: -34, deliveredDB: 6),
                       -40, accuracy: 0.6)
    }

    /// The correction must vanish at the baseline, where ENVO has delivered
    /// nothing — otherwise it would bias the anchor itself.
    func testNoCorrectionAtZeroOffset() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 1.0)
        XCTAssertEqual(e.roomLevelDB(fromFloorDB: -52, deliveredDB: 0),
                       -52, accuracy: 0.0001)
    }

    /// Closed loop, with the hardware quantizer in it.
    ///
    /// Two things this pins down. First, the failure being fixed: when the floor
    /// carries all of ENVO's own output, the control law converges to
    /// `gain/(1−gain)` — 0.67 dB per dB of room change instead of the 0.40 it
    /// was tuned for. Second, that the correction restores the design gain.
    ///
    /// The quantizer is not incidental. iOS moves the system volume in steps
    /// worth roughly 3 dB, and the control law's own rate limit is 0.75 dB/s, so
    /// ENVO's *intent* never changes by a decibel in a single tick — but what it
    /// *delivers* jumps a whole step at a time. Those jumps are the only probe
    /// signal available. Feed the estimator the unquantized intent and it
    /// correctly finds nothing to measure.
    ///
    /// This scenario is also exactly why the route prior exists: a single
    /// transient produces at most one usable observation, and once the loop
    /// settles it produces none, so the prior is what is carrying the correction
    /// most of the time.
    func testClosedLoopCorrectionMovesTowardTheDesignGain() {
        let law = ControlLaw(gain: 0.40, smoothing: 0.85,
                             zeroHysteresisDB: 0.5, maxRateDBPerSecond: 0.75)
        let roomRise: Float = 10
        let hardwareStepDB: Float = 3.0

        func settle(correcting: Bool) -> Float {
            var e = estimator()
            e.settleTicks = 12
            e.windowTicks = 4
            e.prior = correcting ? 0.75 : 0            // built-in speaker
            var offset: Float = 0
            var baseline: Float?

            for tick in 0..<600 {
                let room: Float = tick < 40 ? -50 : -50 + roomRise
                let delivered = (offset / hardwareStepDB).rounded() * hardwareStepDB
                // Fully coupled: the measured floor carries all of ENVO's output.
                let floor = room + delivered
                e.ingest(floorDB: floor, deliveredDB: delivered)

                let observed = correcting
                    ? e.roomLevelDB(fromFloorDB: floor, deliveredDB: delivered)
                    : floor

                guard let anchored = baseline else {
                    if tick >= 20 { baseline = observed }
                    continue
                }
                offset = law.nextOffsetDB(currentOffsetDB: offset,
                                          noiseDeltaDB: observed - anchored,
                                          rangeDB: 9,
                                          allowIncrease: true,
                                          allowDecrease: true)
            }
            return offset
        }

        let target = roomRise * 0.40
        let uncorrected = settle(correcting: false)
        let corrected = settle(correcting: true)

        XCTAssertGreaterThan(uncorrected, roomRise * 0.55,
                             "uncorrected, a fully coupled floor over-compensates")
        XCTAssertLessThan(abs(corrected - target), abs(uncorrected - target),
                          "the correction must move the loop toward its design gain")
        XCTAssertEqual(corrected, target, accuracy: 1.5)
    }

    // MARK: - Lifecycle

    func testResetClearsEverything() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 1.0)
        e.reset()
        XCTAssertEqual(e.coupling, 0, accuracy: 0.0001)
        XCTAssertEqual(e.observationCount, 0)
    }

    /// A re-anchor drops `deliveredDB` to zero without ENVO having stepped
    /// anything. That must not be mistaken for a probe — but what has already
    /// been learned about the route is still true.
    func testDiscardingAProbeKeepsWhatWasLearned() {
        var e = estimator()
        feed(&e, ticks: 6,  roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 3, trueCoupling: 1.0)
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 6, trueCoupling: 1.0)
        let learned = e.coupling

        e.discardObservationInProgress()
        XCTAssertEqual(e.coupling, learned, accuracy: 0.0001)

        // The zeroing itself must not register as an observation.
        let before = e.observationCount
        feed(&e, ticks: 10, roomDB: -40, deliveredDB: 0, trueCoupling: 1.0)
        XCTAssertEqual(e.observationCount, before)
    }

    func testHostileInputsAreIgnored() {
        var e = estimator()
        e.ingest(floorDB: .nan, deliveredDB: 3)
        e.ingest(floorDB: -40, deliveredDB: .infinity)
        XCTAssertEqual(e.coupling, 0, accuracy: 0.0001)
        XCTAssertTrue(e.roomLevelDB(fromFloorDB: -40, deliveredDB: 3).isFinite)
    }
}
