import XCTest
@testable import ENVO

/// The weighting that replaced broadband A-weighting as the control signal.
final class MaskingWeightingTests: XCTestCase {

    private let allBands = OctaveBandAnalyzer.centerFrequencies.count

    private func flat(_ level: Float) -> [Float] {
        [Float](repeating: level, count: allBands)
    }

    // MARK: - Scale

    /// The property that makes the result readable as a level at all: importance
    /// weights sum to one in the power domain, so a spectrally flat room at L
    /// reads exactly L. Without this the number would be on some arbitrary
    /// scale and no difference taken against it would mean decibels.
    func testFlatSpectrumReadsItsOwnLevel() {
        for level in [Float(-80), -60, -40, -20] {
            XCTAssertEqual(MaskingWeighting.maskingLevelDB(flat(level),
                                                           activeBandCount: allBands),
                           level, accuracy: 0.01)
        }
    }

    /// 1:1 in dB. Every difference the engine takes depends on this.
    func testScaleIsOneToOne() {
        let quiet = MaskingWeighting.maskingLevelDB(flat(-70), activeBandCount: allBands)
        let loud  = MaskingWeighting.maskingLevelDB(flat(-55), activeBandCount: allBands)
        XCTAssertEqual(loud - quiet, 15, accuracy: 0.01)
    }

    /// A route with a reduced bandwidth renormalises rather than reading low.
    func testTruncatedBandwidthStillReadsTheLevel() {
        XCTAssertEqual(MaskingWeighting.maskingLevelDB(flat(-60), activeBandCount: 4),
                       -60, accuracy: 0.01)
    }

    // MARK: - Upward spread of masking

    /// The whole reason this replaced A-weighting.
    ///
    /// A bus, a train and an aircraft cabin are low-frequency drones. They bury
    /// speech and music through upward spread of masking while barely moving a
    /// dB(A) meter — and the 125 Hz band carries essentially no *signal*
    /// importance (0.010 of 0.955), so an importance weighting alone would
    /// ignore them almost completely too. The spread term is what makes them
    /// register.
    func testLowFrequencyRumbleRaisesTheMaskingLevel() {
        var rumble = flat(-60)
        rumble[0] = -30                                  // 30 dB of 125 Hz drone

        let quiet = MaskingWeighting.maskingLevelDB(flat(-60), activeBandCount: allBands)
        let droning = MaskingWeighting.maskingLevelDB(rumble, activeBandCount: allBands)

        XCTAssertGreaterThan(droning - quiet, 8.0,
                             "a low-frequency drone must register as masking")
    }

    /// …but it must not register as though it were midrange noise, or ENVO
    /// would over-compensate for rumble it can partly ignore.
    func testRumbleCountsForLessThanTheSameEnergyInTheMidrange() {
        var rumble = flat(-60); rumble[0] = -30
        var midrange = flat(-60); midrange[3] = -30      // 1 kHz

        XCTAssertLessThan(MaskingWeighting.maskingLevelDB(rumble, activeBandCount: allBands),
                          MaskingWeighting.maskingLevelDB(midrange, activeBandCount: allBands))
    }

    /// Masking spreads up, never down. Energy in the top band must be credited
    /// with its own importance weight and nothing more — it cannot be treated as
    /// burying the midrange below it.
    ///
    /// Pinned to the exact no-spread value: if downward spread ever crept in,
    /// the lower bands would be lifted and the result would come out higher.
    func testHighFrequencyEnergyDoesNotSpreadDownward() {
        var hiss = flat(-60)
        hiss[5] = -30                                    // 4 kHz only

        let weights = MaskingWeighting.bandImportance
        let total = weights.reduce(0, +)
        var expectedPower: Float = 0
        for (i, w) in weights.enumerated() {
            expectedPower += (w / total) * AcousticMath.power(fromDB: hiss[i])
        }

        XCTAssertEqual(MaskingWeighting.maskingLevelDB(hiss, activeBandCount: allBands),
                       AcousticMath.dB(fromPower: expectedPower),
                       accuracy: 0.01,
                       "the top band must contribute only its own weight")
    }

