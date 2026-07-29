import Foundation

/// Measures how strongly a level envelope fluctuates at syllabic rates —
/// the temporal half of ENVO's speech/steady-noise discriminator.
///
/// WHY TEMPORAL AND NOT ONLY SPECTRAL
/// ----------------------------------
/// The previous detector asked a purely spectral question: how much energy sits
/// near a few voice frequencies. Music answers that question the same way speech
/// does, and so does any broadband noise in a room with little low-frequency
/// content. The property that actually separates a person talking from a fan,
/// an engine or a ventilation duct is *temporal*: speech modulates its own
/// level at the syllable rate, 3–5 Hz, by several decibels. Steady mechanical
/// noise does not modulate at all.
///
/// This is the standard modulation-domain approach used in voice activity
/// detection, and it is cheap: bandpass the decibel envelope between 2 and 8 Hz
/// with two one-pole filters and take its RMS.
///
/// KNOWN LIMIT
/// -----------
/// Many-talker babble tends toward steady noise — the more people are talking,
/// the more their syllables average out, and modulation depth falls. So this
/// detector is strongest in a café or an open-plan office with a handful of
/// nearby voices and weakest in a packed restaurant. That is precisely why the
/// engine *averages* this score with `MaskingWeighting.speechBandShare` rather
/// than gating on it: the spectral term stays valid however many talkers there
/// are, and the temporal term rejects the steady-noise false positives the
/// spectral term alone would produce.
///
/// The failure direction is safe either way. This score only ever feeds
/// `LombardDamper`, which can only reduce how much ENVO adjusts.
struct ModulationDetector: Equatable {

    /// Envelope passband, bracketing the 3–5 Hz syllabic rate with margin for
    /// slow and fast speakers.
    ///
    /// A difference of two one-poles, which is a gentle filter rather than a
    /// sharp one — worth being precise about, because the two skirts do very
    /// different amounts of work. Measured at the buffer rate, a 6 dB envelope
    /// gives 2.5 dB RMS at 4 Hz, 0.74 dB at 0.5 Hz, 0.09 dB at 0.05 Hz, and
    /// still 1.7 dB at 15 Hz.
    ///
    /// So the low side is decisive and the high side is mild, which is the right
    /// way round. Slow drift is the dangerous false positive: a room changing
    /// over tens of seconds reading as "speech" would engage the damper and
    /// suppress exactly the adaptation ENVO exists to perform, and at 0.05 Hz
    /// this rejects it by 28 dB. Fast fluctuation is not dangerous, because
    /// nothing meaningful lives above 10 Hz in a level envelope — what is there
    /// is the statistical scatter of a short-window level estimate, which is
    /// what `floorDB` is set above.
    ///
    /// Second-order sections were measured and rejected: they sharpen the high
    /// side (15 Hz drops to 1.3 dB) at the cost of doubling the response to slow
    /// drift, which trades a harmless weakness for a harmful one.
    private static let lowCutoffHz: Float = 2.0
    private static let highCutoffHz: Float = 8.0

    /// Averaging time for the RMS. Long enough to span several syllables,
    /// short enough to follow someone starting or stopping talking.
    private static let rmsTimeConstant: Float = 2.0

    /// Modulation depth, in dB RMS, below which nothing counts as speech-like.
    ///
    /// Calibrated against what actually arrives here rather than against the
    /// modulation present in the room. Two attenuations sit in between:
    /// estimating a level from a ~21 ms buffer leaves roughly half a decibel of
    /// statistical scatter on a perfectly steady signal, and the 2–8 Hz
    /// bandpass passes about 0.6 of a 4 Hz component (the two one-poles partly
    /// cancel at the passband centre). So a room modulating ±5 dB at the
    /// syllabic rate presents about 2 dB RMS here, and steady mechanical noise
    /// presents a few tenths. This floor sits between the two.
    var floorDB: Float

    /// Depth at which the score reaches 1, on the same measured-here scale.
    var fullScaleDB: Float

    private var lowpassSlow: Float = 0
    private var lowpassFast: Float = 0
    private var meanSquare: Float = 0
    private var seeded = false

    init(floorDB: Float = 0.8, fullScaleDB: Float = 3.0) {
        self.floorDB = max(0, floorDB)
        self.fullScaleDB = max(self.floorDB + 0.1, fullScaleDB)
    }

    /// Current modulation depth in dB RMS.
    private(set) var depthDB: Float = 0

    /// Current depth mapped to 0…1.
    var score: Float {
        AcousticMath.clamp((depthDB - floorDB) / (fullScaleDB - floorDB), 0, 1)
    }

    /// Feed one level reading.
    ///
    /// - Parameters:
    ///   - levelDB: the level envelope, in decibels. Decibels rather than
    ///     amplitude on purpose — modulation *depth* is a ratio, and a ratio in
    ///     the linear domain is a difference in the log domain, so working in dB
    ///     makes the measurement independent of how loud the room happens to be.
    ///   - dt: seconds since the previous reading.
    mutating func ingest(levelDB: Float, dt: Float) {
        guard levelDB.isFinite, dt > 0, dt < 1.0 else { return }

        if !seeded {
            lowpassSlow = levelDB
            lowpassFast = levelDB
            seeded = true
            return
        }

        let slowAlpha = ModulationDetector.alpha(cutoffHz: ModulationDetector.lowCutoffHz, dt: dt)
        let fastAlpha = ModulationDetector.alpha(cutoffHz: ModulationDetector.highCutoffHz, dt: dt)

        lowpassSlow = slowAlpha * lowpassSlow + (1 - slowAlpha) * levelDB
        lowpassFast = fastAlpha * lowpassFast + (1 - fastAlpha) * levelDB

        // Bandpass: everything the fast filter still passes, minus everything
        // the slow one has already smoothed away.
        let bandpassed = lowpassFast - lowpassSlow

        let rmsAlpha = expf(-dt / ModulationDetector.rmsTimeConstant)
        meanSquare = rmsAlpha * meanSquare + (1 - rmsAlpha) * bandpassed * bandpassed
        depthDB = meanSquare > 0 ? meanSquare.squareRoot() : 0
    }

    mutating func reset() {
        lowpassSlow = 0
        lowpassFast = 0
        meanSquare = 0
        depthDB = 0
        seeded = false
    }

    private static func alpha(cutoffHz: Float, dt: Float) -> Float {
        let tau = 1.0 / (2.0 * Float.pi * cutoffHz)
        return expf(-dt / tau)
    }
}
