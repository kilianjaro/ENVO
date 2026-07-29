import XCTest
@testable import ENVO

/// Rewritten for the v2 profile. The v1 tests asserted that
/// `estimateAmbient(rawMicLevel: 0.45, atVolume: 0.5)` returns 0.15 — the
/// result of subtracting one decibel value from another. That number was
/// self-consistent and physically meaningless, and the tests locked it in.
final class CalibrationProfileTests: XCTestCase {

    /// A plausible sweep: quiet room at −68 dBFS, speaker rising to −22 dBFS
    /// at full volume.
    private func profile(
        silenceFloorDB: Float = -68,
        points: [(Float, Float)] = [
            (0.25, -52.0),
            (0.40, -43.0),
            (0.55, -36.0),
            (0.70, -30.5),
            (0.85, -26.0),
            (1.00, -22.0)
        ],
        route: String? = nil
    ) -> CalibrationProfile {
        CalibrationProfile(
            version: CalibrationProfile.currentVersion,
            silenceFloorDB: silenceFloorDB,
            points: points.map { .init(volume: $0.0, micLevelDB: $0.1) },
            date: Date(),
            routePortType: route
        )
    }

    // MARK: - Interpolation

    func testEmptyProfileReturnsSilenceFloor() {
        let p = CalibrationProfile(silenceFloorDB: -70, points: [],
                                   date: Date(), routePortType: nil)
        XCTAssertEqual(p.expectedMicLevelDB(atVolume: 0.5), -70)
    }

    func testInterpolatesBetweenPoints() {
        let p = profile()
        // Midway between the 0.25 (−52) and 0.40 (−43) points.
        XCTAssertEqual(p.expectedMicLevelDB(atVolume: 0.325), -47.5, accuracy: 0.1)
    }

    func testClampsOutsideTheMeasuredRange() {
        let p = profile()
        XCTAssertEqual(p.expectedMicLevelDB(atVolume: -0.5), -52)
        XCTAssertEqual(p.expectedMicLevelDB(atVolume: 1.5), -22)
    }

    func testDuplicateVolumesDoNotDivideByZero() {
        let p = CalibrationProfile(
            silenceFloorDB: -70,
            points: [.init(volume: 0.5, micLevelDB: -40),
                     .init(volume: 0.5, micLevelDB: -35)],
            date: Date(), routePortType: nil
        )
        XCTAssertTrue(p.expectedMicLevelDB(atVolume: 0.5).isFinite)
    }

    // MARK: - Speaker contribution
    //
    // The profile no longer offers a runtime ambient estimate — see the note
    // in CalibrationProfile. What it still provides is the speaker's own level
    // during the sweep, which feeds the measured taper and the calibration log.

    func testDeviceContributionRemovesTheRoomEnergetically() {
        // Speaker and room equal at the mic: the mixed reading is 3 dB above
        // either, so removing the room must leave the speaker.
        let room: Float = -60
        let p = profile(silenceFloorDB: room,
                        points: [(0.25, -57.0), (0.55, -50.0), (1.0, -40.0)])
        XCTAssertEqual(p.deviceContributionDB(atVolume: 0.25), -60, accuracy: 0.2)
    }

    func testDeviceContributionIsSilenceWhenTheSweepHeardOnlyTheRoom() {
        let p = profile(silenceFloorDB: -60,
                        points: [(0.25, -60.0), (0.55, -60.0), (1.0, -60.0)])
        XCTAssertEqual(p.deviceContributionDB(atVolume: 0.55), AcousticMath.silenceDB)
    }

    func testDeviceContributionRisesWithVolume() {
        let p = profile()
        var previous = -Float.infinity
        for v in [Float(0.25), 0.40, 0.55, 0.70, 0.85, 1.0] {
            let value = p.deviceContributionDB(atVolume: v)
            XCTAssertGreaterThan(value, previous)
            previous = value
        }
    }

    // MARK: - Validation

    func testUsableProfileIsAccepted() {
        XCTAssertTrue(profile().isUsable)
    }

    func testProfileThatHeardNothingIsRejected() {
        // Every step at the room floor: the exact signature of the silent
        // sweep / deaf mic bug.
        let p = profile(silenceFloorDB: -68, points: [
            (0.25, -68), (0.40, -68), (0.55, -68),
            (0.70, -68), (0.85, -68), (1.00, -67.5)
        ])
        XCTAssertFalse(p.isUsable)
    }

    func testTooFewPointsIsRejected() {
        XCTAssertFalse(profile(points: [(0.5, -40), (1.0, -25)]).isUsable)
    }

    func testWrongVersionIsRejected() {
        var p = profile()
        p.version = 1
        XCTAssertFalse(p.isUsable)
    }

    // MARK: - Measured taper

    func testDerivesAPlausibleTaperFromTheSweep() {
        guard let taper = profile().measuredTaper else {
            return XCTFail("a good sweep must yield a taper")
        }
        XCTAssertGreaterThan(taper.spanDB, 20)
        XCTAssertLessThan(taper.spanDB, 90)
    }

    func testNoTaperFromASweepThatHeardNothing() {
        let p = profile(silenceFloorDB: -68, points: [
            (0.25, -68), (0.40, -68), (0.55, -68),
            (0.70, -68), (0.85, -68), (1.00, -67.5)
        ])
        XCTAssertNil(p.measuredTaper)
    }

    /// A profile made on one route must not silently supply its taper on
    /// another. Calibrating on the phone speaker says nothing about the curve
    /// a Bluetooth speaker applies.
    func testFallsBackToDefaultTaperOnAnUnknownRoute() {
        let p = profile(route: "SomeOtherPort")
        XCTAssertFalse(p.taperAppliesToCurrentRoute())
        XCTAssertEqual(p.applicableTaper, VolumeTaper.default)
    }

    func testFallsBackToDefaultTaperWhenNoRouteWasRecorded() {
        XCTAssertEqual(profile(route: nil).applicableTaper, VolumeTaper.default)
    }
}
