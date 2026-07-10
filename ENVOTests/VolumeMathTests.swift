import XCTest
@testable import ENVO

final class VolumeMathTests: XCTestCase {

    func testZeroDBProducesZeroDelta() {
        let delta = VolumeMath.volumeDelta(forDB: 0, atBase: 0.5)
        XCTAssertEqual(delta, 0, accuracy: 0.0001)
    }

    func testPositiveDBIncreasesVolume() {
        let delta = VolumeMath.volumeDelta(forDB: 6, atBase: 0.5)
        XCTAssertGreaterThan(delta, 0)
    }

    func testNegativeDBDecreasesVolume() {
        let delta = VolumeMath.volumeDelta(forDB: -6, atBase: 0.5)
        XCTAssertLessThan(delta, 0)
    }

    func test6dBRoughlyDoublesAmplitude() {
        // +6 dB ≈ 2× amplitude. From a base of 0.4, target ≈ 0.8.
        let delta = VolumeMath.volumeDelta(forDB: 6, atBase: 0.4)
        XCTAssertEqual(delta, 0.4, accuracy: 0.02)
    }

    func test3dBRoughlyMultipliesBy1_41() {
        // +3 dB ≈ ×1.4125.
        let delta = VolumeMath.volumeDelta(forDB: 3, atBase: 0.5)
        let target = 0.5 + delta
        XCTAssertEqual(target / 0.5, 1.4125, accuracy: 0.02)
    }

    func testCeilingIsHonored() {
        // From 0.9 with +6 dB, raw target would be 1.8. With ceiling 0.92,
        // delta should be exactly 0.02.
        let delta = VolumeMath.volumeDelta(forDB: 6, atBase: 0.9, ceiling: 0.92)
        XCTAssertEqual(0.9 + delta, 0.92, accuracy: 0.0001)
    }

    func testCeilingNotTriggeredBelowLimit() {
        // From 0.4 with +6 dB target 0.8 < ceiling 0.92, no clamp.
        let delta = VolumeMath.volumeDelta(forDB: 6, atBase: 0.4, ceiling: 0.92)
        XCTAssertEqual(0.4 + delta, 0.8, accuracy: 0.01)
    }

    func testInverseIsConsistent() {
        // Round trip: convert dB → delta → dB.
        let base: Float = 0.5
        let dB: Float = 4.5
        let delta = VolumeMath.volumeDelta(forDB: dB, atBase: base)
        let backDB = VolumeMath.dB(forDelta: delta, atBase: base)
        XCTAssertEqual(backDB, dB, accuracy: 0.05)
    }

    func testBaseRelativity() {
        // +3 dB at base 0.2 should be a SMALLER absolute delta than +3 dB
        // at base 0.8, because the multiplier scales the base.
        let small = VolumeMath.volumeDelta(forDB: 3, atBase: 0.2)
        let large = VolumeMath.volumeDelta(forDB: 3, atBase: 0.8, ceiling: 2.0)
        XCTAssertLessThan(small, large)
    }
}
