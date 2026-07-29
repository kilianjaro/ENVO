import XCTest
@testable import ENVO

/// Replaces VolumeMathTests, which asserted the behaviour of the broken
/// model — that "+6 dB" should double the slider value. Those tests passed
/// consistently while the app over-delivered by roughly a factor of two,
/// which is the failure mode this file is written to make impossible.
final class VolumeTaperTests: XCTestCase {

    // MARK: - Curve basics

    func testFaderSlopeIsExact() {
        let taper = VolumeTaper(spanDB: 48)
        XCTAssertEqual(taper.spanDB, 48, accuracy: 0.01)
        XCTAssertEqual(taper.gainDB(atVolume: 1.0), 0, accuracy: 0.01)
        // Half a slider is half the span down, not −6 dB.
        XCTAssertEqual(taper.gainDB(atVolume: 0.5), -24, accuracy: 0.5)
    }

    func testHalvingTheSliderIsFarMoreThanSixDB() {
        // The specific belief the old model encoded, stated as its refutation.
        let taper = VolumeTaper.default
        let delivered = taper.deliveredDB(forDelta: -0.25, atBase: 0.5)
        XCTAssertLessThan(delivered, -10,
                          "Halving the slider must read as much more than -6 dB")
    }

    func testInverseIsConsistentAcrossTheCurve() {
        let taper = VolumeTaper.default
        for v in stride(from: Float(0.05), through: 1.0, by: 0.05) {
            let gain = taper.gainDB(atVolume: v)
            XCTAssertEqual(taper.volume(forGainDB: gain), v, accuracy: 0.005,
                           "inverse failed at volume \(v)")
        }
    }

    // MARK: - The bound that leaked

    /// The core guarantee: for the taper in use, the delivered change never
    /// exceeds the user's range setting — at any base volume, any range, any
    /// requested amount, including absurd ones.
    func testDeliveredDBNeverExceedsRange() {
        let tapers: [VolumeTaper] = [
            .default,
            VolumeTaper(spanDB: 36),
            VolumeTaper(spanDB: 48),
            VolumeTaper(spanDB: 70),
            measuredTaper()
        ]
        let ranges: [Float] = [3, 6, 9]
        let requests: [Float] = [-100, -9, -6, -3, -0.5, 0, 0.5, 3, 6, 9, 100]

        for taper in tapers {
            for range in ranges {
                for base in stride(from: Float(0.0), through: 1.0, by: 0.05) {
                    for request in requests {
                        let delta = taper.volumeDelta(forDB: request,
                                                      atBase: base,
                                                      rangeDB: range,
                                                      ceiling: 0.92)
                        let delivered = taper.deliveredDB(forDelta: delta, atBase: base)

                        XCTAssertLessThanOrEqual(
                            abs(delivered), range + 0.15,
                            "range \(range) breached at base \(base) request \(request): delivered \(delivered)"
                        )
                    }
                }
            }
        }
    }

    /// The safety ceiling and the 0…1 slider bounds hold unconditionally.
    func testResultingVolumeAlwaysWithinCeilingAndBounds() {
        let taper = VolumeTaper.default
        for range in [Float(3), 6, 9] {
            for base in stride(from: Float(0.0), through: 1.0, by: 0.025) {
                for request in [Float(-50), -9, 0, 9, 50] {
                    let delta = taper.volumeDelta(forDB: request,
                                                  atBase: base,
                                                  rangeDB: range,
                                                  ceiling: 0.92)
                    let result = base + delta
                    XCTAssertGreaterThanOrEqual(result, 0, "below zero at base \(base)")
                    XCTAssertLessThanOrEqual(result, 1.0, "above one at base \(base)")
                    if base <= 0.92 {
                        XCTAssertLessThanOrEqual(result, 0.92 + 0.0001,
                                                 "ceiling breached at base \(base)")
                    }
                }
            }
        }
    }

    func testSliderTravelNeverExceedsAbsoluteLimit() {
        for taper in [VolumeTaper.default, VolumeTaper(spanDB: 12), measuredTaper()] {
            for base in stride(from: Float(0.0), through: 1.0, by: 0.05) {
                for request in [Float(-200), -9, 9, 200] {
                    let delta = taper.volumeDelta(forDB: request,
                                                  atBase: base,
                                                  rangeDB: 9,
                                                  ceiling: 0.92)
                    XCTAssertLessThanOrEqual(abs(delta),
                                             VolumeTaper.absoluteMaxDelta + 0.0001)
                }
            }
        }
    }

    /// Assuming a steeper curve than reality must under-deliver, never
    /// over-deliver. This is the property that makes the uncalibrated default
    /// safe, and it is the exact inverse of what the old model did.
    func testUncalibratedDefaultUnderDeliversAgainstShallowerRealCurves() {
        let assumed = VolumeTaper.default            // steep: 60 dB/slider
        for realSpan in [Float(35), 40, 45, 50, 55, 60] {
            let real = VolumeTaper(spanDB: realSpan)
            for base in stride(from: Float(0.15), through: 0.9, by: 0.05) {
                for request in [Float(-6), -3, 3, 6] {
                    let delta = assumed.volumeDelta(forDB: request, atBase: base,
                                                    rangeDB: 6, ceiling: 0.92)
                    let actuallyDelivered = real.deliveredDB(forDelta: delta, atBase: base)
                    XCTAssertLessThanOrEqual(
                        abs(actuallyDelivered), abs(request) + 0.05,
                        "over-delivered on a \(realSpan) dB curve at base \(base)"
                    )
                }
            }
        }
    }

