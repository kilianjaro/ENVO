import Foundation

/// Six-band octave filterbank, 125 Hz … 4 kHz.
///
/// WHY A FILTERBANK AND NOT JUST A WEIGHTING CURVE
/// -----------------------------------------------
/// A single broadband number — A-weighted or otherwise — answers "how loud is
/// this room". That is not the question the control loop asks. The loop asks
/// "how much of my audio is being buried", and masking is a *spectral*
/// phenomenon that no fixed linear filter can express:
///
///   * Masking is band-by-band. Noise at 4 kHz does nothing to a 250 Hz cue.
///   * Low-frequency noise masks *upward* into the midrange far more than
///     A-weighting's −19 dB at 100 Hz would suggest. An aircraft cabin is a
///     70–90 Hz drone that destroys speech intelligibility while reading
///     modestly on a dB(A) meter — which is exactly the case the previous
///     broadband A-weighted design under-read.
///
/// Band levels are the standard instrument for this (IEC 61260), and once you
/// have them the upward-spread model and the speech/steady-noise discriminator
/// both fall out of the same measurement. See `MaskingWeighting`.
///
/// IMPLEMENTATION
/// --------------
/// One RBJ constant-peak-gain bandpass per band at Q = √2 (the octave value:
/// edges at f₀/√2 and f₀·√2), cascaded twice. Cascading doubles the skirt slope
/// to 12 dB/octave, which matters because the upward-spread model below smears
/// at 12 dB/octave — with single 6 dB/octave sections the filter's own leakage
/// would dominate the model it feeds.
///
/// The cascade also narrows the −3 dB bandwidth to roughly 0.64 octave, so
/// broadband noise reads a few dB low. It reads low by the *same* amount in
/// every band, so the weighted sum carries a constant offset that is absorbed
/// into `AudioManager.fullScaleSPL` and cancels out of every difference the
/// engine actually uses.
///
/// Cost is 12 biquads per sample — about 60 multiply-adds, or well under 1% of
/// one core at 48 kHz. Audio-thread only; allocates nothing after `init`.
struct OctaveBandAnalyzer {

    static let centerFrequencies: [Float] = [125, 250, 500, 1000, 2000, 4000]

    /// Sections per band. Two identical bandpasses in series.
    private static let sectionsPerBand = 2

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
    }

    let sampleRate: Double

    /// Bands whose centre sits safely below Nyquist. At a 16 kHz input rate the
    /// 4 kHz band is still fine; at 8 kHz it is not, and a bandpass sitting on
    /// Nyquist returns noise rather than a measurement. Inactive bands are
    /// excluded from the weighting and the weights renormalised, rather than
    /// contributing garbage.
    let activeBandCount: Int

    private var sections: [Biquad]

    /// Preallocated output. Written in place by `analyze`, never reallocated.
    private(set) var bandLevelsDB: [Float]

    /// Scratch for per-band power accumulation. Preallocated for the same reason.
    private var bandPower: [Float]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate

        let usableLimit = Float(sampleRate) * 0.45
        var active = 0
        for f in OctaveBandAnalyzer.centerFrequencies where f < usableLimit {
            active += 1
        }
        self.activeBandCount = max(1, active)

        var built: [Biquad] = []
        built.reserveCapacity(OctaveBandAnalyzer.centerFrequencies.count
                              * OctaveBandAnalyzer.sectionsPerBand)

        // Q for a one-octave band: BW = f₀(√2 − 1/√2) = 0.7071·f₀, Q = f₀/BW.
        let q = Double(2.0).squareRoot()

        for f in OctaveBandAnalyzer.centerFrequencies {
            let w0 = 2 * Double.pi * Double(f) / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha

            // RBJ bandpass, constant 0 dB peak gain.
            let biquad = Biquad(
                b0: Float(alpha / a0),
                b1: 0,
                b2: Float(-alpha / a0),
                a1: Float(-2 * cos(w0) / a0),
                a2: Float((1 - alpha) / a0)
            )
            for _ in 0..<OctaveBandAnalyzer.sectionsPerBand {
                built.append(biquad)
            }
        }

        self.sections = built
        self.bandLevelsDB = [Float](repeating: AcousticMath.silenceDB,
                                    count: OctaveBandAnalyzer.centerFrequencies.count)
        self.bandPower = [Float](repeating: 0,
                                 count: OctaveBandAnalyzer.centerFrequencies.count)
    }

    /// Filter one buffer and update `bandLevelsDB` with each band's RMS level
    /// in dBFS. Inactive bands are set to `silenceDB`.
    mutating func analyze(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        let bandCount = OctaveBandAnalyzer.centerFrequencies.count
        let perBand = OctaveBandAnalyzer.sectionsPerBand

        for b in 0..<bandCount { bandPower[b] = 0 }

        for i in 0..<count {
            let input = samples[i]
            for b in 0..<activeBandCount {
                var v = input
                let base = b * perBand
                for s in 0..<perBand {
                    v = sections[base + s].process(v)
                }
                bandPower[b] += v * v
            }
        }

        let n = Float(count)
        for b in 0..<bandCount {
            if b < activeBandCount {
                let meanSquare = bandPower[b] / n
                bandLevelsDB[b] = meanSquare > 0
                    ? max(10.0 * log10f(meanSquare), AcousticMath.silenceDB)
                    : AcousticMath.silenceDB
            } else {
                bandLevelsDB[b] = AcousticMath.silenceDB
            }
        }
    }

    mutating func reset() {
        for i in sections.indices {
            sections[i].x1 = 0; sections[i].x2 = 0
            sections[i].y1 = 0; sections[i].y2 = 0
        }
        for i in bandLevelsDB.indices { bandLevelsDB[i] = AcousticMath.silenceDB }
        for i in bandPower.indices { bandPower[i] = 0 }
    }
}
