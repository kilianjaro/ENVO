import XCTest
@testable import ENVO

/// The arithmetic these tests pin down is the arithmetic the old code got
/// wrong. Each case here corresponds to an operation that was previously
/// performed on decibel values as if they were linear.
final class AcousticMathTests: XCTestCase {

    func testPowerRoundTrip() {
        for dB in stride(from: Float(-100), through: 0, by: 7) {
            let back = AcousticMath.dB(fromPower: AcousticMath.power(fromDB: dB))
            XCTAssertEqual(back, dB, accuracy: 0.01, "round trip failed at \(dB)")
        }
    }

    /// Two equal sources are 3 dB louder together, not twice the number.
    func testEqualSourcesAddThreeDB() {
        // Exactly 10·log10(2) = 3.0103 dB.
        XCTAssertEqual(AcousticMath.addDB(-60, -60), -56.99, accuracy: 0.02)
        XCTAssertEqual(AcousticMath.addDB(-40, -40), -36.99, accuracy: 0.02)
    }

    /// A much quieter source barely moves the total.
    func testFarQuieterSourceBarelyAdds() {
        XCTAssertEqual(AcousticMath.addDB(-40, -80), -40, accuracy: 0.01)
    }

    /// Subtraction must invert addition. This is the operation calibration
    /// relies on to separate the room from the speaker.
    func testSubtractInvertsAdd() {
        let room: Float = -63
        let speaker: Float = -55
        let mixed = AcousticMath.addDB(room, speaker)
        XCTAssertEqual(AcousticMath.subtractDB(mixed, speaker), room, accuracy: 0.05)
    }

    func testSubtractingAnEqualOrLouderComponentIsSilence() {
        XCTAssertEqual(AcousticMath.subtractDB(-50, -50), AcousticMath.silenceDB)
        XCTAssertEqual(AcousticMath.subtractDB(-50, -40), AcousticMath.silenceDB)
    }

    /// Energy-weighted averaging must not under-weight the loud samples the
    /// way arithmetic dB averaging does.
    func testMeanIsEnergyWeighted() {
        let mean = AcousticMath.meanDB([-60, -40])
        // Arithmetic mean would be -50; the energetic mean is dominated by
        // the louder sample and lands near -43.
        XCTAssertEqual(mean, -43.0, accuracy: 0.2)
        XCTAssertGreaterThan(mean, -50)
    }

    func testMeanOfIdenticalValuesIsThatValue() {
        XCTAssertEqual(AcousticMath.meanDB([-57, -57, -57]), -57, accuracy: 0.01)
    }

    func testEmptyMeanIsSilenceNotNaN() {
        XCTAssertEqual(AcousticMath.meanDB([]), AcousticMath.silenceDB)
    }

    // MARK: - Totality

    func testNoInputProducesNaNOrInfinity() {
        let hostile: [Float] = [0, -.infinity, .infinity, .nan,
                                -1000, 1000, AcousticMath.silenceDB]
        for a in hostile {
            XCTAssertTrue(AcousticMath.power(fromDB: a).isFinite, "power(\(a))")
            XCTAssertTrue(AcousticMath.dB(fromPower: a).isFinite, "dB(\(a))")
            for b in hostile {
                XCTAssertTrue(AcousticMath.addDB(a, b).isFinite, "add(\(a),\(b))")
                XCTAssertTrue(AcousticMath.subtractDB(a, b).isFinite, "sub(\(a),\(b))")
            }
        }
    }
}
