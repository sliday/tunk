import XCTest
@testable import TunkCore

/// Pruning an over-long group down to an armed count.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). These prove what
/// the knob does to the state machine — what fires, what refuses to, and that
/// OFF is the old detector exactly. The detection numbers live in the harness,
/// on recorded data.
final class GroupPruneTests: XCTestCase {

    private static let double: Set<Int> = [2]
    private static let doubleAndTriple: Set<Int> = [2, 3]

    private func config(ranker: Int, maxDrop: Int = 1, requireSpacing: Bool = true) -> DetectorConfig {
        var c = DetectorConfig.default
        c.groupPruneRanker = ranker
        c.groupPruneMaxDrop = maxDrop
        c.groupPruneRequireSpacing = requireSpacing
        return c
    }

    /// Three taps 150 ms apart: one group of three, which nothing is bound to.
    private func triple(spacingNs: Int64 = 150_000_000) -> SyntheticStream {
        SyntheticStream.gesture(count: 3, spacingNs: spacingNs).stream
    }

    // MARK: - Off is the old detector, exactly

    func testDefaultConfigHasPruningOff() {
        XCTAssertEqual(DetectorConfig.default.groupPruneRanker, 0)
    }

    /// The proof the shipped build is untouched. Same samples, same inputs; the
    /// default config and an explicitly-off config must produce byte-identical
    /// triggers, onsets and groups, on a stream that exercises every path the
    /// prune could have reached: a double, a triple, and a knock train.
    func testOffReproducesTheBaselineExactly() {
        var stream = SyntheticStream(durationNs: 12_000_000_000)
        let base = SyntheticStream.leadInNs
        let amplitude = SyntheticStream.amplitude(timesThreshold: 2.0)
        for t in [base, base + 160_000_000,                                   // double
                  base + 3_000_000_000, base + 3_150_000_000, base + 3_300_000_000,  // triple
                  base + 6_000_000_000, base + 6_120_000_000,                 // tight pair
                  base + 8_000_000_000] {                                     // lone tap
            stream.taps.append(.init(tNs: t, amplitude: amplitude))
        }
        for i in 0..<20 {   // knock train at double-tap cadence
            stream.taps.append(.init(tNs: base + 9_000_000_000 + Int64(i) * 200_000_000,
                                     amplitude: amplitude))
        }
        let samples = stream.samples()

        let off = TapDetector.replayGroups(samples: samples, inputs: [],
                                           config: .default, armedTapCounts: Self.double)
        for ranker in [0] {
            let explicit = TapDetector.replayGroups(samples: samples, inputs: [],
                                                    config: config(ranker: ranker),
                                                    armedTapCounts: Self.double)
            XCTAssertEqual(off.triggers, explicit.triggers)
            XCTAssertEqual(off.onsets, explicit.onsets)
            XCTAssertEqual(off.groups, explicit.groups)
        }
        XCTAssertFalse(off.groups.isEmpty, "the fixture must actually produce groups")
        XCTAssertTrue(off.groups.allSatisfy { $0.prunedFrom == nil })
    }

    /// The same stream with every ranker on must leave the ARMED groups alone:
    /// pruning may only ever touch a group whose count fires nothing.
    func testPruningNeverTouchesAGroupThatAlreadyFires() {
        let stream = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000).stream
        let samples = stream.samples()
        let off = TapDetector.replayGroups(samples: samples, inputs: [],
                                           config: .default, armedTapCounts: Self.double)
        XCTAssertEqual(off.triggers.count, 1)

