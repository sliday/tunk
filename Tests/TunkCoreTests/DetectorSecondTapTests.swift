import XCTest
@testable import TunkCore

/// The gated second-tap bar: `DetectorConfig.secondTapThresholdFraction` and
/// `DetectorConfig.secondTapBaselineFraction`.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). These prove the
/// state machine, not a detection rate — the detection numbers for this pair
/// come from `tunk-score` over real recordings and are quoted in
/// notes/BAR_ASSESSMENT.md.
///
/// The mechanism exists because the ungated version of it,
/// `DSPTuning.inGestureThresholdFraction`, was measured and rejected: a flat
/// reduction after any onset let ring-down cross the reduced bar. The gate is
/// "the envelope came back down first", and the pair of tests at the bottom is
/// the one that matters — same weak second strike, accepted when the envelope
/// returned to baseline and refused when it did not.
final class DetectorSecondTapTests: XCTestCase {

    private let armed: Set<Int> = [2]

    private func off() -> DetectorConfig { .default }

    private func on(fraction: Double, baseline: Double) -> DetectorConfig {
        var c = DetectorConfig.default
        c.secondTapThresholdFraction = fraction
        c.secondTapBaselineFraction = baseline
        return c
    }

    /// One strong strike, then a weaker one `gapNs` later.
    private func pair(secondAmplitudeMultiple: Double,
                      gapNs: Int64 = 160_000_000) -> [AccelSample] {
        let first = SyntheticStream.leadInNs
        let second = first + gapNs
        var stream = SyntheticStream(
            durationNs: second + 1_000_000_000,
            taps: [SyntheticStream.Tap(tNs: first,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 2.0)),
                   SyntheticStream.Tap(tNs: second,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: secondAmplitudeMultiple))])
        stream.noiseAmplitude = 0.002
        return stream.samples()
    }

    private func replay(_ samples: [AccelSample], _ config: DetectorConfig)
        -> (triggers: [Trigger], onsets: [OnsetEvent], groups: [TapGroupEvent])
    {
        TapDetector.replayGroups(samples: samples, inputs: [], config: config,
                                 armedTapCounts: armed)
    }

    // MARK: - Off is off

    /// The shipped default is the disabled one. If this ever fails, the
    /// mechanism has started changing behaviour for users who never asked for
    /// it.
    func testShippedDefaultDisablesTheReducedBar() {
        XCTAssertEqual(DetectorConfig.default.secondTapThresholdFraction, 1.0)
    }

    /// With the fraction at 1.0 the detector must compute the same numbers it
    /// computed before this pair existed, whatever the baseline knob says.
    /// Asserted on a stream the mechanism would otherwise change: the weak
    /// second strike below is the one recovered in
    /// `testAWeakSecondStrikeIsRecoveredWhenTheEnvelopeReturned`.
    func testDisabledFractionReproducesTheBaselineExactly() {
        let samples = pair(secondAmplitudeMultiple: 0.9)
        let baseline = replay(samples, off())

        for baselineFraction in [0.0, 0.1, 0.25, 0.4, 1.0] {
            var config = DetectorConfig.default
            config.secondTapBaselineFraction = baselineFraction
            let run = replay(samples, config)
            XCTAssertEqual(run.triggers, baseline.triggers,
                           "triggers moved with the reduction off, r=\(baselineFraction)")
            XCTAssertEqual(run.onsets, baseline.onsets,
                           "onsets moved with the reduction off, r=\(baselineFraction)")
            XCTAssertEqual(run.groups, baseline.groups,
                           "groups moved with the reduction off, r=\(baselineFraction)")
        }
    }

    /// A baseline fraction of zero is the other off switch: the envelope can
    /// never fall below zero, so the reduction can never arm.
    func testZeroBaselineFractionAlsoDisablesTheReduction() {
        let samples = pair(secondAmplitudeMultiple: 0.9)
        let baseline = replay(samples, off())
        let run = replay(samples, on(fraction: 0.8, baseline: 0.0))
        XCTAssertEqual(run.triggers, baseline.triggers)
        XCTAssertEqual(run.onsets, baseline.onsets)
    }

    // MARK: - What it buys

    /// The gesture the shipped detector loses: a real double whose second
    /// strike lands just under the bar. It is one group of one onset with the
    /// reduction off, and a fired double with it on.
    func testAWeakSecondStrikeIsRecoveredWhenTheEnvelopeReturned() {
        let samples = pair(secondAmplitudeMultiple: 0.9)

        let before = replay(samples, off())
        XCTAssertEqual(before.triggers.count, 0, "fixture must be a miss before the change")
        XCTAssertEqual(before.groups.map(\.tapCount), [1])

        let after = replay(samples, on(fraction: 0.8, baseline: 0.3))
        XCTAssertEqual(after.triggers.count, 1, "the second strike should now be seen")
        XCTAssertEqual(after.triggers.first?.tapOnsets.count, 2)
    }

    /// A strike that is genuinely too weak stays missed. The reduction is a
    /// fraction of the bar, not the removal of it.
    func testAStrikeFarBelowTheReducedBarIsStillRefused() {
        let samples = pair(secondAmplitudeMultiple: 0.5)
        let after = replay(samples, on(fraction: 0.8, baseline: 0.3))
        XCTAssertEqual(after.triggers.count, 0)
        XCTAssertEqual(after.groups.map(\.tapCount), [1])
    }

    // MARK: - The gate itself

    /// The pair that separates this mechanism from the flat reduction that was
    /// measured and rejected.
    ///
    /// Same weak second strike in both runs. In one the envelope falls back to
    /// the noise floor between the strikes, which is what a real second tap
    /// looks like. In the other the chassis is still ringing — modelled as
    /// broadband shake held at a fraction of the threshold across the gap, so
    /// the envelope never returns — which is what a ring tail looks like. The
    /// reduced bar must arm in the first case and not in the second.
    func testTheReducedBarNeedsTheEnvelopeToComeBackDown() {
        let clean = pair(secondAmplitudeMultiple: 0.95)
        let firstNs = SyntheticStream.leadInNs
        let ringing = holdingEnvelopeUp(clean,
                                        amplitude: DetectorConfig.default.defaultThreshold * 0.3,
                                        fromNs: firstNs,
                                        toNs: firstNs + 160_000_000)

        let config = on(fraction: 0.8, baseline: 0.2)

        let returned = replay(clean, config)
        XCTAssertEqual(returned.triggers.count, 1,
                       "envelope returned to baseline: the reduced bar should arm")

        let held = replay(ringing, config)
        XCTAssertEqual(held.triggers.count, 0,
                       "envelope never came back: the reduced bar must stay shut")
        XCTAssertEqual(held.groups.map(\.tapCount), [1])
    }

    /// Sustain broadband shake over a window, so the envelope cannot fall back
    /// to the noise floor there. SYNTHETIC stand-in for a chassis still ringing.
    private func holdingEnvelopeUp(_ samples: [AccelSample], amplitude: Double,
                                   fromNs: Int64, toNs: Int64,
                                   seed: UInt64 = 0xDECA9) -> [AccelSample] {
        var noise = SyntheticNoise(seed: seed)
        return samples.map { s in
            guard s.tNs >= fromNs, s.tNs < toNs else { return s }
            var out = s
            out.x += Float(noise.next(amplitude))
            out.y += Float(noise.next(amplitude))
            out.z += Float(noise.next(amplitude))
            return out
        }
    }

    /// The evidence is per onset, not per gesture. After a second onset the
    /// detector must wait for the envelope to come back down again before it
    /// will drop the bar for a third.
    func testEachOnsetHasToEarnTheReductionAgain() {
        let samples = pair(secondAmplitudeMultiple: 0.9)
        let config = on(fraction: 0.8, baseline: 0.3)
        let run = replay(samples, config)
        XCTAssertEqual(run.groups.map(\.tapCount), [2],
                       "no phantom third onset from the second strike's own ring-down")
    }

    // MARK: - Coherence

    func testAFractionOutsideTheUnitRangeIsClampedOff() {
        for bad in [1.5, 0.0, -0.2, Double.nan] {
            var c = DetectorConfig.default
            c.secondTapThresholdFraction = bad
            XCTAssertEqual(c.madeCoherent().secondTapThresholdFraction, 1.0,
                           "fraction \(bad) should clamp to no reduction")
            XCTAssertTrue(c.coherenceIssues.contains { $0.field == "secondTapThresholdFraction" })
        }
    }

    func testABaselineFractionOutsideTheUnitRangeIsClampedOff() {
        for bad in [-0.1, 1.4, Double.infinity] {
            var c = DetectorConfig.default
            c.secondTapBaselineFraction = bad
            XCTAssertEqual(c.madeCoherent().secondTapBaselineFraction, 0,
                           "baseline fraction \(bad) should clamp to never arming")
            XCTAssertTrue(c.coherenceIssues.contains { $0.field == "secondTapBaselineFraction" })
        }
    }

    /// A settings file written before these keys existed must keep loading, and
    /// must load with the mechanism off.
    func testASettingsFileWithoutTheKeysLoadsWithTheMechanismOff() throws {
        let json = Data(#"{"sensitivity":1.0,"defaultThreshold":0.032}"#.utf8)
        let decoded = try JSONDecoder().decode(DetectorConfig.self, from: json)
        XCTAssertEqual(decoded.secondTapThresholdFraction, 1.0)
        XCTAssertEqual(decoded.secondTapBaselineFraction,
                       DetectorConfig.default.secondTapBaselineFraction)
    }

    func testTheKnobsSurviveARoundTrip() throws {
        let config = on(fraction: 0.85, baseline: 0.3)
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(DetectorConfig.self, from: data)
        XCTAssertEqual(back.secondTapThresholdFraction, 0.85)
        XCTAssertEqual(back.secondTapBaselineFraction, 0.3)
    }
}
