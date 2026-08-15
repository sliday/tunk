import XCTest
@testable import TunkCore
import TunkFormat

/// `DSPTuning.decayPredictionMargin`: require a second onset to beat the
/// resonator's own analytically-known ring-down before it may extend a group.
///
/// The mechanism was built to attack lap false triggers and it does not work
/// there, for a reason that is arithmetic rather than empirical, and the last
/// test in this file is the one that says why. It is kept because the knob is
/// live and a future front end with a longer ring could reach a different
/// answer; the negative is pinned so nobody re-derives it by hand.
///
/// Measured on `data/raw` (TRAIN, in-sample) at the resonator operating point
/// — 40 Hz Q 2, threshold 0.011 g, minThreshold 0.002 g:
///
///     margin      lap detected   false triggers in 9.2 min
///     0 (off)      73/80  91.25 %   6
///     750          73/80  91.25 %   6
///     770-2000     73/80  91.25 %   5
///     2200         72/80  90.00 %   5
///     10000        69/80  86.25 %   4
///
/// The whole usable window removes one false trigger, and raising
/// `minInterTapNs` from 100 ms to 118 ms removes the same one at the same cost.
final class DecayPredictionTests: XCTestCase {

    // MARK: - Off by default

    func testMarginShipsOff() {
        XCTAssertEqual(DSPTuning.default.decayPredictionMargin, 0,
                       "the decay test ships OFF; every graded number assumes it")
    }

    func testOffLeavesTheResonatorChainExactlyWhereItWas() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        var reference = DSPTuning.default
        reference.resonatorHz = 40
        reference.minThresholdG = 0.002
        var gated = reference
        gated.decayPredictionMargin = 0

