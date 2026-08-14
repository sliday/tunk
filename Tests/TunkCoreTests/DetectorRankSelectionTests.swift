import XCTest
@testable import TunkCore

/// Within-group ranking of the second tap.
///
/// Every waveform here is SYNTHETIC, generated from a formula. These prove the
/// state machine — that the knob is inert when off, that a selection costs no
/// latency, that the gate still outranks it. Detection rates come from recorded
/// sessions through `tunk-score`, never from here.
final class DetectorRankSelectionTests: XCTestCase {

    // MARK: - Fixtures

    /// One gesture on a chassis that rings long enough to deafen the detector:
    /// the envelope never falls back under `releaseFraction * threshold` between
    /// the two strikes, so the second strike is never declared an onset. This is
    /// the failure the ranking mechanism exists for, measured on real lap
    /// recordings as 12 of 80 gestures.
    private func deafGesture(spacingNs: Int64 = 200_000_000)
        -> (samples: [AccelSample], first: Int64, second: Int64)
    {
        let first = SyntheticStream.leadInNs
        let second = first + spacingNs
        var stream = SyntheticStream(durationNs: second + 1_500_000_000, taps: [
            SyntheticStream.Tap(tNs: first,
                                amplitude: SyntheticStream.amplitude(timesThreshold: 2.2),
                                ringHz: 60, decaySeconds: 0.15),
            SyntheticStream.Tap(tNs: second,
                                amplitude: SyntheticStream.amplitude(timesThreshold: 1.6),
                                ringHz: 60, decaySeconds: 0.15)
        ])
        stream.noiseAmplitude = 0.002
        return (stream.samples(), first, second)
    }

    private var rankingOn: DetectorConfig {
        var config = DetectorConfig.default
        config.rankCandidateFraction = 0.7
        config.rankAgreement = 2
        return config
    }

    // MARK: - Off by default, and inert when off

    func testTheKnobShipsOff() {
        XCTAssertEqual(DetectorConfig.default.rankCandidateFraction, 0,
                       "ranking must be opt-in; shipped behaviour is the build before it existed")
    }

    /// The other rank knobs must do nothing at all while the master knob is
    /// zero. If any of them leaked, "default" and "default plus wild rank
    /// settings" would diverge somewhere in these four streams.
    func testWithTheKnobOffEveryOtherRankKnobIsInert() {
        var wild = DetectorConfig.default
        wild.rankCandidateFraction = 0
        wild.rankAgreement = 0
        wild.rankWeightCos = 17
        wild.rankWeightCrest = 5
        wild.rankWeightDecay = -3
        wild.rankWeightKurtosis = 99

        let streams: [(String, [AccelSample])] = [
            ("deaf gesture", deafGesture().samples),
            ("clean double", SyntheticStream.gesture(count: 2, spacingNs: 160_000_000).stream.samples()),
            ("triple", SyntheticStream.gesture(count: 3, spacingNs: 150_000_000).stream.samples()),
            ("knock train", SyntheticStream.gesture(count: 12, spacingNs: 250_000_000).stream.samples())
        ]

        for (name, samples) in streams {
            let plain = TapDetector.replayGroups(samples: samples, inputs: [],
                                                 config: .default)
            let knobbed = TapDetector.replayGroups(samples: samples, inputs: [],
                                                   config: wild)
            XCTAssertEqual(plain.triggers, knobbed.triggers, "triggers differ on \(name)")
            XCTAssertEqual(plain.onsets, knobbed.onsets, "onsets differ on \(name)")
            XCTAssertEqual(plain.groups, knobbed.groups, "groups differ on \(name)")
        }
    }

    /// The fixture has to be a real failure for the rest of the file to mean
    /// anything: with the knob off this gesture fires nothing, and it fires
    /// nothing because the detector never heard the second strike.
    func testTheFixtureIsDeafWithTheKnobOff() {
        let fixture = deafGesture()
        let off = TapDetector.replayGroups(samples: fixture.samples, inputs: [], config: .default)
        XCTAssertTrue(off.triggers.isEmpty, "fixture must not fire before the mechanism runs")
        XCTAssertEqual(off.onsets.filter { !$0.suppressedByGate }.count, 1,
                       "fixture must produce exactly one onset, i.e. the detector was deaf")
    }

    // MARK: - What ranking does

    /// Turns the deaf group of one into a group of two, choosing an onset from
    /// inside the join window.
    ///
    /// It does not assert which candidate wins. A synthetic tap is a pure damped
    /// sinusoid, so its own lobes are indistinguishable from a fresh strike by
    /// construction — the shape statistics have nothing to separate here, and
    /// pretending otherwise would be testing the fixture. Which candidate wins on
    /// real recordings is `tunk-score`'s job, and the answer is in the commit
    /// message.
    func testRankingRecoversTheDeafSecondStrike() {
        let fixture = deafGesture()
        let on = TapDetector.replayGroups(samples: fixture.samples, inputs: [], config: rankingOn)
        XCTAssertEqual(on.triggers.count, 1, "the gesture should fire once")
        guard let trigger = on.triggers.first else { return }
        XCTAssertEqual(trigger.tapCount, 2)
        XCTAssertEqual(trigger.tapOnsets[0], on.onsets.first?.tNs)
        let gap = trigger.tapOnsets[1] - trigger.tapOnsets[0]
        XCTAssertGreaterThanOrEqual(gap, DetectorConfig.default.minInterTapNs)
        XCTAssertLessThanOrEqual(gap, DetectorConfig.default.maxInterTapNs)
    }

