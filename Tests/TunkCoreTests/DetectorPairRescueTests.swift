import XCTest
@testable import TunkCore

/// Retrospective pairing ranked by polarization, at the detector level.
///
/// Every fixture here is SYNTHETIC, and synthetic fixtures are the hardest case
/// this mechanism can be handed: `SyntheticStream` builds every tap as one
/// damped sinusoid scaled onto all three axes, so every transient it makes is
/// perfectly rectilinear and every transient points the SAME way. Both
/// discriminators the mechanism adds — the rectilinearity ranking and the
/// coherence veto — are therefore defeated by construction here. What these
/// tests measure is what survives when only the timing rules are left.
final class DetectorPairRescueTests: XCTestCase {

    private static func rescueTuning(candidateFraction: Double = 0.5,
                                     cosMin: Double = 0.7,
                                     rankByRect: Bool = true) -> DSPTuning {
        var t = DSPTuning.default
        t.pairRescueEnabled = true
        t.pairRescueCandidateFraction = candidateFraction
        t.pairRescueCosMin = cosMin
        t.pairRescueRankByRect = rankByRect
        return t
    }

    private func run(_ samples: [AccelSample],
                     inputs: [InputEvent] = [],
                     tuning: DSPTuning = .default,
                     config: DetectorConfig = .default,
                     armed: Set<Int> = [2])
        -> (triggers: [Trigger], onsets: [OnsetEvent], groups: [TapGroupEvent])
    {
        TapDetector.replayGroups(samples: samples, inputs: inputs, config: config,
                                 tuning: tuning, armedTapCounts: armed)
    }

    // MARK: - Fixtures with a chosen axis

    /// One damped ring along a chosen direction, so a transient can be made to
    /// point somewhere other than where the last one pointed.
    private struct AxisTap {
        var tNs: Int64
        var amplitude: Double
        var axis: (x: Double, y: Double, z: Double)
        var ringHz: Double = 180
        var decaySeconds: Double = 0.004
    }

    private func axisStream(_ taps: [AxisTap], durationNs: Int64,
                            noiseAmplitude: Double = 0.002,
                            seed: UInt64 = 0xC0FFEE) -> [AccelSample] {
        var noise = SyntheticNoise(seed: seed)
        var out: [AccelSample] = []
        var t: Int64 = 0
        while t <= durationNs {
            var x = 0.004 + noise.next(noiseAmplitude)
            var y = -0.003 + noise.next(noiseAmplitude)
            var z = -0.9796 + noise.next(noiseAmplitude)
            for tap in taps where t >= tap.tNs {
                let dt = Double(t - tap.tNs) / 1e9
                if dt > tap.decaySeconds * 8 { continue }
                let ring = exp(-dt / tap.decaySeconds) * sin(2 * Double.pi * tap.ringHz * dt)
                x += tap.amplitude * tap.axis.x * ring
                y += tap.amplitude * tap.axis.y * ring
                z += tap.amplitude * tap.axis.z * ring
            }
            out.append(AccelSample(tNs: t, arrivalNs: t + 300_000, x: Float(x), y: Float(y), z: Float(z)))
            t += SyntheticStream.intervalNs
        }
        return out
    }

    /// A full-bar strike, then a strike too weak to be an onset, `gapNs` later.
    /// The shipped detector sees one onset here and fires nothing.
    private func weakSecondTap(gapNs: Int64,
                               secondAmplitudeTimesThreshold: Double = 0.6,
                               secondAxis: (x: Double, y: Double, z: Double) = (0.35, 0.25, 1.0))
        -> [AccelSample]
    {
        let base = SyntheticStream.leadInNs
        return axisStream([
            AxisTap(tNs: base, amplitude: 0.9, axis: (0.35, 0.25, 1.0)),
            AxisTap(tNs: base + gapNs,
                    amplitude: SyntheticStream.amplitude(timesThreshold: secondAmplitudeTimesThreshold),
                    axis: secondAxis)
        ], durationNs: base + gapNs + 1_500_000_000)
    }

    // MARK: - Off unless asked for

    func testTheMechanismShipsOff() {
        XCTAssertFalse(DSPTuning.default.pairRescueEnabled,
                       "this must not ship on until it has been graded on held-out data")
    }

