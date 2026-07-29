import Foundation

/// Turns octave-band levels into the single number the control loop steers on,
/// plus the two spectral descriptors the rest of the engine needs.
///
/// WHY NOT A-WEIGHTING
/// -------------------
/// A-weighting is a loudness/hearing-risk curve. It answers "how loud does this
/// seem", which is the right question for a sound level meter and the wrong one
/// for a volume controller. What ENVO actually needs to know is how much of the
/// user's audio is being *masked*, and masking differs from loudness in one
/// decisive way: low-frequency noise masks upward. A masker at 125 Hz raises
/// the audibility threshold at 500 Hz and 1 kHz substantially, which is why an
/// aircraft cabin or a bus makes speech unintelligible while a dB(A) meter
/// reports something unremarkable. A-weighting discards ~19 dB at 100 Hz and so
/// throws away most of the evidence in exactly those environments.
///
/// THE MODEL
/// ---------
/// Two standard pieces, both deliberately simple:
///
///  1. **Upward spread of masking.** The effective masking level in a band is
///     the greater of that band's own level and the spill from the band below,
///     attenuated by a fixed slope. 12 dB/octave is a conservative value from
///     the middle of the published range (roughly 10–25 dB/octave depending on
///     masker level); erring shallow means LF gets *less* credit, so the model
///     under-reacts rather than over-reacts.
///
///  2. **Band importance.** The spread-adjusted levels are combined with the
///     octave-band importance weights from ANSI S3.5 (the Speech Intelligibility
///     Index), which say where the information the listener cares about
///     actually lives. 125 Hz carries almost no speech information — but it
///     still enters the result, through the spread term in step 1, as a masker
///     of the bands that do.
///
/// The weights sum to 1 in the power domain, which gives the result a useful
/// property: a spectrally flat room at level L yields exactly L. The scale is
/// therefore directly comparable to a band level and 1:1 in dB, so every
/// difference the engine takes (room vs. baseline, floor vs. calibration) means
/// what it says.
///
/// ON MUSIC
/// --------
/// SII importance is defined for speech. Music spreads its information more
/// evenly, so for a listener playing music these weights slightly over-value
/// 1–4 kHz. That is a tolerable bias — it is the same band-importance shape any
/// broadband programme material would want, and the weights are exposed here as
/// a named constant precisely so they can be retuned against real listening.
enum MaskingWeighting {

    /// Octave-band importance, ANSI S3.5-1997 Table 3 values mapped onto the
    /// six bands the analyzer produces. 125 Hz is not in the standard set (it
    /// carries essentially no speech information); it gets a token weight so
    /// that a room which is *only* rumble still reads as something rather than
    /// as silence.
    static let bandImportance: [Float] = [0.010, 0.062, 0.167, 0.237, 0.265, 0.214]

    /// Upward spread of masking, in dB of attenuation per octave above a masker.
    static let upwardSpreadDBPerOctave: Float = 12.0

    // MARK: - Control level

    /// The masking-weighted level, in the same dBFS scale as the band levels.
    ///
    /// - Parameters:
    ///   - bandLevelsDB: one level per octave band, low to high.
    ///   - activeBandCount: bands below Nyquist. Weights are renormalised over
    ///     just these, so a reduced-bandwidth input route shifts the scale by a
    ///     constant rather than silently reading low.
    static func maskingLevelDB(_ bandLevelsDB: [Float], activeBandCount: Int) -> Float {
        let n = min(max(activeBandCount, 1),
                    min(bandLevelsDB.count, bandImportance.count))
        guard n > 0 else { return AcousticMath.silenceDB }

        // 1. Upward spread. Each band is masked at least as hard as the band
        //    below it, minus the slope. The recursion carries a strong low band
        //    all the way up, decaying an octave at a time.
        var spread = [Float](repeating: AcousticMath.silenceDB, count: n)
        for i in 0..<n {
            let own = bandLevelsDB[i].isFinite ? bandLevelsDB[i] : AcousticMath.silenceDB
            spread[i] = i == 0
                ? own
                : max(own, spread[i - 1] - upwardSpreadDBPerOctave)
        }

        // 2. Importance-weighted energetic sum, weights renormalised over the
        //    active bands so the "flat room at L reads L" property survives a
        //    truncated bandwidth.
        var weightSum: Float = 0
        for i in 0..<n { weightSum += bandImportance[i] }
        guard weightSum > 0 else { return AcousticMath.silenceDB }

        var power: Float = 0
        for i in 0..<n {
            power += (bandImportance[i] / weightSum) * AcousticMath.power(fromDB: spread[i])
        }
        return AcousticMath.dB(fromPower: power)
    }

    // MARK: - Spectral descriptors

    /// Fraction of total band energy sitting in 250 Hz – 2 kHz.
    ///
    /// This is the spectral half of the speech/steady-noise discriminator.
    /// Speech babble peaks around 500 Hz and keeps substantial energy through
    /// 2 kHz, so it lands near 0.5–0.6. Traffic, HVAC, engine and tyre noise are
    /// dominated by 125 Hz and below and land near 0.1–0.2. Unlike the seven
    /// 43 Hz-wide Goertzel probes this replaces, it is a genuine band ratio —
    /// nothing between the probe frequencies goes unseen, and there is no
    /// rectangular-window leakage smearing low-frequency energy into it.
    static func speechBandShare(_ bandLevelsDB: [Float], activeBandCount: Int) -> Float {
        let n = min(max(activeBandCount, 1), bandLevelsDB.count)
        var total: Float = 0
        var speech: Float = 0
        for i in 0..<n {
            let p = AcousticMath.power(fromDB: bandLevelsDB[i])
            total += p
            if i >= 1 && i <= 4 { speech += p }     // 250, 500, 1k, 2k
        }
        guard total > 0 else { return 0 }
        return AcousticMath.clamp(speech / total, 0, 1)
    }

    /// Fraction of total band energy above 1 kHz.
    ///
    /// Used only to spot an obstructed microphone. Cloth, a pocket, a table top
    /// or a hand act as a low-pass: the broadband level falls *and* the high
    /// bands collapse far faster than the low ones. A room that merely got
    /// quieter keeps its spectral shape, so the two cases separate cleanly on
    /// this ratio where they do not separate on level alone.
    static func highFrequencyShare(_ bandLevelsDB: [Float], activeBandCount: Int) -> Float {
        let n = min(max(activeBandCount, 1), bandLevelsDB.count)
        var total: Float = 0
        var high: Float = 0
        for i in 0..<n {
            let p = AcousticMath.power(fromDB: bandLevelsDB[i])
            total += p
            if i >= 4 { high += p }                 // 2k, 4k
        }
        guard total > 0 else { return 0 }
        return AcousticMath.clamp(high / total, 0, 1)
    }
}