    /// The mechanism may not buy detection with latency. A recovered gesture
    /// fires exactly one confirm window after the onset that was selected —
    /// the same rule, and the same number, as a gesture the detector heard
    /// unaided.
    func testASelectedGestureSpendsNoExtraLatency() {
        let fixture = deafGesture()
        let on = TapDetector.replayGroups(samples: fixture.samples, inputs: [], config: rankingOn)
        guard let trigger = on.triggers.first, let last = trigger.tapOnsets.last else {
            return XCTFail("expected a trigger")
        }
        let latency = trigger.tNs - last
        XCTAssertLessThanOrEqual(latency,
                                 DetectorConfig.default.confirmWindowNs + SyntheticStream.intervalNs,
                                 "fired later than one confirm window after its own second onset")
        XCTAssertGreaterThanOrEqual(latency, DetectorConfig.default.confirmWindowNs)
    }

    /// The graceful-degradation clause. Ask for agreement from more statistics
    /// than are enabled and the ranker can never satisfy it, so every group is
    /// left exactly as today's detector left it.
    func testAnUnsatisfiableAgreementDegradesToTodaysBehaviour() {
        let fixture = deafGesture()
        var impossible = rankingOn
        impossible.rankAgreement = 4          // only cos, decay and kurtosis are weighted
        let off = TapDetector.replayGroups(samples: fixture.samples, inputs: [], config: .default)
        let declined = TapDetector.replayGroups(samples: fixture.samples, inputs: [], config: impossible)
        XCTAssertEqual(declined.triggers, off.triggers)
        XCTAssertEqual(declined.onsets, off.onsets)
        XCTAssertEqual(declined.groups.map(\.tapOnsets), off.groups.map(\.tapOnsets))
        XCTAssertEqual(declined.groups.map(\.fired), off.groups.map(\.fired))
        // The one visible difference, and it is deliberate: a group of one holds
        // its confirm decision open until the candidates could have been scored.
        // Nothing is bound to a count of one, so no user-visible latency moves.
        XCTAssertEqual(Double(declined.groups.first!.tNs - off.groups.first!.tNs),
                       Double(DSPTuning.default.rankStatTailNs),
                       accuracy: Double(SyntheticStream.intervalNs))
    }

    /// The gate outranks the ranker. A keystroke over the second strike must
    /// keep the gesture from firing even though the candidate is there and wins.
    func testTheGateStillSuppressesASelectedOnset() {
        let fixture = deafGesture()
        let key = InputEvent(tNs: fixture.second - 5_000_000, kind: .keyDown, code: 4)
        let gated = TapDetector.replayGroups(samples: fixture.samples, inputs: [key],
                                             config: rankingOn)
        XCTAssertTrue(gated.triggers.isEmpty, "a gated second strike must not be selected")
    }

    /// Ranking only runs where a group of one could become a group of two. With
    /// single tap armed the group fires on its own, and holding its confirm
    /// decision open would be latency spent for nothing.
    func testSingleTapArmedOptsOutOfRanking() {
        let fixture = deafGesture()
        var config = rankingOn
        config.armedTapCounts = [1, 2]
        let armed = TapDetector.replayGroups(samples: fixture.samples, inputs: [], config: config)
        XCTAssertEqual(armed.triggers.count, 1)
        XCTAssertEqual(armed.triggers.first?.tapCount, 1,
                       "single tap must still fire one confirm window after the first onset")
    }

    // MARK: - Config plumbing

    func testTheRankKnobsSurviveASettingsRoundTrip() throws {
        var config = DetectorConfig.default
        config.rankCandidateFraction = 0.7
        config.rankAgreement = 3
        config.rankWeightCos = 1
        config.rankWeightCrest = 0.25
        config.rankWeightDecay = 2
        config.rankWeightKurtosis = 0.5
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(DetectorConfig.self, from: data)
        XCTAssertEqual(back, config)
    }

    /// A settings file written before this round must keep working, with
    /// ranking off rather than half-configured.
    func testASettingsFileWithoutTheRankKeysLoadsWithRankingOff() throws {
        let legacy = #"{"sensitivity":1,"defaultThreshold":0.032,"tapCountToFire":2}"#
        let config = try JSONDecoder().decode(DetectorConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.rankCandidateFraction, 0)
        XCTAssertEqual(config.rankAgreement, DetectorConfig.default.rankAgreement)
    }
}