        for ranker in [1, 2, 3, 4, 5, 6, -1, -2] {
            let on = TapDetector.replayGroups(samples: samples, inputs: [],
                                              config: config(ranker: ranker),
                                              armedTapCounts: Self.double)
            XCTAssertEqual(off.triggers, on.triggers, "ranker \(ranker) changed a 2-tap gesture")
            XCTAssertEqual(off.groups, on.groups, "ranker \(ranker) changed a 2-tap group")
        }
    }

    // MARK: - What the knob does when it is on

    func testATripleFiresNothingWithPruningOff() {
        let result = TapDetector.replayGroups(samples: triple().samples(), inputs: [],
                                              config: .default, armedTapCounts: Self.double)
        XCTAssertEqual(result.groups.map(\.tapCount), [3])
        XCTAssertEqual(result.triggers.count, 0)
    }

    /// The cost, stated as a test rather than as a hope. A deliberate triple
    /// fires nothing today; with pruning on and only double armed, it fires a
    /// DOUBLE. Anyone arming this knob is choosing that trade.
    ///
    /// Taps 150 ms apart, so keeping the last candidate leaves a 300 ms pair the
    /// spacing rule would refuse. The rule is tested on its own below; this test
    /// is about the count, so it runs with the rule off.
    func testATripleBecomesADoubleWhenPruningIsOn() {
        for ranker in [1, 2, 3, 4, 5, 6] {
            let result = TapDetector.replayGroups(samples: triple().samples(), inputs: [],
                                                  config: config(ranker: ranker,
                                                                 requireSpacing: false),
                                                  armedTapCounts: Self.double)
            XCTAssertEqual(result.triggers.count, 1, "ranker \(ranker)")
            XCTAssertEqual(result.triggers.first?.tapCount, 2, "ranker \(ranker)")
            XCTAssertEqual(result.groups.first?.prunedFrom, 3, "ranker \(ranker)")
            XCTAssertEqual(result.groups.first?.tapCount, 2, "ranker \(ranker)")
        }
    }

    /// ...and it does not happen when the user has bound triple, because then
    /// the group already fires something they asked for.
    func testATripleIsLeftAloneWhenTripleIsArmed() {
        let result = TapDetector.replayGroups(samples: triple().samples(), inputs: [],
                                              config: config(ranker: 1),
                                              armedTapCounts: Self.doubleAndTriple)
        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertEqual(result.triggers.first?.tapCount, 3)
        XCTAssertNil(result.groups.first?.prunedFrom)
    }

    /// A knock train is the reason the confirm window exists. Pruning must not
    /// turn one into a trigger every group, whatever the ranker says: a group of
    /// twenty is nine drops away from a double and `groupPruneMaxDrop` refuses.
    func testAKnockTrainStillFiresNothing() {
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 61_000_000_000)
        for i in 0..<240 {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * 250_000_000,
                                     amplitude: 0.5))
        }
        let samples = stream.samples()
        for ranker in [1, 2, 3, 4, 5, 6] {
            let result = TapDetector.replayGroups(samples: samples, inputs: [],
                                                  config: config(ranker: ranker, maxDrop: 2),
                                                  armedTapCounts: Self.double)
            XCTAssertEqual(result.triggers.count, 0,
                           "ranker \(ranker) fired on 60 s of thumps at double-tap cadence")
        }
    }

    /// Pruning may not quietly widen the join window. Three onsets at 0, 120 and
    /// 260 ms: dropping the middle one leaves a 260 ms pair, wider than the
    /// 220 ms the grouper accepts, so with the spacing rule on nothing fires.
    func testTheSpacingRuleRefusesAPairTheGrouperWouldNotHaveAccepted() {
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 2_000_000_000)
        let amplitude = SyntheticStream.amplitude(timesThreshold: 2.0)
        for offset in [Int64(0), 120_000_000, 260_000_000] {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + offset, amplitude: amplitude))
        }
        let samples = stream.samples()

        // Ranker 5 keeps the latest candidate, so it is the one that always asks
        // for the wide pair. That makes this a test of the rule, not of a ranker.
        let strict = TapDetector.replayGroups(samples: samples, inputs: [],
                                              config: config(ranker: 5, requireSpacing: true),
                                              armedTapCounts: Self.double)
        XCTAssertEqual(strict.triggers.count, 0)
        XCTAssertNil(strict.groups.first?.prunedFrom)

        let relaxed = TapDetector.replayGroups(samples: samples, inputs: [],
                                               config: config(ranker: 5, requireSpacing: false),
                                               armedTapCounts: Self.double)
        XCTAssertEqual(relaxed.triggers.count, 1)
        XCTAssertEqual(relaxed.triggers.first?.tapOnsets.count, 2)
        let onsets = relaxed.triggers[0].tapOnsets
        XCTAssertGreaterThan(onsets[1] - onsets[0], DetectorConfig.default.maxInterTapNs)
    }

    func testMaxDropZeroDisablesPruningWithoutTouchingTheRanker() {
        let result = TapDetector.replayGroups(samples: triple().samples(), inputs: [],
                                              config: config(ranker: 1, maxDrop: 0),
                                              armedTapCounts: Self.double)
        XCTAssertEqual(result.triggers.count, 0)
        XCTAssertEqual(result.groups.map(\.tapCount), [3])
    }

    /// Pruning down to a single tap is never allowed. Single is a different risk
    /// class — every mug set down is one transient — and it is not something a
    /// ranker gets to decide for the user.
    func testATripleIsNeverPrunedDownToASingleTap() {
        let result = TapDetector.replayGroups(samples: triple().samples(), inputs: [],
                                              config: config(ranker: 1, maxDrop: 2),
                                              armedTapCounts: [1])
        XCTAssertEqual(result.triggers.count, 0)
        XCTAssertEqual(result.groups.map(\.tapCount), [3])
    }

    // MARK: - Determinism and config hygiene

    func testPruningStaysDeterministic() {
        let samples = triple().samples()
        for ranker in [1, 2, 3, 4] {
            let a = TapDetector.replayGroups(samples: samples, inputs: [],
                                             config: config(ranker: ranker),
                                             armedTapCounts: Self.double)
            let b = TapDetector.replayGroups(samples: samples, inputs: [],
                                             config: config(ranker: ranker),
                                             armedTapCounts: Self.double)
            XCTAssertEqual(a.triggers, b.triggers, "ranker \(ranker)")
            XCTAssertEqual(a.groups, b.groups, "ranker \(ranker)")
        }
    }

    func testAnUnknownRankerIsClampedOffRatherThanSubstituted() {
        var c = DetectorConfig.default
        c.groupPruneRanker = 99
        XCTAssertEqual(c.madeCoherent().groupPruneRanker, 0)
        XCTAssertTrue(c.coherenceIssues.contains { $0.field == "groupPruneRanker" })

        c.groupPruneRanker = -99
        XCTAssertEqual(c.madeCoherent().groupPruneRanker, 0)
    }

    func testMaxDropIsClampedToWhatAGroupCanHold() {
        var c = DetectorConfig.default
        c.groupPruneMaxDrop = 9
        XCTAssertEqual(c.madeCoherent().groupPruneMaxDrop, DetectorConfig.maxGroupPruneDrop)
        c.groupPruneMaxDrop = -1
        XCTAssertEqual(c.madeCoherent().groupPruneMaxDrop, 0)
    }

    /// A settings file written before this knob existed must keep working, and
    /// must come back with pruning off.
    func testASettingsFileWithoutTheKnobLoadsWithPruningOff() throws {
        let json = Data(#"{"sensitivity":1.0,"defaultThreshold":0.032,"tapCountToFire":2}"#.utf8)
        let decoded = try JSONDecoder().decode(DetectorConfig.self, from: json)
        XCTAssertEqual(decoded.groupPruneRanker, 0)
        XCTAssertEqual(decoded.groupPruneMaxDrop, 1)
        XCTAssertTrue(decoded.groupPruneRequireSpacing)
    }

    func testTheKnobSurvivesARoundTrip() throws {
        var c = DetectorConfig.default
        c.groupPruneRanker = -2
        c.groupPruneMaxDrop = 2
        c.groupPruneRequireSpacing = false
        let back = try JSONDecoder().decode(DetectorConfig.self,
                                            from: try JSONEncoder().encode(c))
        XCTAssertEqual(back.groupPruneRanker, -2)
        XCTAssertEqual(back.groupPruneMaxDrop, 2)
        XCTAssertFalse(back.groupPruneRequireSpacing)
    }

    // MARK: - The feature math

    /// The anchor is always kept, and exactly `target` onsets come back in time
    /// order, whatever the ranker.
    func testSelectionKeepsTheAnchorAndReturnsTheTargetCountInOrder() {
        let samples = shapeSamples()
        let onsets: [Int64] = [0, 100_000_000, 200_000_000]
        for ranker in [1, 2, 3, 4, 5, 6, -1, -2, -3, -4] {
            guard let kept = GroupPrune.select(onsets: onsets, strengths: [1, 1, 1], target: 2,
                                               samples: samples, peakHoldNs: 12_000_000,
                                               ranker: ranker) else {
                return XCTFail("ranker \(ranker) declined a well-formed group")
            }
            XCTAssertEqual(kept.count, 2, "ranker \(ranker)")
            XCTAssertEqual(kept.first, 0, "ranker \(ranker) dropped the anchor")
            XCTAssertEqual(kept, kept.sorted(), "ranker \(ranker) returned onsets out of order")
        }
    }

    func testSelectionDeclinesWhenTheSampleHistoryIsMissing() {
        XCTAssertNil(GroupPrune.select(onsets: [0, 100_000_000, 200_000_000], strengths: [1, 1, 1],
                                       target: 2, samples: [], peakHoldNs: 12_000_000, ranker: 1))
    }

    func testSelectionDeclinesWhenNothingWouldBeDropped() {
        XCTAssertNil(GroupPrune.select(onsets: [0, 100_000_000], strengths: [1, 1], target: 2,
                                       samples: shapeSamples(), peakHoldNs: 12_000_000, ranker: 1))
    }

    /// cos_first_xy is a direction comparison and nothing else: same lateral
    /// direction reads +1, opposite reads -1, whatever the amplitudes are.
    func testCosFirstXYReadsDirectionNotSize() {
        let s: [GroupPrune.ShapeSample] = [
            .init(tNs: 0, x: 1, y: 0, z: 0),
            .init(tNs: 1, x: 9, y: 0, z: 5),
            .init(tNs: 2, x: -0.1, y: 0, z: 0),
            .init(tNs: 3, x: 0, y: 1, z: 0),
        ]
        XCTAssertEqual(GroupPrune.cosFirstXY(samples: s, peak: 1, first: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(GroupPrune.cosFirstXY(samples: s, peak: 2, first: 0), -1.0, accuracy: 1e-9)
        XCTAssertEqual(GroupPrune.cosFirstXY(samples: s, peak: 3, first: 0), 0.0, accuracy: 1e-9)
    }

    /// A pure sinusoid sits at sqrt(2), which is the ring-lobe value the
    /// measurement found (1.39 against sqrt(2) = 1.414). An impulse sits far
    /// above it. If this ever stops holding, the statistic has stopped being
    /// crest factor.
    func testCrestFactorSeparatesASinusoidFromAnImpulse() {
        let rate = 796.3
        let intervalNs = Int64(1e9 / rate)
        var sine: [GroupPrune.ShapeSample] = []
        var impulse: [GroupPrune.ShapeSample] = []
        for i in 0..<64 {
            let t = Int64(i) * intervalNs
            let phase = 2 * Double.pi * 40.0 * Double(t) / 1e9
            sine.append(.init(tNs: t, x: sin(phase), y: 0, z: 0))
            impulse.append(.init(tNs: t, x: i == 8 ? 1 : 0.02, y: 0, z: 0))
        }
        let sineCrest = GroupPrune.crest(samples: sine, peak: 5)
        let impulseCrest = GroupPrune.crest(samples: impulse, peak: 8)
        XCTAssertEqual(sineCrest, 2.0.squareRoot(), accuracy: 0.15)
        XCTAssertGreaterThan(impulseCrest, 3.0)
    }

    /// A candidate sitting exactly on the preceding onset's decay curve reads
    /// ~0; one standing above it reads positive. That is the whole statistic.
    func testDecayResidualIsZeroOnTheCurveAndPositiveAboveIt() {
        let intervalNs = Int64(1_256_000)
        let tau = 0.03
        var onCurve: [GroupPrune.ShapeSample] = []
        for i in 0..<200 {
            let t = Int64(i) * intervalNs
            let value = exp(-Double(t) / 1e9 / tau)
            onCurve.append(.init(tNs: t, x: value, y: 0, z: 0))
        }
        let candidate = 150
        XCTAssertEqual(GroupPrune.decayResidual(samples: onCurve, previousPeak: 0, peak: candidate),
                       0, accuracy: 0.25)

        var withStrike = onCurve
        withStrike[candidate].x *= 6
        XCTAssertGreaterThan(
            GroupPrune.decayResidual(samples: withStrike, previousPeak: 0, peak: candidate), 1.0)
    }

    /// A synthetic three-onset stream where the middle candidate is a ring lobe
    /// on the FIRST strike's axis-flipped tail and the last is a fresh strike in
    /// the first strike's own direction. cos_first_xy has to keep the last one.
    private func shapeSamples() -> [GroupPrune.ShapeSample] {
        let intervalNs = Int64(1_256_000)
        var out: [GroupPrune.ShapeSample] = []
        var t: Int64 = 0
        while t <= 400_000_000 {
            var x = 0.0, y = 0.0, z = 0.0
            func ring(_ start: Int64, _ amplitude: Double, _ sign: Double) {
                let dt = Double(t - start) / 1e9
                guard dt >= 0, dt < 0.05 else { return }
                let value = amplitude * exp(-dt / 0.006) * sin(2 * Double.pi * 180 * dt)
                x += sign * value
                y += sign * value * 0.5
                z += value
            }
            ring(0, 1.0, 1)
            ring(100_000_000, 0.5, -1)
            ring(200_000_000, 0.8, 1)
            out.append(.init(tNs: t, x: x, y: y, z: z))
            t += intervalNs
        }
        return out
    }

    func testCosFirstXYPicksTheStrikeThatMatchesTheFirstDirection() {
        let samples = shapeSamples()
        let kept = GroupPrune.select(onsets: [0, 100_000_000, 200_000_000], strengths: [1, 0.5, 0.8],
                                     target: 2, samples: samples, peakHoldNs: 12_000_000, ranker: 1)
        XCTAssertEqual(kept, [0, 2],
                       "the lobe on the flipped axis must lose to the strike sharing the "
                       + "first strike's lateral direction")
    }
}
