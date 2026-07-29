import XCTest
@testable import ENVO

/// The guard on the failure mode that mattered most in the field: a phone in a
/// pocket or lying face-down reads 15–25 dB quiet, the low percentile follows it
/// straight down, and ENVO concludes the room went silent and turns the volume
/// down — usually at the exact moment the user started walking somewhere noisy.
final class ObstructionDetectorTests: XCTestCase {

    /// The engine feeds this at 10 Hz.
    private let dt: Float = 0.1

    private func feed(_ d: inout ObstructionDetector,
                      seconds: Float,
                      levelDB: Float,
                      highFrequencyShare: Float) {
        var t: Float = 0
        while t < seconds {
            d.ingest(levelDB: levelDB, highFrequencyShare: highFrequencyShare, dt: dt)
            t += dt
        }
    }

    /// Clear air: phone on a desk, room around it.
    private func settled() -> ObstructionDetector {
        var d = ObstructionDetector()
        feed(&d, seconds: 10, levelDB: -50, highFrequencyShare: 0.30)
        return d
    }

    func testClearAirIsNotObstructed() {
        XCTAssertFalse(settled().isObstructed)
    }

    /// Into a pocket: the level collapses and so does the top end.
    func testPocketIsDetected() {
        var d = settled()
        feed(&d, seconds: 4, levelDB: -70, highFrequencyShare: 0.06)
        XCTAssertTrue(d.isObstructed)
    }

    /// The discrimination that makes this usable. A room that genuinely went
    /// quiet — a fan switching off, a café emptying — drops just as far in level
    /// but keeps its spectral shape, and must be honoured rather than suppressed.
    func testAQuieterRoomIsNotMistakenForAPocket() {
        var d = settled()
        feed(&d, seconds: 10, levelDB: -66, highFrequencyShare: 0.30)
        XCTAssertFalse(d.isObstructed,
                       "a uniformly quieter room keeps its high-frequency share")
    }

    /// Muffling without a level drop is not an obstruction either — it is just a
    /// duller room.
    func testDullerRoomAtTheSameLevelIsNotObstruction() {
        var d = settled()
        feed(&d, seconds: 10, levelDB: -50, highFrequencyShare: 0.05)
        XCTAssertFalse(d.isObstructed)
    }

    /// Brief handling must not flip the state, or the advisory would flicker
    /// every time the phone is picked up.
    func testBriefOcclusionDoesNotTrigger() {
        var d = settled()
        feed(&d, seconds: 1.0, levelDB: -70, highFrequencyShare: 0.06)
        XCTAssertFalse(d.isObstructed)
    }

    func testTakingThePhoneOutClearsIt() {
        var d = settled()
        feed(&d, seconds: 5, levelDB: -70, highFrequencyShare: 0.06)
        XCTAssertTrue(d.isObstructed)

        feed(&d, seconds: 3, levelDB: -50, highFrequencyShare: 0.30)
        XCTAssertFalse(d.isObstructed)
    }

    /// The reference is frozen while obstructed. Without that, twenty minutes in
    /// a pocket would slowly redefine "normal" as muffled, the drop would stop
    /// looking like a drop, and the detector would clear itself while still in
    /// the pocket.
    func testALongStayInThePocketStaysDetected() {
        var d = settled()
        feed(&d, seconds: 600, levelDB: -70, highFrequencyShare: 0.06)
        XCTAssertTrue(d.isObstructed, "the reference must not drift onto the pocket")
    }

    /// Nothing is reported before there is enough clear air to have a reference.
    func testNoVerdictBeforeWarmup() {
        var d = ObstructionDetector()
        feed(&d, seconds: 2, levelDB: -50, highFrequencyShare: 0.30)
        feed(&d, seconds: 4, levelDB: -70, highFrequencyShare: 0.06)
        XCTAssertFalse(d.isObstructed)
    }

    func testHostileInputsAreIgnored() {
        var d = settled()
        d.ingest(levelDB: .nan, highFrequencyShare: 0.3, dt: dt)
        d.ingest(levelDB: -50, highFrequencyShare: .infinity, dt: dt)
        d.ingest(levelDB: -50, highFrequencyShare: 0.3, dt: 0)
        XCTAssertFalse(d.isObstructed)
    }

    func testResetClearsState() {
        var d = settled()
        feed(&d, seconds: 5, levelDB: -70, highFrequencyShare: 0.06)
        XCTAssertTrue(d.isObstructed)
        d.reset()
        XCTAssertFalse(d.isObstructed)
    }
}
