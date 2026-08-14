import XCTest
@testable import TunkCore

/// The sub-threshold second-tap admission: `DetectorConfig.secondTapAdmitFraction`
/// and `secondTapAdmitMinCrest`.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). These tests
/// prove the state machine — that the knob is off by default, that the off path
/// is byte-identical to the shipped one, that an admission lands at the crossing
/// rather than at the decision, and that the shape gate can veto. The real
/// question, whether admitting weak second taps helps on a lap, is answered by
/// `tunk-score` over recorded sessions and not by anything in this file.
final class SecondTapAdmissionTests: XCTestCase {

    private func run(_ stream: SyntheticStream, config: DetectorConfig)
        -> (triggers: [Trigger], onsets: [OnsetEvent])
    {
        TapDetector.replay(samples: stream.samples(), inputs: [], config: config)
    }

    /// A full-strength first strike and a second one too weak to clear the bar,
    /// 150 ms later. The shipped detector sees one onset and fires nothing.
    private func weakSecondTap(spacingNs: Int64 = 150_000_000,
                               secondMultiple: Double = 0.85) -> SyntheticStream {
        let first = SyntheticStream.leadInNs
        let second = first + spacingNs
        var stream = SyntheticStream(
            durationNs: second + 1_000_000_000,
            taps: [SyntheticStream.Tap(tNs: first,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 1.6)),
                   SyntheticStream.Tap(tNs: second,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: secondMultiple))])
        stream.noiseAmplitude = 0.002
        return stream
    }

    // MARK: - Off by default

    func testShippedDefaultHasTheAdmissionOff() {
        XCTAssertEqual(DetectorConfig.default.secondTapAdmitFraction, 1.0,
                       "1.0 is off; anything below it changes shipped behaviour")
        XCTAssertEqual(DetectorConfig.default.secondTapAdmitMinCrest, 0.0)
    }

    /// The off path has to be the *same* path, not a similar one.
    func testOffIsIdenticalToTheShippedDetector() {
        let stream = weakSecondTap()
        var explicitlyOff = DetectorConfig.default
        explicitlyOff.secondTapAdmitFraction = 1.0
        explicitlyOff.secondTapAdmitMinCrest = 0

        let shipped = run(stream, config: .default)
        let off = run(stream, config: explicitlyOff)

        XCTAssertEqual(shipped.triggers, off.triggers)
        XCTAssertEqual(shipped.onsets, off.onsets)
        XCTAssertTrue(shipped.triggers.isEmpty,
                      "the weak second tap is missed with the knob off — that is the gap")
        XCTAssertEqual(shipped.onsets.filter { !$0.suppressedByGate }.count, 1)
    }

    /// A fraction outside (0, 1] is not a sneaky way to change behaviour.
    func testAnIncoherentFractionFallsBackToOff() {
        for bad in [0.0, -0.5, Double.nan] {
            var config = DetectorConfig.default
            config.secondTapAdmitFraction = bad
            XCTAssertEqual(config.madeCoherent().secondTapAdmitFraction, 1.0)
            XCTAssertTrue(config.coherenceIssues.contains { $0.field == "secondTapAdmitFraction" })
        }
        var negativeCrest = DetectorConfig.default
        negativeCrest.secondTapAdmitMinCrest = -1
        XCTAssertEqual(negativeCrest.madeCoherent().secondTapAdmitMinCrest, 0)
    }

    // MARK: - On

    func testAdmittingTheSecondTapCompletesTheGesture() {
        let stream = weakSecondTap()
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.8
        config.secondTapAdmitMinCrest = 0

        let result = run(stream, config: config)
        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertEqual(result.triggers.first?.tapCount, 2)
    }

    /// The shape window is looked at *after* the crossing, so the decision is
    /// deferred by a dozen samples. The onset it produces must still be stamped
    /// at the crossing, or every admitted gesture would fire late.
    func testAnAdmittedOnsetIsStampedAtTheCrossingNotTheDecision() {
        let spacing: Int64 = 150_000_000
        let stream = weakSecondTap(spacingNs: spacing)
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.8

        guard let trigger = run(stream, config: config).triggers.first else {
            return XCTFail("expected the gesture to fire")
        }
        let secondStrike = SyntheticStream.leadInNs + spacing
        XCTAssertEqual(trigger.tapOnsets.count, 2)
        XCTAssertLessThan(abs(trigger.tapOnsets[1] - secondStrike), 5_000_000,
                          "admitted onset within 5 ms of the synthetic strike")
        let latency = trigger.tNs - trigger.tapOnsets[1]
        XCTAssertLessThan(latency, DetectorConfig.default.confirmWindowNs + 10_000_000,
                          "the shape window must not be added to the latency")
        XCTAssertLessThanOrEqual(latency, 250_000_000, "PRD p95 latency budget")
    }

    func testTheShapeGateCanVetoAnAdmission() {
        let stream = weakSecondTap()
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.8
        config.secondTapAdmitMinCrest = 50   // no real strike is this impulsive

        let result = run(stream, config: config)
        XCTAssertTrue(result.triggers.isEmpty,
                      "the shape test is the veto, and it has to be able to say no")
        XCTAssertEqual(result.onsets.filter { !$0.suppressedByGate }.count, 1)
    }

    /// A weak strike with nothing before it is not a first tap and is not a
    /// second tap either. The reduced bar exists only inside a live gesture.
    func testAWeakTapOnItsOwnIsNeverAdmitted() {
        let first = SyntheticStream.leadInNs
        var stream = SyntheticStream(
            durationNs: first + 2_000_000_000,
            taps: [SyntheticStream.Tap(tNs: first,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 0.85))])
        stream.noiseAmplitude = 0.002
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.5
        config.armedTapCounts = [1, 2]

        let result = run(stream, config: config)
        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertTrue(result.onsets.filter { !$0.suppressedByGate }.isEmpty,
                      "no group is live, so the bar never comes down")
    }

    /// One admission per gesture. Two would let a ringing chassis assemble a
    /// whole gesture out of a single strike.
    func testOnlyOneAdmissionPerGesture() {
        let first = SyntheticStream.leadInNs
        let weak = SyntheticStream.amplitude(timesThreshold: 0.85)
        var stream = SyntheticStream(
            durationNs: first + 2_000_000_000,
            taps: [SyntheticStream.Tap(tNs: first,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 1.6)),
                   SyntheticStream.Tap(tNs: first + 110_000_000, amplitude: weak),
                   SyntheticStream.Tap(tNs: first + 215_000_000, amplitude: weak)])
        stream.noiseAmplitude = 0.002
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.8

        let result = run(stream, config: config)
        let ungated = result.onsets.filter { !$0.suppressedByGate }
        XCTAssertEqual(ungated.count, 2, "the strong strike and one admission, not two")
        XCTAssertEqual(result.triggers.first?.tapCount, 2)
    }

    /// Nothing about the admission may change how the detector re-arms. Lowering
    /// the release level along with the crossing level is what
    /// `DSPTuning.inGestureThresholdFraction` did, and it cost the soft surface
    /// 8 of 40 onsets: the detector sat disarmed through the real second tap.
    func testTheReleaseLevelIsUntouchedByTheAdmission() {
        // Second strike strong enough to clear the full bar on its own. If the
        // reduced bar were also driving the hysteresis, the detector would still
        // be disarmed when it arrives.
        let spacing: Int64 = 150_000_000
        let stream = weakSecondTap(spacingNs: spacing, secondMultiple: 1.4)
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.5

        let onKnob = run(stream, config: config)
        let off = run(stream, config: .default)
        XCTAssertEqual(onKnob.triggers.count, 1)
        XCTAssertEqual(onKnob.triggers.map(\.tapOnsets), off.triggers.map(\.tapOnsets),
                       "a gesture the shipped detector already gets must be untouched")
    }

    // MARK: - Round trip

    func testSettingsRoundTripAndOldFilesStayOff() throws {
        var config = DetectorConfig.default
        config.secondTapAdmitFraction = 0.8
        config.secondTapAdmitMinCrest = 1.15
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(DetectorConfig.self, from: data)
        XCTAssertEqual(back.secondTapAdmitFraction, 0.8)
        XCTAssertEqual(back.secondTapAdmitMinCrest, 1.15)

        let old = Data(#"{"sensitivity": 1.0, "defaultThreshold": 0.032}"#.utf8)
        let migrated = try JSONDecoder().decode(DetectorConfig.self, from: old)
        XCTAssertEqual(migrated.secondTapAdmitFraction, 1.0,
                       "a settings file written before this knob existed must stay off")
        XCTAssertEqual(migrated.secondTapAdmitMinCrest, 0.0)
    }
}
