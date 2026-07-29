import XCTest
@testable import ENVO

/// Verifies the filter against the IEC 61672 A-weighting curve by measuring
/// its actual gain on sine waves — the same path the audio thread uses —
/// rather than by inspecting coefficients.
final class AWeightingFilterTests: XCTestCase {

    private let sampleRate: Double = 48000

    /// Gain in dB at a frequency, measured by running a sine through the
    /// filter and comparing RMS in to RMS out. Skips the first cycles so the
    /// biquad state has settled.
    private func gainDB(at frequency: Double, sampleRate: Double = 48000) -> Float {
        var filter = AWeightingFilter(sampleRate: sampleRate)
        let settle = Int(sampleRate * 0.5)
        let measure = Int(sampleRate * 0.5)

        var sumIn: Double = 0
        var sumOut: Double = 0

        for n in 0..<(settle + measure) {
            let phase = 2 * Double.pi * frequency * Double(n) / sampleRate
            let x = Float(sin(phase))
            let y = filter.process(x)
            if n >= settle {
                sumIn += Double(x) * Double(x)
                sumOut += Double(y) * Double(y)
            }
        }
        guard sumIn > 0, sumOut > 0 else { return -200 }
        return Float(10 * log10(sumOut / sumIn))
    }

    /// Reference values from the IEC 61672 A-weighting table.
    func testMatchesTheStandardCurve() {
        let expected: [(frequency: Double, dB: Float, tolerance: Float)] = [
            (31.5,  -39.4, 1.0),
            (63.0,  -26.2, 0.7),
            (100.0, -19.1, 0.5),
            (200.0, -10.9, 0.5),
            (500.0,  -3.2, 0.4),
            (1000.0,  0.0, 0.1),
            (2000.0,  1.2, 0.4),
            (4000.0,  1.0, 0.5),
            (8000.0,  -1.1, 1.0),
            (10000.0, -2.5, 1.5)   // bilinear warping grows near Nyquist
        ]

        for (frequency, target, tolerance) in expected {
            let measured = gainDB(at: frequency)
            XCTAssertEqual(measured, target, accuracy: tolerance,
                           "A-weighting at \(frequency) Hz: expected \(target), got \(measured)")
        }
    }

    func testUnityAtOneKilohertz() {
        XCTAssertEqual(gainDB(at: 1000), 0, accuracy: 0.1)
    }

    /// The whole point: low-frequency rumble is heavily discounted.
    func testRumbleIsStronglyAttenuated() {
        XCTAssertLessThan(gainDB(at: 50), -25,
                          "50 Hz rumble must be discounted, not counted in full")
    }

    func testNormalizationHoldsAcrossSampleRates() {
        for rate in [44100.0, 48000.0] {
            XCTAssertEqual(gainDB(at: 1000, sampleRate: rate), 0, accuracy: 0.15,
                           "not unity at 1 kHz for \(rate) Hz")
        }
    }

    // MARK: - Robustness

    func testSilenceInSilenceOut() {
        var filter = AWeightingFilter(sampleRate: sampleRate)
        for _ in 0..<1000 {
            XCTAssertEqual(filter.process(0), 0, accuracy: 1e-9)
        }
    }

    func testOutputStaysFiniteOnHostileInput() {
        var filter = AWeightingFilter(sampleRate: sampleRate)
        for value in [Float(1), -1, 0, 1e6, -1e6, 0.5] {
            for _ in 0..<200 {
                XCTAssertTrue(filter.process(value).isFinite)
            }
        }
    }

    func testResetClearsState() {
        var filter = AWeightingFilter(sampleRate: sampleRate)
        for _ in 0..<500 { _ = filter.process(1.0) }
        filter.reset()
        // With cleared state the first sample of silence must produce silence.
        XCTAssertEqual(filter.process(0), 0, accuracy: 1e-9)
    }

    /// The filter is stable: a bounded input cannot produce a growing output.
    func testStableUnderSustainedInput() {
        var filter = AWeightingFilter(sampleRate: sampleRate)
        var peak: Float = 0
        for n in 0..<Int(sampleRate * 2) {
            let phase = 2 * Double.pi * 1000 * Double(n) / sampleRate
            peak = max(peak, abs(filter.process(Float(sin(phase)))))
        }
        XCTAssertLessThan(peak, 2.0, "filter output is growing without bound")
    }
}