        let a = TapDetector.replay(samples: samples, inputs: [], tuning: reference)
        let b = TapDetector.replay(samples: samples, inputs: [], tuning: gated)
        XCTAssertEqual(a.triggers.count, 1)
        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.onsets, b.onsets)
    }

    /// The stage is absent without a resonator, so the margin must be inert
    /// there however large it is. Otherwise a sweep of this knob would silently
    /// grade a different mechanism on the shipped front end.
    func testMarginIsInertWithoutTheResonator() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        var huge = DSPTuning.default
        huge.decayPredictionMargin = 1_000_000
        XCTAssertNil(huge.resonatorDecayTauSeconds)

        let shipped = TapDetector.replay(samples: samples, inputs: [])
        let with = TapDetector.replay(samples: samples, inputs: [], tuning: huge)
        XCTAssertEqual(shipped.triggers.count, 1)
        XCTAssertEqual(shipped.triggers, with.triggers)
    }

    // MARK: - The constant it predicts with

    /// The prediction is only worth anything if `q / (pi * f0)` really is the
    /// decay of the filter that was built. Drive one impulse through and measure.
    func testDecayConstantMatchesTheFilterItDescribes() {
        var tuning = DSPTuning.default
        tuning.resonatorHz = 40
        tuning.resonatorQ = 2
        guard let tau = tuning.resonatorDecayTauSeconds else {
            return XCTFail("a 40 Hz stage must report a decay constant")
        }
        XCTAssertEqual(tau, 2.0 / (Double.pi * 40.0), accuracy: 1e-12)
        XCTAssertEqual(tau, 0.0159, accuracy: 0.0001)

        var res = Resonator(centreHz: 40, q: 2, sampleRateHz: tuning.sampleRateHz)
        let peak = res.process(1.0)
        let stepsPerTau = Int((tau * tuning.sampleRateHz).rounded())
        var value = peak
        for _ in 0..<stepsPerTau { value = res.process(0.0) }
        XCTAssertEqual(value / peak, exp(-1.0), accuracy: 0.01,
                       "one predicted time constant must be one measured time constant")

        // And four of them put it two orders of magnitude down, which is the
        // property the whole mechanism rests on.
        for _ in 0..<(3 * stepsPerTau) { value = res.process(0.0) }
        XCTAssertEqual(value / peak, exp(-4.0), accuracy: 0.005)
    }

    // MARK: - What it does when the prediction is reachable

    /// A SYNTHETIC pair 105 ms apart, the second a quarter the size of the first
    /// and landing just over the bar. That is the weakest second strike the
    /// detector can legally take at the earliest legal spacing, so it is the
    /// friendliest case the mechanism will ever see, and it still beats the
    /// prediction by ~150x. The margin has to be in the hundreds to reject it.
    ///
    /// Off, and at 10, the gesture fires. At 1000 the second onset fails the
    /// test, is published as suppressed, and nothing comes out.
    func testASecondOnsetThatDoesNotBeatThePredictionIsRejected() {
        let fixture = Self.weakSecondStrikeFixture()

        let open = TapDetector.replay(samples: fixture.samples, inputs: [],
                                      config: fixture.config, tuning: fixture.tuning)
        XCTAssertEqual(open.triggers.count, 1, "the fixture must fire with the test off")
        XCTAssertEqual(open.triggers.first?.tapOnsets.count, 2)

        var gatedTuning = fixture.tuning
        gatedTuning.decayPredictionMargin = 1000
        let gated = TapDetector.replay(samples: fixture.samples, inputs: [],
                                       config: fixture.config, tuning: gatedTuning)
        XCTAssertEqual(gated.triggers.count, 0,
                       "a second onset under the predicted ring must not complete a gesture")

        let survivors = gated.onsets.filter { !$0.suppressedByGate }
        XCTAssertEqual(survivors.count, 1, "only the first strike survives the test")
        XCTAssertEqual(gated.onsets.count, 2, "the rejected onset is still published")
    }

    /// The other half of the contract, and the shape of the whole result: a
    /// margin of 10 — well above the 2.5 the hysteresis alone guarantees — still
    /// rejects nothing, because the ring is 6.6 time constants down by the time
    /// the second onset is allowed to exist.
    func testASecondOnsetThatBeatsThePredictionIsKept() {
        let fixture = Self.weakSecondStrikeFixture()
        var tuning = fixture.tuning
        tuning.decayPredictionMargin = 10

        let kept = TapDetector.replay(samples: fixture.samples, inputs: [],
                                      config: fixture.config, tuning: tuning)
        XCTAssertEqual(kept.triggers.count, 1)
        XCTAssertEqual(kept.triggers.first?.tapOnsets.count, 2)
    }

    /// One SYNTHETIC 0.9 g strike and one 0.225 g strike 105 ms later, with the
    /// bar calibrated off the fixture's own first peak rather than a guessed
    /// constant — the resonator's gain through a synthetic strike is not a
    /// number a test should be asserting.
    private static func weakSecondStrikeFixture()
        -> (samples: [AccelSample], config: DetectorConfig, tuning: DSPTuning)
    {
        var tuning = DSPTuning.default
        tuning.resonatorHz = 40
        tuning.resonatorQ = 2
        tuning.minThresholdG = 0.0005

        let first = SyntheticStream.leadInNs
        let second = first + 105_000_000
        var stream = SyntheticStream(durationNs: second + 1_000_000_000,
                                     taps: [.init(tNs: first, amplitude: 0.9),
                                            .init(tNs: second, amplitude: 0.225)])
        stream.noiseAmplitude = 0.002
        let samples = stream.samples()

        var probe = SignalChain(tuning: tuning)
        var peak = 0.0
        for s in samples where s.tNs <= first + 20_000_000 {
            peak = max(peak, probe.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                           holdNoiseFloor: true))
        }
        var config = DetectorConfig.default
        config.calibratedThreshold = 0.2 * peak
        return (samples, config, tuning)
    }

    // MARK: - Why it cannot work at the shipped operating point

    /// The measured negative, as arithmetic.
    ///
    /// A second onset cannot arrive until `onsetDebounceNs` (100 ms) after the
    /// first, because the detector cannot re-arm before then. That is 6.3 time
    /// constants at 40 Hz Q 2, where the prediction has fallen to 0.19 % of the
    /// first strike. The strongest onset ever measured on lap in `data/raw` is
    /// 0.0238 g, so the largest prediction any legal second onset can face is
    /// 4.5e-5 g — against a threshold of 0.011 g that the onset had to clear to
    /// exist at all.
    ///
    /// So every true detection beats the prediction by at least ~240x for free,
    /// and rejecting anything at all needs a margin in the hundreds. At that
    /// point the test is no longer reading amplitude: `s2 < margin * s1 *
    /// exp(-dt/tau)` is `dt < tau * ln(margin * s1/s2)`, an inter-onset floor
    /// with an amplitude-ratio wobble on it. Measured, that is exactly how it
    /// behaves — see the sweep in this file's header.
    func testThePredictionCannotReachTheThresholdAtAnyLegalSecondOnset() {
        var tuning = DSPTuning.default
        tuning.resonatorHz = 40
        tuning.resonatorQ = 2
        tuning.minThresholdG = 0.002
        guard let tau = tuning.resonatorDecayTauSeconds else {
            return XCTFail("a 40 Hz stage must report a decay constant")
        }

        let earliestSecondOnset = Double(tuning.onsetDebounceNs) / 1e9
        let survivingFraction = exp(-earliestSecondOnset / tau)
        XCTAssertLessThan(survivingFraction, 0.002)

        let strongestLapOnsetG = 0.0238
        let threshold = 0.011
        let largestPrediction = strongestLapOnsetG * survivingFraction
        XCTAssertLessThan(largestPrediction, threshold / 100,
                          "if this ever fails the mechanism has headroom and is worth re-running")
    }

    /// The same objection with the resonator taken out of it, which is why this
    /// is not a tuning problem.
    ///
    /// The detector re-arms only once the envelope has fallen under
    /// `releaseFraction * T`, and the ring only falls further between re-arming
    /// and the next crossing, so the prediction facing any declared onset is at
    /// most `releaseFraction * T` while the onset itself is at least `T`. Every
    /// second onset that can exist therefore beats its own predicted ring by at
    /// least `1 / releaseFraction`, whatever the front end, whatever the tap
    /// spacing, whatever the amplitudes. A margin under 2.5 is a guaranteed
    /// no-op, and one over it is rejecting real strikes as well.
    func testHysteresisAloneGuaranteesEverySecondOnsetBeatsThePrediction() {
        let floor = 1.0 / DSPTuning.default.releaseFraction
        XCTAssertEqual(floor, 2.5, accuracy: 1e-12)

        let fixture = Self.weakSecondStrikeFixture()
        var tuning = fixture.tuning
        tuning.decayPredictionMargin = floor
        let atTheFloor = TapDetector.replay(samples: fixture.samples, inputs: [],
                                            config: fixture.config, tuning: tuning)
        XCTAssertEqual(atTheFloor.triggers.count, 1,
                       "nothing can be rejected at or under 1 / releaseFraction")
    }
}