    func testAWeakSecondTapFiresNothingOnTheShippedDetector() {
        let samples = weakSecondTap(gapNs: 150_000_000)
        let result = run(samples)
        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertEqual(result.onsets.count, 1, "the weak strike never crosses the bar")
    }

    /// Turning the mechanism on must not disturb a gesture that already worked.
    /// Same samples, same triggers, same instants.
    func testACleanDoubleIsUntouchedByTheMechanism() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let samples = stream.samples()
        XCTAssertEqual(run(samples).triggers, run(samples, tuning: Self.rescueTuning()).triggers)
        XCTAssertEqual(run(samples).triggers.count, 1)
    }

    func testACleanTripleIsStillAnUnbindableThreeGroup() {
        let (stream, _) = SyntheticStream.gesture(count: 3, spacingNs: 150_000_000)
        let result = run(stream.samples(), tuning: Self.rescueTuning(), armed: [2])
        XCTAssertTrue(result.triggers.isEmpty, "a third full-bar onset still makes a 3-group")
        XCTAssertEqual(result.groups.first?.tapCount, 3)
    }

    // MARK: - What it recovers

    func testAWeakSecondTapIsRescuedAsADouble() {
        let samples = weakSecondTap(gapNs: 150_000_000)
        let result = run(samples, tuning: Self.rescueTuning())
        XCTAssertEqual(result.triggers.count, 1)
        guard let t = result.triggers.first else { return }
        XCTAssertEqual(t.tapCount, 2)
        XCTAssertEqual(t.tapOnsets.count, 2)
        let interval = t.tapOnsets[1] - t.tapOnsets[0]
        XCTAssertEqual(Double(interval) / 1e6, 150, accuracy: 8,
                       "the rescued onset lands on the weak strike, not somewhere else")
    }

    /// Latency is unchanged by construction: the decision happens at the
    /// deadline the detector was already waiting for. Measured from the FIRST
    /// onset, a rescued pair fires exactly one confirm window later, which is
    /// sooner after the second strike than an ordinary double.
    func testRescueCostsNoLatency() {
        let samples = weakSecondTap(gapNs: 150_000_000)
        guard let t = run(samples, tuning: Self.rescueTuning()).triggers.first else {
            return XCTFail("nothing fired")
        }
        let fromFirst = t.tNs - t.tapOnsets[0]
        XCTAssertGreaterThanOrEqual(fromFirst, DetectorConfig.default.confirmWindowNs)
        XCTAssertLessThan(fromFirst, DetectorConfig.default.confirmWindowNs + 5_000_000)
        XCTAssertLessThan(t.tNs - t.tapOnsets[1], DetectorConfig.default.confirmWindowNs)
    }

    func testACrestUnderTheCandidateFractionIsNotRescued() {
        // 0.3x the bar, against a 0.5 candidate fraction.
        let samples = weakSecondTap(gapNs: 150_000_000, secondAmplitudeTimesThreshold: 0.3)
        XCTAssertTrue(run(samples, tuning: Self.rescueTuning()).triggers.isEmpty)
        XCTAssertEqual(run(samples, tuning: Self.rescueTuning(candidateFraction: 0.2))
                        .triggers.count, 1,
                       "and it is the fraction that decided, not something else")
    }

    // MARK: - The rules it does not get to break

    func testTheInterTapBandStillApplies() {
        for gapMs in [40, 80, 260, 400] as [Int64] {
            let samples = weakSecondTap(gapNs: gapMs * 1_000_000)
            XCTAssertTrue(run(samples, tuning: Self.rescueTuning()).triggers.isEmpty,
                          "\(gapMs) ms is outside the legal band and must not be paired")
        }
        for gapMs in [110, 150, 200] as [Int64] {
            let samples = weakSecondTap(gapNs: gapMs * 1_000_000)
            XCTAssertEqual(run(samples, tuning: Self.rescueTuning()).triggers.count, 1,
                           "\(gapMs) ms is inside it")
        }
    }

    /// A deviation from the Python prototype, pinned rather than papered over.
    ///
    /// A crest's polarization is read `polarizationLookaheadSamples` after the
    /// crest, so a crest cannot be considered until those samples have arrived.
    /// The group's deadline is one confirm window after the anchor, which means
    /// the last ~10 ms of the legal inter-tap band is out of reach: at the
    /// instant the decision is made, that crest's axis reading does not exist
    /// yet. The prototype ran offline over precomputed arrays and had no such
    /// limit, so its band ran to the full 220 ms.
    ///
    /// Closing the gap would mean either reading samples from after the decision
    /// instant, which breaks the detector's contract, or moving the deadline,
    /// which spends latency. Measured on `data/raw`, the sliver costs nothing:
    /// every ablation row reproduces the prototype's train numbers exactly.
    ///
    /// Sweeping the gap in 5 ms steps, the last gap that pairs is 205 ms and the
    /// first that does not is 210 ms, against a 220 ms ceiling.
    func testTheTopOfTheBandIsOutOfReachByTheLookahead() {
        XCTAssertEqual(run(weakSecondTap(gapNs: 205_000_000), tuning: Self.rescueTuning())
                        .triggers.count, 1)
        XCTAssertTrue(run(weakSecondTap(gapNs: 210_000_000), tuning: Self.rescueTuning())
                        .triggers.isEmpty,
                      "inside the 220 ms ceiling, but its axis reading is not in yet")
        // Shorten the lag and the same crest becomes reachable, which is what
        // shows the edge is the lookahead and not some other rule.
        var shorter = Self.rescueTuning()
        shorter.polarizationLookaheadSamples = 2
        XCTAssertEqual(run(weakSecondTap(gapNs: 210_000_000), tuning: shorter).triggers.count, 1)
    }

    /// The input gate is read at the DEADLINE, so a keystroke whose HID event
    /// arrives after the chassis shock still retracts the crest. That is the
    /// same retroactive protection an onset gets, and it is the reason this
    /// mechanism does not spend the gate's timing margin.
    func testAKeystrokeKillsTheRescuedCrest() {
        let base = SyntheticStream.leadInNs
        let samples = weakSecondTap(gapNs: 150_000_000)
        let onGate = [InputEvent(tNs: base + 150_000_000, kind: .keyDown, code: 4)]
        XCTAssertTrue(run(samples, inputs: onGate, tuning: Self.rescueTuning()).triggers.isEmpty)

        // Delivered late, and still in time. The margin is the distance from
        // the crest to the deadline — 70 ms for a 150 ms pairing — against the
        // 25 ms of `preGateNs` that is all an ordinary second onset gets. This
        // mechanism buys typing margin rather than spending it, which is the
        // opposite of what sank `rejected/early-fire-on-count`.
        for lagMs in [20, 40, 60] as [Int64] {
            let late = [InputEvent(tNs: base + 150_000_000 + lagMs * 1_000_000,
                                   kind: .keyDown, code: 4)]
            XCTAssertTrue(run(samples, inputs: late, tuning: Self.rescueTuning()).triggers.isEmpty,
                          "a keystroke delivered \(lagMs) ms late still retracts the crest")
        }

        // Long before the crest, gate expired: the rescue is allowed.
        let old = [InputEvent(tNs: base - 400_000_000, kind: .keyDown, code: 4)]
        XCTAssertEqual(run(samples, inputs: old, tuning: Self.rescueTuning()).triggers.count, 1)
    }

    func testTheRefractoryStillApplies() {
        // Two gestures 300 ms apart: the second one's crest sits inside the
        // first one's refractory and must not be taken.
        let base = SyntheticStream.leadInNs
        let samples = axisStream([
            AxisTap(tNs: base, amplitude: 0.9, axis: (0.35, 0.25, 1.0)),
            AxisTap(tNs: base + 150_000_000, amplitude: 0.9, axis: (0.35, 0.25, 1.0)),
            AxisTap(tNs: base + 450_000_000, amplitude: 0.9, axis: (0.35, 0.25, 1.0)),
            AxisTap(tNs: base + 600_000_000,
                    amplitude: SyntheticStream.amplitude(timesThreshold: 0.6),
                    axis: (0.35, 0.25, 1.0))
        ], durationNs: base + 2_500_000_000)
        let result = run(samples, tuning: Self.rescueTuning())
        XCTAssertEqual(result.triggers.count, 1, "the refractory swallows the second pairing")
    }

    // MARK: - The veto

    /// The veto's direction is the whole claim: the second tap's axis is MORE
    /// aligned with the first tap's, not less. A crest that points somewhere
    /// else is rejected.
    func testACrestOnADifferentAxisIsVetoed() {
        let across = weakSecondTap(gapNs: 150_000_000, secondAxis: (1.0, -0.2, 0.05))
        XCTAssertTrue(run(across, tuning: Self.rescueTuning(cosMin: 0.7)).triggers.isEmpty,
                      "the coherence veto rejects it")
        XCTAssertEqual(run(across, tuning: Self.rescueTuning(cosMin: 0.0)).triggers.count, 1,
                       "and with the veto off the same crest is taken, so the veto is what decided")
    }

    func testACrestOnTheSameAxisSurvivesTheVeto() {
        let along = weakSecondTap(gapNs: 150_000_000, secondAxis: (0.35, 0.25, 1.0))
        XCTAssertEqual(run(along, tuning: Self.rescueTuning(cosMin: 0.7)).triggers.count, 1)
    }

    /// Ranking has to be able to disagree with amplitude, or the rect column in
    /// the ablation means nothing.
    ///
    /// Tested against the buffer rather than through a fixture, because a
    /// SYNTHETIC tap cannot pose the question: `SyntheticStream` scales one
    /// damped sinusoid onto three axes, so its crests are rectilinear or they
    /// are noise, and never the mixture a real broadband contact produces. The
    /// separation the mechanism rests on is measured on `data/raw`, not here.
    func testRankingByRectPicksADifferentCrestFromRankingByAmplitude() {
        var buffer = PairRescue(lookahead: 8)
        let anchor: Int64 = 0
        // A loud, perfectly rectilinear crest: a ring lobe. And a quieter one
        // whose energy is spread over a second axis: a fresh contact.
        buffer.insertForTesting(PairRescueCandidate(tNs: 150_000_000, amplitude: 0.030,
                                                    threshold: 0.032, rect: 0.996,
                                                    ux: 0, uy: 0, uz: 1))
        buffer.insertForTesting(PairRescueCandidate(tNs: 180_000_000, amplitude: 0.020,
                                                    threshold: 0.032, rect: 0.930,
                                                    ux: 0, uy: 0, uz: 1))
        func pick(rankByRect: Bool) -> Int64? {
            buffer.scan(anchorTNs: anchor, anchorAmplitude: 0.040,
                        minInterNs: 100_000_000, maxInterNs: 220_000_000,
                        refractoryUntilNs: .min, gateUntilNs: .min,
                        candidateFraction: 0.5, rectMax: 1.1, cosMin: 0,
                        anchorFraction: 0, rankByRect: rankByRect)?.tNs
        }
        XCTAssertEqual(pick(rankByRect: false), 150_000_000, "loudest")
        XCTAssertEqual(pick(rankByRect: true), 180_000_000, "least rectilinear")
    }

    /// Ties keep the earlier crest, so the choice cannot depend on iteration
    /// order or on how the ring happened to wrap.
    func testAnExactTieKeepsTheEarlierCrest() {
        var buffer = PairRescue(lookahead: 8)
        for t in [120_000_000, 160_000_000, 200_000_000] as [Int64] {
            buffer.insertForTesting(PairRescueCandidate(tNs: t, amplitude: 0.030,
                                                        threshold: 0.032, rect: 0.95,
                                                        ux: 0, uy: 0, uz: 1))
        }
        for byRect in [true, false] {
            XCTAssertEqual(buffer.scan(anchorTNs: 0, anchorAmplitude: 0.040,
                                       minInterNs: 100_000_000,
                                       maxInterNs: 220_000_000, refractoryUntilNs: .min,
                                       gateUntilNs: .min, candidateFraction: 0.5,
                                       rectMax: 1.1, cosMin: 0, anchorFraction: 0,
                                       rankByRect: byRect)?.tNs,
                           120_000_000)
        }
    }

    /// The rectilinearity ceiling is inactive at its shipped value and does bite
    /// when set, so the ablation can reach it.
    func testTheRectCeilingRejectsOutright() {
        var buffer = PairRescue(lookahead: 8)
        buffer.insertForTesting(PairRescueCandidate(tNs: 150_000_000, amplitude: 0.030,
                                                    threshold: 0.032, rect: 0.99,
                                                    ux: 0, uy: 0, uz: 1))
        func pick(rectMax: Double) -> PairRescueCandidate? {
            buffer.scan(anchorTNs: 0, anchorAmplitude: 0.040,
                        minInterNs: 100_000_000, maxInterNs: 220_000_000,
                        refractoryUntilNs: .min, gateUntilNs: .min, candidateFraction: 0.5,
                        rectMax: rectMax, cosMin: 0, anchorFraction: 0, rankByRect: true)
        }
        XCTAssertNotNil(pick(rectMax: DSPTuning.default.pairRescueRectMax))
        XCTAssertNil(pick(rectMax: 0.95))
    }

    // MARK: - Determinism and the detector's contract

    func testIdenticalInputTwiceGivesIdenticalOutput() {
        let samples = weakSecondTap(gapNs: 150_000_000)
        let a = run(samples, tuning: Self.rescueTuning())
        let b = run(samples, tuning: Self.rescueTuning())
        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.onsets, b.onsets)
        XCTAssertEqual(a.groups, b.groups)
    }

    /// Live and replay are the same code, and must stay so: the mechanism reads
    /// no clock and its buffer advances only on `ingest(sample:)`.
    func testLiveIngestMatchesReplayUnderWallClockJitter() {
        let samples = weakSecondTap(gapNs: 150_000_000)
        let replayed = run(samples, tuning: Self.rescueTuning()).triggers

        let live = TapDetector(config: .default, tuning: Self.rescueTuning(), armedTapCounts: [2])
        var liveTriggers: [Trigger] = []
        for (i, s) in samples.enumerated() {
            var jittered = s
            jittered.arrivalNs = s.tNs + Int64(i % 7) * 40_000_000 - 11_000_000
            if i % 500 == 0 { Thread.sleep(forTimeInterval: 0.005) }
            if let t = live.ingest(sample: jittered) { liveTriggers.append(t) }
        }
        XCTAssertEqual(liveTriggers, replayed)
        XCTAssertEqual(liveTriggers.count, 1)
    }

    func testResetDropsTheBufferedCrests() {
        let samples = weakSecondTap(gapNs: 150_000_000)
        let detector = TapDetector(config: .default, tuning: Self.rescueTuning(),
                                   armedTapCounts: [2])
        var triggers: [Trigger] = []
        let base = SyntheticStream.leadInNs
        for s in samples {
            // Reset between the anchor and its deadline.
            if s.tNs > base + 160_000_000 && s.tNs < base + 200_000_000 { detector.reset() }
            if let t = detector.ingest(sample: s) { triggers.append(t) }
        }
        XCTAssertTrue(triggers.isEmpty, "the group and its buffer went together")
    }

    // MARK: - The crest buffer on its own

    func testTheCrestBufferEvictsByTimeAndIsBounded() {
        var buffer = PairRescue(lookahead: 8)
        // A rising then falling ramp makes exactly one crest per cycle.
        var index = 0
        var t: Int64 = 0
        for cycle in 0..<5000 {
            for level in [0.02, 0.09, 0.03] {
                buffer.observe(tNs: t, index: index, envelope: level, threshold: 0.032,
                               rect: 0.9, ux: 0, uy: 0, uz: 1,
                               candidateFraction: 0.5, retentionNs: 440_000_000)
                index += 1
                t += SyntheticStream.intervalNs
            }
            XCTAssertLessThanOrEqual(buffer.bufferedCount, PairRescue.capacity, "cycle \(cycle)")
        }
        // 440 ms of retention at ~2.6 crests per 10 ms is well under the cap.
        XCTAssertLessThan(buffer.bufferedCount, PairRescue.capacity)
        XCTAssertGreaterThan(buffer.bufferedCount, 0)
    }
}