    func testZeroRequestProducesNoMovement() {
        for taper in [VolumeTaper.default, measuredTaper()] {
            for base in stride(from: Float(0.05), through: 1.0, by: 0.05) {
                XCTAssertEqual(taper.volumeDelta(forDB: 0, atBase: base,
                                                 rangeDB: 6, ceiling: 0.92),
                               0, accuracy: 0.0005)
            }
        }
    }

    func testDirectionIsCorrect() {
        let taper = VolumeTaper.default
        XCTAssertGreaterThan(taper.volumeDelta(forDB: 3, atBase: 0.5, rangeDB: 6), 0)
        XCTAssertLessThan(taper.volumeDelta(forDB: -3, atBase: 0.5, rangeDB: 6), 0)
    }

    // MARK: - Measured taper construction

    func testMeasuredTaperRejectsTooFewPoints() {
        XCTAssertNil(VolumeTaper(measuredPoints: []))
        XCTAssertNil(VolumeTaper(measuredPoints: [(0.5, -20)]))
    }

    func testMeasuredTaperRejectsFlatCurve() {
        // A sweep where the mic heard the same level at every volume measured
        // something other than the speaker.
        XCTAssertNil(VolumeTaper(measuredPoints: [
            (0.25, -50), (0.5, -50), (0.75, -50), (1.0, -50)
        ]))
    }

    func testMeasuredTaperRejectsImplausibleSpan() {
        // 4 dB across the whole slider.
        XCTAssertNil(VolumeTaper(measuredPoints: [
            (0.25, -4), (0.6, -2), (1.0, 0)
        ]))
        // 200 dB across the whole slider.
        XCTAssertNil(VolumeTaper(measuredPoints: [
            (0.25, -150), (0.6, -75), (1.0, 0)
        ]))
    }

    func testMeasuredTaperRejectsNonMonotonicData() {
        XCTAssertNil(VolumeTaper(measuredPoints: [
            (0.25, -30), (0.5, -35), (0.75, -38), (1.0, -40)
        ]))
    }

    func testMeasuredTaperIsUsedAndIsInvertible() {
        let taper = measuredTaper()
        XCTAssertGreaterThan(taper.spanDB, 12)
        for v in stride(from: Float(0.3), through: 1.0, by: 0.05) {
            let gain = taper.gainDB(atVolume: v)
            XCTAssertEqual(taper.volume(forGainDB: gain), v, accuracy: 0.01)
        }
    }

    /// Under a measured taper the bound is not merely respected — it is met.
    /// This is what calibration buys.
    ///
    /// Run without a ceiling: near the top of the slider the safety ceiling
    /// legitimately truncates an upward request, and that is covered by
    /// `testResultingVolumeAlwaysWithinCeilingAndBounds`.
    func testMeasuredTaperDeliversWhatWasAsked() {
        let taper = measuredTaper()
        for base in stride(from: Float(0.35), through: 0.75, by: 0.05) {
            for request in [Float(-6), -3, 3, 6] {
                let delta = taper.volumeDelta(forDB: request, atBase: base,
                                              rangeDB: 6, ceiling: 1.0)
                let delivered = taper.deliveredDB(forDelta: delta, atBase: base)
                XCTAssertEqual(delivered, request, accuracy: 0.2,
                               "base \(base) request \(request)")
            }
        }
    }

    /// The ceiling caps ENVO's own contribution; it must never pull a user
    /// who has chosen a high volume back down.
    func testCeilingNeverDragsTheUserDown() {
        let taper = VolumeTaper.default
        for base in [Float(0.93), 0.95, 1.0] {
            for request in [Float(0), 3, 6, -6] {
                let delta = taper.volumeDelta(forDB: request, atBase: base,
                                              rangeDB: 6, ceiling: 0.92)
                if request >= 0 {
                    XCTAssertEqual(delta, 0, accuracy: 0.0005,
                                   "ENVO moved a base of \(base) on a +\(request) dB request")
                } else {
                    XCTAssertLessThanOrEqual(delta, 0)
                }
            }
        }
    }

    // MARK: - Helpers

    /// A realistic sweep result: roughly 45 dB across the slider, slightly
    /// steeper at the bottom, as a real speaker curve is.
    private func measuredTaper() -> VolumeTaper {
        VolumeTaper(measuredPoints: [
            (0.25, -30.0),
            (0.40, -21.0),
            (0.55, -14.0),
            (0.70, -8.5),
            (0.85, -4.0),
            (1.00, 0.0)
        ])!
    }
}