    /// The corollary, stated so the asymmetry is not mistaken for a bug: the
    /// same energy placed high counts for *more* than placed low, because 4 kHz
    /// carries real speech importance and 125 Hz carries almost none. The spread
    /// term gives low frequencies a voice, not a veto.
    func testTheSameEnergyCountsForMoreWhereTheInformationIs() {
        var hiss = flat(-60);   hiss[5] = -30
        var rumble = flat(-60); rumble[0] = -30

        XCTAssertGreaterThan(MaskingWeighting.maskingLevelDB(hiss, activeBandCount: allBands),
                             MaskingWeighting.maskingLevelDB(rumble, activeBandCount: allBands))
    }

    func testNonFiniteBandsDoNotProduceNonFiniteOutput() {
        var bands = flat(-60)
        bands[2] = .nan
        bands[4] = .infinity
        XCTAssertTrue(MaskingWeighting.maskingLevelDB(bands, activeBandCount: allBands).isFinite)
    }

    // MARK: - Spectral descriptors

    /// Speech babble peaks near 500 Hz; traffic and ventilation are dominated by
    /// 125 Hz and below. This is the separation the Lombard damper depends on,
    /// and the one the old narrow-bin Goertzel ratio could not make reliably.
    func testSpeechShareSeparatesBabbleFromTraffic() {
        let babble: [Float]  = [-58, -46, -42, -44, -48, -58]
        let traffic: [Float] = [-32, -42, -52, -60, -66, -72]

        let babbleShare  = MaskingWeighting.speechBandShare(babble, activeBandCount: allBands)
        let trafficShare = MaskingWeighting.speechBandShare(traffic, activeBandCount: allBands)

        XCTAssertGreaterThan(babbleShare, 0.55)
        XCTAssertLessThan(trafficShare, 0.35)
        XCTAssertGreaterThan(babbleShare - trafficShare, 0.3,
                             "the two must be separable by a ramp, not just ordered")
    }

    /// Real octave-band levels from an iPhone 14 measuring broadband pink noise
    /// through its own microphone, at five different room levels
    /// (`envo-diag-20260730-131523.csv`).
    ///
    /// These exist because a guess got this wrong. The speech ramp was originally
    /// calibrated on invented spectra with 30 dB tilts across octaves, which no
    /// real room produces — and on real hardware plain pink noise scored 1.00 on
    /// the spectral term, putting `speechLikeness` just past the Lombard damper's
    /// engage threshold. ENVO was damping its response to ordinary noise.
    static let measuredPinkNoiseBands: [[Float]] = [
        [-37.5, -42.6, -42.6, -40.5, -46.3, -51.2],
        [-30.7, -35.4, -35.5, -33.5, -39.4, -44.4],
        [-22.9, -27.6, -27.3, -25.1, -31.0, -36.0],
        [-29.9, -33.8, -33.7, -31.8, -37.5, -42.6],
        [-38.3, -42.7, -42.5, -40.4, -46.3, -51.3],
    ]

    /// The share of a broadband signal has a floor well above zero, because four
    /// of the six bands are in the numerator. Any ramp has to start above it.
    func testBroadbandNoiseShareSitsWellAboveZero() {
        for bands in Self.measuredPinkNoiseBands {
            let share = MaskingWeighting.speechBandShare(bands, activeBandCount: allBands)
            XCTAssertGreaterThan(share, 0.50,
                                 "broadband noise cannot read as low as LF-dominated noise")
            XCTAssertLessThan(share, 0.65,
                              "…but it must stay below where speech babble sits")
        }
    }

    /// The regression that matters: measured broadband noise must be separable
    /// from speech by a ramp, at every level it was recorded at.
    func testMeasuredNoiseIsSeparableFromSpeechShapedNoise() {
        let babble: [Float] = [-40, -36, -33, -35, -40, -48]   // speech-shaped
        let babbleShare = MaskingWeighting.speechBandShare(babble, activeBandCount: allBands)

        for bands in Self.measuredPinkNoiseBands {
            let pinkShare = MaskingWeighting.speechBandShare(bands, activeBandCount: allBands)
            XCTAssertGreaterThan(babbleShare - pinkShare, 0.15,
                                 "the gap must be wide enough for a ramp to sit in")
        }
    }

