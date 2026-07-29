import Foundation

/// IEC 61672 A-weighting, as a cascade of three biquads.
///
/// WHY WEIGHT AT ALL
/// -----------------
/// A plain broadband RMS answers "how much sound pressure is arriving", which
/// is not the same question as "how loud does this seem". Ears are markedly
/// less sensitive at low frequencies, but low frequencies carry a great deal
/// of energy: traffic rumble, HVAC, a fridge compressor, wind on the mic,
/// handling noise, the body of a bus. Unweighted, those dominate the number
/// while barely affecting whether you can hear your podcast.
///
/// The practical symptom is a level readout that reports a busy-street figure
/// for a room that plainly is not that loud — and, worse for a control loop,
/// an ambient estimate that chases rumble instead of the noise that actually
/// masks speech and music.
///
/// A-weighting is the standard correction: about −19 dB at 100 Hz, 0 dB at
/// 1 kHz, −2.5 dB at 10 kHz. It is what a sound level meter set to dB(A)
/// applies, which also makes ENVO's numbers comparable to any SPL app.
///
/// IMPLEMENTATION
/// --------------
/// The analog prototype has four zeros at the origin and six poles:
///
///     H(s) = k·s⁴ / [ (s+ω₁)²(s+ω₂)(s+ω₃)(s+ω₄)² ]
///
/// Split into three second-order sections and bilinear-transformed. The
/// overall gain is normalized numerically so the response is exactly 0 dB at
/// 1 kHz, rather than hard-coding a constant that would only be right at one
/// sample rate.
struct AWeightingFilter {

    /// Pole frequencies from IEC 61672.
    private static let f1 = 20.598997
    private static let f2 = 107.65265
    private static let f3 = 737.86223
    private static let f4 = 12194.217

    private struct Biquad {
        var b0: Float, b1: Float, b2: Float
        var a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }

        mutating func reset() {
            x1 = 0; x2 = 0; y1 = 0; y2 = 0
        }
    }

    private var sections: [Biquad]
    private let gain: Float

    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate

        let w1 = 2 * Double.pi * AWeightingFilter.f1
        let w2 = 2 * Double.pi * AWeightingFilter.f2
        let w3 = 2 * Double.pi * AWeightingFilter.f3
        let w4 = 2 * Double.pi * AWeightingFilter.f4

        // Analog sections as (b2, b1, b0, a2, a1, a0).
        let analog: [(Double, Double, Double, Double, Double, Double)] = [
            (1, 0, 0, 1, 2 * w1, w1 * w1),          // s² / (s+ω₁)²
            (1, 0, 0, 1, w2 + w3, w2 * w3),          // s² / (s+ω₂)(s+ω₃)
            (0, 0, 1, 1, 2 * w4, w4 * w4)            // 1 / (s+ω₄)²
        ]

        let c = 2 * sampleRate
        let cc = c * c

        var built: [Biquad] = []
        var digital: [(Double, Double, Double, Double, Double)] = []

        for (b2, b1, b0, a2, a1, a0) in analog {
            let B0 = b2 * cc + b1 * c + b0
            let B1 = 2 * b0 - 2 * b2 * cc
            let B2 = b2 * cc - b1 * c + b0
            let A0 = a2 * cc + a1 * c + a0
            let A1 = 2 * a0 - 2 * a2 * cc
            let A2 = a2 * cc - a1 * c + a0

            digital.append((B0 / A0, B1 / A0, B2 / A0, A1 / A0, A2 / A0))
        }

        // Normalize to unity gain at 1 kHz.
        let reference = AWeightingFilter.cascadeMagnitude(digital,
                                                          frequency: 1000,
                                                          sampleRate: sampleRate)
        let normalization = reference > 0 ? 1.0 / reference : 1.0

        for (b0, b1, b2, a1, a2) in digital {
            built.append(Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2),
                                a1: Float(a1), a2: Float(a2)))
        }

        self.sections = built
        self.gain = Float(normalization)
    }

    /// Filter one sample. Cheap enough to run per-sample on the audio thread:
    /// three biquads is fifteen multiply-adds.
    mutating func process(_ sample: Float) -> Float {
        var value = sample
        for i in sections.indices {
            value = sections[i].process(value)
        }
        return value * gain
    }

    mutating func reset() {
        for i in sections.indices { sections[i].reset() }
    }

    // MARK: - Response (diagnostics and tests)

    /// Magnitude response of a coefficient cascade at a given frequency.
    private static func cascadeMagnitude(
        _ sections: [(Double, Double, Double, Double, Double)],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(-omega), sin1 = sin(-omega)
        let cos2 = cos(-2 * omega), sin2 = sin(-2 * omega)

        var magnitude = 1.0
        for (b0, b1, b2, a1, a2) in sections {
            let numRe = b0 + b1 * cos1 + b2 * cos2
            let numIm = b1 * sin1 + b2 * sin2
            let denRe = 1 + a1 * cos1 + a2 * cos2
            let denIm = a1 * sin1 + a2 * sin2

            let numMag = (numRe * numRe + numIm * numIm).squareRoot()
            let denMag = (denRe * denRe + denIm * denIm).squareRoot()
            magnitude *= denMag > 0 ? numMag / denMag : 0
        }
        return magnitude
    }
}
