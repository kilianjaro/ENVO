import XCTest
@testable import ENVO

/// Drives the production control law directly. The previous safety argument
/// rested on a separate simulation that reimplemented `tick()`, so it could
/// only ever prove things about itself.
final class ControlLawTests: XCTestCase {

    private func law(gain: Float = 0.4,
                     smoothing: Float = 0.85,
                     hysteresis: Float = 0.5,
                     rate: Float = 0.75) -> ControlLaw {
        ControlLaw(gain: gain,
                   smoothing: smoothing,
                   zeroHysteresisDB: hysteresis,
                   maxRateDBPerSecond: rate)
    }

    /// Runs the loop for `ticks` seconds against a constant room delta and
    /// returns every offset along the way.
    private func run(_ l: ControlLaw,
                     noiseDeltaDB: Float,
                     rangeDB: Float,
                     ticks: Int,
                     allowIncrease: Bool = true,
                     allowDecrease: Bool = true,
                     from start: Float = 0) -> [Float] {
        var offset = start
        var history: [Float] = []
        for _ in 0..<ticks {
            offset = l.nextOffsetDB(currentOffsetDB: offset,
                                    noiseDeltaDB: noiseDeltaDB,
                                    rangeDB: rangeDB,
                                    allowIncrease: allowIncrease,
                                    allowDecrease: allowDecrease)
            history.append(offset)
        }
        return history
    }

    // MARK: - Bounds

    /// The range setting is never exceeded, for any room delta, any starting
    /// offset, any duration.
    func testRangeIsNeverExceeded() {
        for range in [Float(3), 6, 9] {
            for delta in stride(from: Float(-60), through: 60, by: 2.5) {
                let history = run(law(), noiseDeltaDB: delta, rangeDB: range, ticks: 400)
                for offset in history {
                    XCTAssertLessThanOrEqual(
                        abs(offset), range + 0.0001,
                        "range \(range) breached with room delta \(delta): \(offset)"
                    )
                }
            }
        }
    }

    func testRateLimitHoldsEveryTick() {
        let l = law()
        for delta in [Float(-60), -20, -5, 5, 20, 60] {
            var previous: Float = 0
            for offset in run(l, noiseDeltaDB: delta, rangeDB: 9, ticks: 200) {
                XCTAssertLessThanOrEqual(abs(offset - previous),
                                         l.maxRateDBPerSecond + 0.0001,
                                         "rate limit breached: \(previous) → \(offset)")
                previous = offset
            }
        }
    }

    func testHostileInputsCannotMoveTheOffset() {
        let l = law()
        for bad in [Float.nan, .infinity, -.infinity] {
            let next = l.nextOffsetDB(currentOffsetDB: 2.0,
                                      noiseDeltaDB: bad,
                                      rangeDB: 6,
                                      allowIncrease: true,
                                      allowDecrease: true)
            XCTAssertTrue(next.isFinite)
            XCTAssertEqual(next, 2.0, accuracy: 0.0001,
                           "a non-finite reading must hold the offset, not move it")
        }
    }

    func testOffsetOutsideRangeIsPulledBackIn() {
        // Happens when the user narrows the range while ENVO is adjusting.
        let l = law()
        let next = l.nextOffsetDB(currentOffsetDB: 9.0,
                                  noiseDeltaDB: 30,
                                  rangeDB: 3,
                                  allowIncrease: true,
                                  allowDecrease: true)
        XCTAssertLessThanOrEqual(abs(next), 3.0001)
    }

    // MARK: - Behaviour

    func testConvergesToTheGainTimesTheRoomChange() {
        // A 10 dB louder room at gain 0.4 should settle at +4 dB.
        let history = run(law(), noiseDeltaDB: 10, rangeDB: 9, ticks: 300)
        XCTAssertEqual(history.last!, 4.0, accuracy: 0.1)
    }

    func testConvergesToTheRangeLimitWhenTheRoomDemandsMore() {
        let history = run(law(), noiseDeltaDB: 40, rangeDB: 6, ticks: 300)
        XCTAssertEqual(history.last!, 6.0, accuracy: 0.05)
    }

    func testApproachIsMonotonicAndDoesNotOvershoot() {
        let history = run(law(), noiseDeltaDB: 20, rangeDB: 6, ticks: 300)
        var previous: Float = 0
        for offset in history {
            XCTAssertGreaterThanOrEqual(offset, previous - 0.0001, "not monotonic")
            XCTAssertLessThanOrEqual(offset, 6.0001, "overshoot past the limit")
            previous = offset
        }
    }

    /// A steady room must not produce a steady stream of small corrections.
    func testSteadyRoomSettlesCompletely() {
        let history = run(law(), noiseDeltaDB: 8, rangeDB: 6, ticks: 400)
        let tail = history.suffix(50)
        let spread = (tail.max() ?? 0) - (tail.min() ?? 0)
        XCTAssertLessThan(spread, 0.01, "the offset is still hunting after settling")
    }

    func testDeadBandSuppressesTinyRoomChanges() {
        // A 1 dB room change at gain 0.4 wants 0.4 dB — below the dead band.
        let history = run(law(), noiseDeltaDB: 1.0, rangeDB: 6, ticks: 200)
        XCTAssertEqual(history.last!, 0, accuracy: 0.0001)
    }

