import XCTest
@testable import ENVO

/// The temporal half of the speech/steady-noise discriminator that replaced the
/// narrow-bin Goertzel "voice band share".
final class ModulationDetectorTests: XCTestCase {

    /// Buffer period at 1024 frames / 44.1 kHz — the rate the audio thread
    /// actually feeds this.
    private let dt: Float = 1024.0 / 44_100.0

    private func run(seconds: Float,
                     detector: inout ModulationDetector,
                     level: (Float) -> Float) {
        var t: Float = 0
        while t < seconds {
            detector.ingest(levelDB: level(t), dt: dt)
            t += dt
        }
    }

    /// A fan, an engine, a ventilation duct: constant level, no syllables.
    func testSteadyNoiseScoresZero() {
        var d = ModulationDetector()
        run(seconds: 10, detector: &d) { _ in -55 }
        XCTAssertLessThan(d.depthDB, 0.2)
        XCTAssertEqual(d.score, 0, accuracy: 0.001)
    }

    /// Speech modulates its own level at the syllable rate. ±5 dB at 4 Hz is a
    /// nearby talker measured through a short integration.
    func testSyllabicModulationScoresHigh() {
        var d = ModulationDetector()
        run(seconds: 10, detector: &d) { t in
            -55 + 5 * sinf(2 * .pi * 4 * t)
        }
        XCTAssertGreaterThan(d.score, 0.4,
                             "a 4 Hz envelope is the signature this exists to find")
    }

    /// Below the passband: a room slowly getting louder over half a minute is
    /// not speech and must not read as it.
    func testSlowDriftIsNotSpeech() {
        var d = ModulationDetector()
        run(seconds: 20, detector: &d) { t in
            -55 + 6 * sinf(2 * .pi * 0.05 * t)      // 20 s period
        }
        XCTAssertEqual(d.score, 0, accuracy: 0.001)
    }

    /// Above the passband: a difference of two one-poles is a gentle filter, so
    /// this is a preference rather than a rejection. That is the right shape —
    /// nothing meaningful lives above 10 Hz in a level envelope, so a mild
    /// slope there costs nothing, whereas the low side has to be decisive.
    func testSyllabicRateIsPreferredOverFasterFluctuation() {
        var syllabic = ModulationDetector()
        var fast = ModulationDetector()
        run(seconds: 15, detector: &syllabic) { t in -55 + 6 * sinf(2 * .pi * 4 * t) }
        run(seconds: 15, detector: &fast)     { t in -55 + 6 * sinf(2 * .pi * 15 * t) }

        XCTAssertGreaterThan(syllabic.depthDB, 1.3 * fast.depthDB)
        XCTAssertGreaterThan(syllabic.score, fast.score + 0.25)
    }

    /// The rejection that actually matters. A room drifting over a couple of
    /// seconds must not read as speech: a false positive here engages the
    /// Lombard damper and suppresses the very adaptation ENVO exists to do.
    func testSubSyllabicDriftIsStronglyRejected() {
        var d = ModulationDetector()
        run(seconds: 25, detector: &d) { t in -55 + 6 * sinf(2 * .pi * 0.5 * t) }
        XCTAssertEqual(d.score, 0, accuracy: 0.001)
    }

    /// Louder rooms must not look more speech-like than quiet ones. Modulation
    /// depth is a ratio, which is why the detector works in decibels.
    func testScoreIsIndependentOfAbsoluteLevel() {
        var quiet = ModulationDetector()
        var loud = ModulationDetector()
        run(seconds: 10, detector: &quiet) { t in -75 + 5 * sinf(2 * .pi * 4 * t) }
        run(seconds: 10, detector: &loud)  { t in -35 + 5 * sinf(2 * .pi * 4 * t) }
        XCTAssertEqual(quiet.score, loud.score, accuracy: 0.02)
    }

    /// Someone stops talking; the score must come back down rather than latch.
    func testScoreDecaysWhenSpeechStops() {
        var d = ModulationDetector()
        run(seconds: 10, detector: &d) { t in -55 + 5 * sinf(2 * .pi * 4 * t) }
        let talking = d.score
        run(seconds: 15, detector: &d) { _ in -55 }
        XCTAssertGreaterThan(talking, 0.4)
        XCTAssertLessThan(d.score, 0.1)
    }

    func testHostileInputsAreIgnored() {
        var d = ModulationDetector()
        run(seconds: 5, detector: &d) { t in -55 + 5 * sinf(2 * .pi * 4 * t) }
        let before = d.depthDB
        d.ingest(levelDB: .nan, dt: dt)
        d.ingest(levelDB: .infinity, dt: dt)
        d.ingest(levelDB: -55, dt: 0)
        d.ingest(levelDB: -55, dt: -1)
        XCTAssertEqual(d.depthDB, before, accuracy: 0.0001)
        XCTAssertTrue(d.score.isFinite)
    }

    func testResetClearsState() {
        var d = ModulationDetector()
        run(seconds: 10, detector: &d) { t in -55 + 5 * sinf(2 * .pi * 4 * t) }
        d.reset()
        XCTAssertEqual(d.depthDB, 0, accuracy: 0.0001)
        XCTAssertEqual(d.score, 0, accuracy: 0.0001)
    }
}
