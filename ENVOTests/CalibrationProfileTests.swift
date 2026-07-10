import XCTest
@testable import ENVO

final class CalibrationProfileTests: XCTestCase {

    private func profile(silenceFloor: Float = 0.1,
                         points: [(Float, Float)] = [
                            (0.0, 0.1),
                            (0.5, 0.4),
                            (1.0, 0.8)
                         ]) -> CalibrationProfile {
        CalibrationProfile(
            silenceFloor: silenceFloor,
            points: points.map { .init(volume: $0.0, micLevel: $0.1) },
            date: Date()
        )
    }

    func testEmptyProfileReturnsSilenceFloor() {
        let p = CalibrationProfile(silenceFloor: 0.12, points: [], date: Date())
        XCTAssertEqual(p.expectedMicLevel(atVolume: 0.5), 0.12)
    }

    func testSinglePointProfileReturnsThatLevel() {
        let p = CalibrationProfile(
            silenceFloor: 0.1,
            points: [.init(volume: 0.5, micLevel: 0.42)],
            date: Date()
        )
        XCTAssertEqual(p.expectedMicLevel(atVolume: 0.0), 0.42)
        XCTAssertEqual(p.expectedMicLevel(atVolume: 1.0), 0.42)
    }

    func testInterpolationAtMidpoint() {
        let p = profile()
        XCTAssertEqual(p.expectedMicLevel(atVolume: 0.25), 0.25, accuracy: 0.0001)
        XCTAssertEqual(p.expectedMicLevel(atVolume: 0.75), 0.6, accuracy: 0.0001)
    }

    func testVolumeBelowFirstClampsToFirst() {
        let p = profile()
        XCTAssertEqual(p.expectedMicLevel(atVolume: -0.5), 0.1)
    }

    func testVolumeAboveLastClampsToLast() {
        let p = profile()
        XCTAssertEqual(p.expectedMicLevel(atVolume: 1.5), 0.8)
    }

    func testEstimateAmbientSubtractsDeviceContribution() {
        // With silenceFloor 0.1 and a 0.5-vol point of 0.4, device
        // contribution at vol=0.5 is 0.3. Raw mic = 0.45 → ambient = 0.15.
        let p = profile()
        let ambient = p.estimateAmbient(rawMicLevel: 0.45, atVolume: 0.5)
        XCTAssertEqual(ambient, 0.15, accuracy: 0.0001)
    }

    func testEstimateAmbientClampsAtZero() {
        // Raw mic below the calibrated device output → ambient cannot
        // be negative.
        let p = profile()
        let ambient = p.estimateAmbient(rawMicLevel: 0.05, atVolume: 0.5)
        XCTAssertEqual(ambient, 0)
    }

    func testZeroWidthPointsDoNotDivideByZero() {
        // Two points at the same volume must not crash.
        let p = CalibrationProfile(
            silenceFloor: 0.1,
            points: [
                .init(volume: 0.5, micLevel: 0.3),
                .init(volume: 0.5, micLevel: 0.5)
            ],
            date: Date()
        )
        let result = p.expectedMicLevel(atVolume: 0.5)
        XCTAssertTrue(result.isFinite)
    }
}