    /// Regression: the dead band must gate the INTENT, not the smoothed step.
    ///
    /// Applied to the smoothed step, any intent below
    /// `zeroHysteresisDB / (1 - smoothing)` — 3.3 dB with these constants — is
    /// snapped back to zero on every tick and the offset never leaves zero.
    /// That shipped, and presented as "the adjustment stayed 0.0 dB the entire
    /// session no matter how much the room changed".
    func testModestIntentIsNotSwallowedByTheDeadBand() {
        // 6 dB louder room × 0.4 gain = 2.4 dB — comfortably above the 0.5 dB
        // dead band, but only 0.36 dB as a first smoothed step.
        let history = run(law(), noiseDeltaDB: 6, rangeDB: 6, ticks: 200)
        XCTAssertEqual(history.last!, 2.4, accuracy: 0.05)
    }

    /// Every room change that clears the dead band must actually move the
    /// offset, at every range.
    func testEveryIntentAboveTheDeadBandProducesMovement() {
        let l = law()
        for range in [Float(3), 6, 9] {
            for delta in stride(from: Float(1.5), through: 30, by: 0.5) {
                let settled = run(l, noiseDeltaDB: delta, rangeDB: range, ticks: 300).last!
                XCTAssertGreaterThan(
                    settled, 0.4,
                    "room delta \(delta) at range \(range) produced no adjustment"
                )
            }
        }
    }

    /// A room sitting exactly on the dead-band boundary must not flip the
    /// offset on and off.
    func testBoundaryRoomDoesNotChatter() {
        let l = law()
        // Intent of exactly the engage threshold.
        let onBoundary = l.zeroHysteresisDB / l.gain
        let tail = run(l, noiseDeltaDB: onBoundary, rangeDB: 6, ticks: 300).suffix(60)
        let spread = (tail.max() ?? 0) - (tail.min() ?? 0)
        XCTAssertLessThan(spread, 0.01, "the offset is chattering at the dead-band edge")
    }

    func testReturnsToZeroWhenTheRoomReturnsToBaseline() {
        let l = law()
        var offset = run(l, noiseDeltaDB: 15, rangeDB: 6, ticks: 200).last!
        XCTAssertGreaterThan(offset, 1)
        offset = run(l, noiseDeltaDB: 0, rangeDB: 6, ticks: 300, from: offset).last!
        XCTAssertEqual(offset, 0, accuracy: 0.0001)
    }

    // MARK: - Direction filters

    func testIncreaseDisabledNeverRaisesVolume() {
        let history = run(law(), noiseDeltaDB: 30, rangeDB: 9,
                          ticks: 300, allowIncrease: false)
        for offset in history {
            XCTAssertLessThanOrEqual(offset, 0.0001)
        }
    }

    func testDecreaseDisabledNeverLowersVolume() {
        let history = run(law(), noiseDeltaDB: -30, rangeDB: 9,
                          ticks: 300, allowDecrease: false)
        for offset in history {
            XCTAssertGreaterThanOrEqual(offset, -0.0001)
        }
    }

    /// Disabling a direction must let an existing offset in that direction
    /// decay away, not freeze it in place.
    func testDisablingADirectionDecaysAnExistingOffset() {
        let l = law()
        let raised = run(l, noiseDeltaDB: 30, rangeDB: 9, ticks: 200).last!
        XCTAssertGreaterThan(raised, 3)
        let after = run(l, noiseDeltaDB: 30, rangeDB: 9, ticks: 300,
                        allowIncrease: false, from: raised).last!
        XCTAssertEqual(after, 0, accuracy: 0.0001)
    }

    // MARK: - Full stack

    /// The control law and the taper together, which is what actually reaches
    /// the hardware. Neither the promised dB nor the safety ceiling may be
    /// breached at any point in a long run.
    func testEndToEndAgainstTheTaperRespectsEveryBound() {
        let l = law()
        let taper = VolumeTaper.default
        let ceiling: Float = 0.92

        for range in [Float(3), 6, 9] {
            for base in stride(from: Float(0.1), through: 0.95, by: 0.05) {
                for delta in [Float(-50), -12, -4, 4, 12, 50] {
                    var offset: Float = 0
                    for _ in 0..<200 {
                        offset = l.nextOffsetDB(currentOffsetDB: offset,
                                                noiseDeltaDB: delta,
                                                rangeDB: range,
                                                allowIncrease: true,
                                                allowDecrease: true)
                        let slider = taper.volumeDelta(forDB: offset, atBase: base,
                                                       rangeDB: range, ceiling: ceiling)
                        let target = base + slider

                        XCTAssertGreaterThanOrEqual(target, 0)
                        XCTAssertLessThanOrEqual(target, 1.0)
                        if base <= ceiling {
                            XCTAssertLessThanOrEqual(target, ceiling + 0.0001,
                                                     "ceiling breached at base \(base)")
                        }
                        XCTAssertLessThanOrEqual(
                            abs(taper.deliveredDB(forDelta: slider, atBase: base)),
                            range + 0.15,
                            "range \(range) breached at base \(base)"
                        )
                    }
                }
            }
        }
    }
}
