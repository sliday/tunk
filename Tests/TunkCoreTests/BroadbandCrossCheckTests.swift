import XCTest
@testable import TunkCore

/// The broadband cross-check (`DSPTuning.crossCheckSupportG` and
/// `crossCheckSupportRatio`): run the shipped broadband chain alongside the
/// resonator chain, let the resonator declare the onsets, and admit an onset
/// only if the broadband chain saw something at the same instant.
///
/// The premise is that a knuckle strike is broadband and shows in both paths,
/// while a narrow ring at the resonator's own centre frequency shows only in the
/// resonator. These tests prove the machinery does that. What it BUYS on
/// recorded data is a separate question and the answer measured on `data/raw`
/// was "nothing" — see the commit message.
///
/// The trap this file is written against: the two paths have different gains. A
/// broadband impulse reaches the envelope at ~0.68x its amplitude through the
/// shipped chain and ~0.079x through the 40 Hz Q 2 resonator, so a support
/// threshold in broadband g is roughly 8.6x the number that means the same thing
/// in resonator g. Every threshold below is derived from a MEASURED peak rather
/// than written down, which is what `SyntheticStream.chainGain(tuning:)` exists
/// for. Nothing here is recorded data.
final class BroadbandCrossCheckTests: XCTestCase {

    /// The resonator operating point the lap work is graded at.
    private var resonatorTuning: DSPTuning {
        var t = DSPTuning.default
        t.resonatorHz = 40
        t.resonatorQ = 2
        t.minThresholdG = 0.002
        return t
    }

    private var resonatorConfig: DetectorConfig {
        var c = DetectorConfig.default
        c.defaultThreshold = 0.011
        c.calibratedThreshold = 0.011
        return c
    }

    // MARK: - Absent unless asked for

    func testShippedTuningHasNoCrossCheck() {
        XCTAssertEqual(DSPTuning.default.crossCheckSupportG, 0,
                       "the cross-check ships OFF; every graded number assumes it")
        XCTAssertEqual(DSPTuning.default.crossCheckSupportRatio, 0)
    }