    /// Anything covering a microphone is a low-pass. This ratio is what lets
    /// `ObstructionDetector` tell a pocket from a room that went quiet.
    func testHighFrequencyShareCollapsesWhenMuffled() {
        let open: [Float]    = [-55, -52, -50, -50, -52, -55]
        let muffled: [Float] = [-60, -60, -64, -72, -82, -92]

        XCTAssertGreaterThan(
            MaskingWeighting.highFrequencyShare(open, activeBandCount: allBands),
            2.0 * MaskingWeighting.highFrequencyShare(muffled, activeBandCount: allBands)
        )
    }

    /// A room that merely got quieter keeps its shape — which is exactly why
    /// obstruction detection requires the spectral condition as well as a drop.
    func testHighFrequencyShareIsUnchangedByAUniformlyQuieterRoom() {
        let loud: [Float]  = [-45, -42, -40, -40, -42, -45]
        let quiet = loud.map { $0 - 15 }

        XCTAssertEqual(
            MaskingWeighting.highFrequencyShare(loud, activeBandCount: allBands),
            MaskingWeighting.highFrequencyShare(quiet, activeBandCount: allBands),
            accuracy: 0.001
        )
    }
}

// MARK: - Filterbank

final class OctaveBandAnalyzerTests: XCTestCase {

    private func level(of frequency: Float,
                       amplitude: Float = 0.5,
                       sampleRate: Double = 48_000,
                       seconds: Double = 0.5) -> [Float] {
        var analyzer = OctaveBandAnalyzer(sampleRate: sampleRate)
        let frameSize = 1024
        let frames = Int(sampleRate * seconds) / frameSize
        var phase: Float = 0
        let increment = 2 * Float.pi * frequency / Float(sampleRate)
        var buffer = [Float](repeating: 0, count: frameSize)

        for _ in 0..<frames {
            for i in 0..<frameSize {
                buffer[i] = amplitude * sinf(phase)
                phase += increment
                if phase > 2 * Float.pi { phase -= 2 * Float.pi }
            }
            buffer.withUnsafeBufferPointer { p in
                analyzer.analyze(p.baseAddress!, count: frameSize)
            }
        }
        return analyzer.bandLevelsDB
    }

    /// Each band must actually be centred where it claims to be.
    func testEachToneLandsInItsOwnBand() {
        for (index, frequency) in OctaveBandAnalyzer.centerFrequencies.enumerated() {
            let bands = level(of: frequency)
            let loudest = bands.enumerated().max(by: { $0.element < $1.element })!.offset
            XCTAssertEqual(loudest, index,
                           "a \(frequency) Hz tone should be loudest in band \(index)")
        }
    }

    /// Two cascaded sections give 12 dB/octave skirts, which is what keeps the
    /// filterbank's own leakage from dominating the 12 dB/octave masking spread
    /// it feeds.
    func testAdjacentBandRejectionIsAtLeastTwelveDB() {
        let bands = level(of: 1000)
        XCTAssertGreaterThan(bands[3] - bands[2], 12.0)
        XCTAssertGreaterThan(bands[3] - bands[4], 12.0)
    }

    /// A tone at the same amplitude must read the same level wherever it sits,
    /// or the weighted sum would be measuring the filterbank rather than the
    /// room.
    func testBandsAreGainMatched() {
        let levels = OctaveBandAnalyzer.centerFrequencies.enumerated().map { index, f in
            level(of: f)[index]
        }
        XCTAssertLessThan(levels.max()! - levels.min()!, 1.5)
    }

    /// A bandpass sitting on Nyquist returns noise, not a measurement.
    func testBandsAboveNyquistAreExcluded() {
        let analyzer = OctaveBandAnalyzer(sampleRate: 8_000)
        XCTAssertLessThan(analyzer.activeBandCount,
                          OctaveBandAnalyzer.centerFrequencies.count)
        XCTAssertEqual(OctaveBandAnalyzer(sampleRate: 48_000).activeBandCount,
                       OctaveBandAnalyzer.centerFrequencies.count)
    }

    func testSilenceReadsAsSilence() {
        var analyzer = OctaveBandAnalyzer(sampleRate: 48_000)
        let silence = [Float](repeating: 0, count: 1024)
        silence.withUnsafeBufferPointer { p in
            analyzer.analyze(p.baseAddress!, count: 1024)
        }
        for level in analyzer.bandLevelsDB {
            XCTAssertEqual(level, AcousticMath.silenceDB, accuracy: 0.001)
        }
    }
}
