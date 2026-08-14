import XCTest
@testable import TunkCore

/// `DetectorConfig.secondTapBarFraction`: the bar for a later onset in a live
/// gesture, as a fraction of the FIRST onset's measured peak.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). They prove what
/// the mechanism does to the state machine, not a detection rate; the rates are
/// measured on real recordings by `tunk-score` and written up in
/// `notes/PROPORTIONAL_BAR.md`.
final class SecondTapBarTests: XCTestCase {

    private func replay(_ stream: SyntheticStream, fraction: Double)
        -> (triggers: [Trigger], onsets: [OnsetEvent], groups: [TapGroupEvent])
    {
        var config = DetectorConfig.default
        config.secondTapBarFraction = fraction
        return TapDetector.replayGroups(samples: stream.samples(), inputs: [], config: config)
    }

    /// One gesture: a first tap at `first` times the shipped threshold and a
    /// second at `second`, spaced 160 ms, which is inside the join window and
    /// clear of the 100 ms debounce.
    private func gesture(first: Double, second: Double) -> SyntheticStream {
        let t0 = SyntheticStream.leadInNs
        return SyntheticStream(
            durationNs: t0 + 1_200_000_000,
            taps: [SyntheticStream.Tap(tNs: t0,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: first)),
                   SyntheticStream.Tap(tNs: t0 + 160_000_000,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: second))])
    }

    // MARK: - Off

    func testTheKnobShipsOff() {
        XCTAssertEqual(DetectorConfig.default.secondTapBarFraction, 0,
                       "shipped behaviour must be the behaviour measured before this existed")
    }

    /// With the knob off the bar does not move for the duration of a gesture.
    /// Sampled live, because a mechanism that only *usually* reduces to the old
    /// path is not off.
    func testOffLeavesTheBarWhereItWasForTheWholeGesture() {
        let detector = TapDetector(armedTapCounts: [2])
        var sawGestureInFlight = false
        for s in gesture(first: 1.6, second: 1.3).samples() {
            let before = detector.activeThreshold
            _ = detector.ingest(sample: s)
            let after = detector.activeThreshold
            if !detector.drainOnsets().isEmpty { sawGestureInFlight = true }
            // The only thing that may move the bar with the knob off is the
            // adaptive noise floor, which moves by parts in ten thousand per
            // sample, never by the tens of percent a proportional bar would.
            XCTAssertEqual(after, before, accuracy: 1e-6)
        }
        XCTAssertTrue(sawGestureInFlight, "fixture produced no onsets; it proves nothing")
    }

    /// Off is not merely "the same threshold": the same triggers, the same
    /// onsets, the same counts, across the shapes the mechanism could plausibly
    /// disturb.
    func testOffProducesTheSameTriggersAsTheMechanismBeingAbsent() {
        for first in [1.2, 2.0, 3.0] {
            for second in [0.8, 1.1, 2.0] {
                let stream = gesture(first: first, second: second)
                let off = replay(stream, fraction: 0)
                let plain = TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                                     config: .default)
                XCTAssertEqual(off.triggers, plain.triggers, "first \(first) second \(second)")
                XCTAssertEqual(off.onsets, plain.onsets, "first \(first) second \(second)")
                XCTAssertEqual(off.groups, plain.groups, "first \(first) second \(second)")
            }
        }
    }

    // MARK: - On

    /// The gap the mechanism exists to close: a second tap under the absolute
    /// threshold, after a first tap that cleared it. 0.8x the threshold is the
    /// shape of a lap second tap — three of the four held-out lap misses are a
    /// second strike that was never declared at all.
    func testAWeakSecondTapIsRecoveredOnlyWhenTheKnobIsOn() {
        let stream = gesture(first: 1.2, second: 0.8)

        let off = replay(stream, fraction: 0)
        XCTAssertEqual(off.triggers.count, 0, "baseline must miss this, or the fixture is not the gap")
        XCTAssertEqual(off.onsets.count, 1, "the second strike never clears the absolute bar")

        let on = replay(stream, fraction: 0.6)
        XCTAssertEqual(on.onsets.count, 2)
        XCTAssertEqual(on.triggers.count, 1)
        XCTAssertEqual(on.triggers.first?.tapOnsets.count, 2)
    }

    /// The property a fixed reduction cannot have. The same fraction that
    /// admits a weak second tap after a weak first tap leaves the full shipped
    /// bar in force after a loud one, so the same second strength that grouped
    /// in a quiet gesture is rejected in a loud one. That is what keeps
    /// ring-down on a damped surface out: a loud strike rings loudly, and the
    /// bar it faces never comes down.
    func testTheBarScalesWithTheFirstTapRatherThanSittingAtAConstant() {
        let quiet = replay(gesture(first: 1.2, second: 0.8), fraction: 0.6)
        XCTAssertEqual(quiet.triggers.count, 1, "a weak pair must group")

        let loud = replay(gesture(first: 3.0, second: 0.8), fraction: 0.6)
        XCTAssertEqual(loud.onsets.count, 1,
                       "the same second strength must NOT clear the bar after a loud first tap")
        XCTAssertEqual(loud.triggers.count, 0)
    }

    /// And the bar is never stricter than the shipped one. A loud first tap
    /// leaves the absolute threshold exactly where it was, so turning the knob
    /// on can only ever add detections, never take one away.
    func testALoudFirstTapLeavesTheShippedBarUntouched() {
        let detector = TapDetector(config: {
            var c = DetectorConfig.default
            c.secondTapBarFraction = 0.65
            return c
        }(), armedTapCounts: [2])

        var barsInFlight: [Double] = []
        for s in gesture(first: 3.0, second: 2.0).samples() {
            _ = detector.ingest(sample: s)
            if !detector.drainOnsets().isEmpty { barsInFlight.append(detector.activeThreshold) }
            _ = detector.drainGroups()
        }
        XCTAssertFalse(barsInFlight.isEmpty)
        for bar in barsInFlight {
            XCTAssertLessThanOrEqual(bar, DetectorConfig.default.defaultThreshold + 1e-9)
        }
    }

    /// The bar is a fraction of the first onset, never a licence to go under the
    /// noise-derived floor. On a surface loud enough to lift the adaptive term
    /// above the proportional one, the adaptive term wins.
    func testTheAdaptiveFloorHoldsTheProportionalBarUp() {
        let detector = TapDetector(config: {
            var c = DetectorConfig.default
            c.secondTapBarFraction = 0.6
            return c
        }(), armedTapCounts: [2])

        var noise = SyntheticNoise(seed: 0xB0A_71DE)
        var sawGesture = false
        for s in gesture(first: 1.2, second: 0.8).samples() {
            var loud = s
            loud.x += Float(noise.next(0.05))
            loud.y += Float(noise.next(0.05))
            loud.z += Float(noise.next(0.05))
            _ = detector.ingest(sample: loud)
            _ = detector.drainOnsets()
            _ = detector.drainGroups()
            sawGesture = true
            XCTAssertGreaterThanOrEqual(detector.activeThreshold,
                                        DSPTuning.default.minThresholdG - 1e-9)
        }
        XCTAssertTrue(sawGesture)
        XCTAssertGreaterThan(detector.activeThreshold, DetectorConfig.default.defaultThreshold,
                             "a live surface must still lift the bar above the absolute threshold")
    }

    /// The bar is only open while a gesture is: past `maxInterTapNs` from the
    /// last onset it is the ordinary threshold again, so a lone weak transient
    /// minutes later gets no help.
    func testTheProportionalBarClosesWithTheJoinWindow() {
        let t0 = SyntheticStream.leadInNs
        let stream = SyntheticStream(
            durationNs: t0 + 2_000_000_000,
            taps: [SyntheticStream.Tap(tNs: t0,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 1.2)),
                   // 400 ms later: past the 220 ms join window.
                   SyntheticStream.Tap(tNs: t0 + 400_000_000,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 0.8))])
        let on = replay(stream, fraction: 0.6)
        XCTAssertEqual(on.onsets.count, 1, "the late weak strike must face the full bar")
        XCTAssertEqual(on.triggers.count, 0)
    }

    // MARK: - Config plumbing

    func testANonsenseFractionClampsToOffAndSaysSo() {
        for bad in [-0.5, Double.nan, Double.infinity] {
            var c = DetectorConfig.default
            c.secondTapBarFraction = bad
            XCTAssertEqual(c.madeCoherent().secondTapBarFraction, 0)
            XCTAssertTrue(c.coherenceIssues.contains { $0.field == "secondTapBarFraction" },
                          "a clamp the user cannot see is a silent disagreement")
        }
    }

    func testASettingsFileWrittenBeforeTheKnobExistedLoadsWithItOff() throws {
        let legacy = """
        {"sensitivity":1,"defaultThreshold":0.032,"gateWindowNs":180000000,
         "minInterTapNs":100000000,"maxInterTapNs":220000000,
         "confirmWindowNs":220000000,"refractoryNs":600000000,"tapCountToFire":2}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DetectorConfig.self, from: legacy)
        XCTAssertEqual(decoded.secondTapBarFraction, 0)
    }

    func testTheFractionSurvivesARoundTrip() throws {
        var c = DetectorConfig.default
        c.secondTapBarFraction = 0.62
        let again = try JSONDecoder().decode(DetectorConfig.self,
                                             from: JSONEncoder().encode(c))
        XCTAssertEqual(again.secondTapBarFraction, 0.62)
        XCTAssertEqual(again, c)
    }
}