    /// With no resonator the broadband path IS the main path, so the second
    /// envelope must be the same number and the ratio identically 1. A ratio
    /// check on the shipped front end therefore cannot bite below 1 and deafens
    /// above it, which is stated in the field's own documentation.
    func testBroadbandEnvelopeAliasesTheEnvelopeWithNoResonator() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        var chain = SignalChain(tuning: .default)
        var sawSignal = false
        for s in stream.samples() {
            chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z), holdNoiseFloor: false)
            XCTAssertEqual(chain.broadbandEnvelope, chain.envelope, accuracy: 0)
            XCTAssertEqual(chain.broadbandSupport, chain.envelope, accuracy: 0)
            if chain.envelope > 0.02 { sawSignal = true }
        }
        XCTAssertTrue(sawSignal, "fixture produced no tap-sized envelope; the check proved nothing")
    }

    /// The fork has to be the shipped chain, not an approximation of it: same
    /// high pass, same quadrature pair, same peak hold, tapped before the narrow
    /// band. Sample for sample, exactly.
    func testBroadbandPathReproducesTheShippedChainWithTheResonatorIn() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        var shipped = SignalChain(tuning: .default)
        var dual = SignalChain(tuning: resonatorTuning)

        for s in stream.samples() {
            let expected = shipped.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                           holdNoiseFloor: false)
            dual.process(x: Double(s.x), y: Double(s.y), z: Double(s.z), holdNoiseFloor: false)
            XCTAssertEqual(dual.broadbandEnvelope, expected, accuracy: 0,
                           "the cross-check must read the shipped broadband envelope")
        }
    }

    // MARK: - Control: it still detects a real double tap

    /// The control the whole mechanism has to pass before any number it produces
    /// is worth reading. A support threshold under the broadband peak of a real
    /// strike changes nothing: the gesture still fires.
    func testRealDoubleTapStillFiresUnderASupportThresholdBelowIt() {
        let broadbandPeak = measuredBroadbandPeak(ofRealStrike: true)
        var tuning = resonatorTuning
        tuning.crossCheckSupportG = broadbandPeak * 0.5

        XCTAssertEqual(triggerCount(tuning: tuning, narrowband: false), 1,
                       "a real double tap must survive a support threshold at half its own broadband peak")
        XCTAssertEqual(triggerCount(tuning: resonatorTuning, narrowband: false), 1,
                       "control: the same gesture fires with the cross-check off")
    }

    /// And the opposite end, so a "0 false triggers" result can never be an inert
    /// gate quietly doing nothing: a support threshold above every broadband peak
    /// in the stream silences the detector completely.
    func testSupportThresholdAboveEveryPeakSilencesTheDetector() {
        let broadbandPeak = measuredBroadbandPeak(ofRealStrike: true)
        var tuning = resonatorTuning
        tuning.crossCheckSupportG = broadbandPeak * 2.0

        XCTAssertEqual(triggerCount(tuning: tuning, narrowband: false), 0,
                       "the gate must be live; if this fires, every FP number above is meaningless")
    }

    // MARK: - The mechanism's own claim

    /// A ring at the resonator's centre frequency reaches the resonator's output
    /// almost intact (peak gain 1 at f0) while a broadband strike loses ~8.6x
    /// through the same band. So a narrowband stimulus that clears the onset
    /// threshold carries far less broadband energy than a real strike that
    /// clears the same threshold, and a support threshold placed between the two
    /// rejects one and keeps the other.
    func testNarrowbandRingIsRejectedWhereARealStrikeIsAdmitted() {
        let realBroadband = measuredBroadbandPeak(ofRealStrike: true)
        let ringBroadband = measuredBroadbandPeak(ofRealStrike: false)

        XCTAssertLessThan(ringBroadband, realBroadband,
                          "fixture is wrong: the 40 Hz ring must be the broadband-poorer of the two")
        // Both must actually reach the detector, or the comparison is vacuous.
        XCTAssertEqual(triggerCount(tuning: resonatorTuning, narrowband: true), 1,
                       "with the check off the resonator fires on the narrowband ring; that is the premise")
        XCTAssertEqual(triggerCount(tuning: resonatorTuning, narrowband: false), 1)

        var tuning = resonatorTuning
        tuning.crossCheckSupportG = (ringBroadband + realBroadband) / 2

        XCTAssertEqual(triggerCount(tuning: tuning, narrowband: true), 0,
                       "the narrowband ring has no broadband support and must be rejected")
        XCTAssertEqual(triggerCount(tuning: tuning, narrowband: false), 1,
                       "the real strike does, and must survive")
    }

    /// Same separation through the relative form, which needs no gain scaling
    /// because it is a ratio.
    func testRatioFormSeparatesTheSameTwoStimuli() {
        // At f0 the resonator's peak gain is 1 and the broadband chain's is 0.68,
        // so a pure 40 Hz ring keeps a low broadband-to-resonator ratio while a
        // broadband strike sits far above it. Both ratios are measured at the
        // crossing, where the detector reads them.
        let ringRatio = measuredCrossingRatio(narrowband: true)
        let realRatio = measuredCrossingRatio(narrowband: false)
        XCTAssertLessThan(ringRatio, realRatio,
                          "fixture is wrong: the 40 Hz ring must be the broadband-poorer of the two")

        var tuning = resonatorTuning
        tuning.crossCheckSupportRatio = (ringRatio + realRatio) / 2

        XCTAssertEqual(triggerCount(tuning: tuning, narrowband: true), 0)
        XCTAssertEqual(triggerCount(tuning: tuning, narrowband: false), 1)
    }

    /// An unsupported onset is still published, so the tap monitor can show the
    /// user a knock the sensor saw and the detector declined to act on. Silence
    /// there is what makes a detector feel broken.
    func testRejectedOnsetIsPublishedAsSuppressed() {
        var tuning = resonatorTuning
        tuning.crossCheckSupportRatio = (measuredCrossingRatio(narrowband: true)
                                         + measuredCrossingRatio(narrowband: false)) / 2
        let detector = TapDetector(config: resonatorConfig, tuning: tuning, armedTapCounts: [2])
        for s in stream(narrowband: true).samples() { _ = detector.ingest(sample: s) }

        let onsets = detector.drainOnsets()
        XCTAssertGreaterThanOrEqual(onsets.count, 2, "the resonator declared no onsets to reject")
        XCTAssertTrue(onsets.allSatisfy(\.suppressedByGate),
                      "a cross-check rejection must reach the tap monitor, not vanish")
    }

    // MARK: - Fixtures

    /// Two strikes 160 ms apart. `narrowband` swaps the 180 Hz broadband ring a
    /// struck chassis makes for a long 40 Hz ring sitting on the resonator's own
    /// centre — the artifact class this mechanism claims to reject.
    ///
    /// Both stimuli are scaled to the SAME resonator envelope, twice the onset
    /// threshold, so the detector cannot tell them apart on the signal it
    /// actually thresholds and the cross-check is the only thing left that can.
    /// The scale factor is measured through the chain, never written down: the
    /// two waveforms differ in resonator gain by more than an order of magnitude
    /// and a shared constant would just be the gain trap again.
    private func stream(narrowband: Bool, amplitude: Double? = nil) -> SyntheticStream {
        let onsets = [SyntheticStream.leadInNs, SyntheticStream.leadInNs + 160_000_000]
        let a = amplitude ?? (2 * resonatorConfig.effectiveThreshold / unitResonatorPeak(narrowband: narrowband))
        var s = SyntheticStream(durationNs: onsets[1] + 1_000_000_000,
                                taps: onsets.map {
                                    narrowband
                                        ? SyntheticStream.Tap(tNs: $0, amplitude: a,
                                                              ringHz: 40, decaySeconds: 0.05)
                                        : SyntheticStream.Tap(tNs: $0, amplitude: a)
                                })
        s.noiseAmplitude = amplitude == nil ? 0.002 : 0
        return s
    }

    /// Resonator-path envelope peak for a unit-amplitude version of the fixture.
    /// Same role as `SyntheticStream.chainGain(tuning:)`, extended to a waveform
    /// the shared helper cannot make.
    private func unitResonatorPeak(narrowband: Bool) -> Double {
        var chain = SignalChain(tuning: resonatorTuning)
        var peak = 0.0
        for s in stream(narrowband: narrowband, amplitude: 1.0).samples() {
            peak = max(peak, chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                           holdNoiseFloor: false))
        }
        return peak
    }

    private func triggerCount(tuning: DSPTuning, narrowband: Bool) -> Int {
        let detector = TapDetector(config: resonatorConfig, tuning: tuning, armedTapCounts: [2])
        var n = 0
        for s in stream(narrowband: narrowband).samples() where detector.ingest(sample: s) != nil {
            n += 1
        }
        return n
    }

    /// Broadband support over resonator envelope AT THE FIRST CROSSING, which is
    /// the instant the detector reads it. Measured, not derived: the numerator is
    /// a look-back peak and the denominator is a rising edge sitting on the
    /// threshold, so the ratio the detector sees is not the ratio of the two
    /// waveforms' peaks.
    private func measuredCrossingRatio(narrowband: Bool) -> Double {
        var chain = SignalChain(tuning: resonatorTuning)
        let threshold = resonatorConfig.effectiveThreshold
        var index = 0
        for s in stream(narrowband: narrowband).samples() {
            let envelope = chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                         holdNoiseFloor: false)
            index += 1
            if index > DSPTuning.default.warmupSamples, envelope >= threshold {
                return chain.broadbandSupport / envelope
            }
        }
        XCTFail("fixture never crossed the onset threshold")
        return 0
    }

    /// Peak of the broadband path over the fixture, measured through the dual
    /// chain itself rather than assumed from a gain constant.
    private func measuredBroadbandPeak(ofRealStrike real: Bool) -> Double {
        var chain = SignalChain(tuning: resonatorTuning)
        var peak = 0.0
        for s in stream(narrowband: !real).samples() {
            chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z), holdNoiseFloor: false)
            peak = max(peak, chain.broadbandEnvelope)
        }
        return peak
    }
}
