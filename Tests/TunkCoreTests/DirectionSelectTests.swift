import XCTest
@testable import TunkCore
import TunkFormat

/// `secondOnsetFraction` + `directionSelect`: admit a weaker onset inside an
/// open group's join window, then pick the real second tap back out of the
/// over-long group by lateral direction.
///
/// The knob defaults to off, so the first test here is that off is off — not
/// "roughly the same numbers", but the same triggers, sample for sample, on
/// every recorded session.
final class DirectionSelectTests: XCTestCase {

    /// Tuned setting, measured on `data/raw` only. Never fitted on the held-out
    /// set and never scored against it.
    private static func tuned() -> DetectorConfig {
        var c = DetectorConfig.default
        c.secondOnsetFraction = 0.8
        c.directionSelect = true
        c.directionMinCos = 0.5
        return c
    }

    private static var dataRoot: URL {
        // Walk up from this file rather than hard-coding a checkout path, so the
        // suite measures the worktree it is running in.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("data/raw")
    }

    private static func tapDecks() throws -> [Session] {
        let sessions = (try? Session.discover(root: dataRoot)) ?? []
        return sessions.filter { $0.meta.sessionId.hasPrefix("tap_deck__") }
    }

    // MARK: - Off is off

    func testDefaultsAreOff() {
        XCTAssertEqual(DetectorConfig.default.secondOnsetFraction, 1.0)
        XCTAssertFalse(DetectorConfig.default.directionSelect)
        XCTAssertEqual(DetectorConfig.default.directionMinCos, -1.0)
    }

    /// Byte-identical behaviour with the knob off, on real recordings: same
    /// triggers, same onsets, same groups. A mechanism that changes the shipped
    /// path while "disabled" is not a mechanism behind a knob.
    func testOffReproducesBaselineOnEveryRecordedSession() throws {
        let sessions = try Self.tapDecks()
        try XCTSkipIf(sessions.isEmpty, "no recordings under \(Self.dataRoot.path)")

        var explicitlyOff = DetectorConfig.default
        explicitlyOff.secondOnsetFraction = 1.0
        explicitlyOff.directionSelect = false

        for s in sessions {
            let samples = try s.samples()
            let inputs = try s.inputs().map(\.event)
            let a = TapDetector.replayGroups(samples: samples, inputs: inputs,
                                             config: .default)
            let b = TapDetector.replayGroups(samples: samples, inputs: inputs,
                                             config: explicitlyOff)
            XCTAssertEqual(a.triggers, b.triggers, s.meta.sessionId)
            XCTAssertEqual(a.onsets, b.onsets, s.meta.sessionId)
            XCTAssertEqual(a.groups, b.groups, s.meta.sessionId)
        }
    }

    /// The selection path can only ever rescue a group that fires nothing. With
    /// the reduced bar on and selection off, the detector must still be the
    /// baseline detector for every group of two — the only difference allowed is
    /// the extra onsets the reduced bar admits.
    func testSelectionNeverTouchesAGroupOfTwo() {
        var cfg = Self.tuned()
        cfg.secondOnsetFraction = 1.0
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()
        let plain = TapDetector.replayGroups(samples: samples, inputs: [], config: .default)
        let selected = TapDetector.replayGroups(samples: samples, inputs: [], config: cfg)
        XCTAssertEqual(plain.triggers, selected.triggers)
        XCTAssertEqual(plain.groups, selected.groups)
    }

    // MARK: - Selection, measured against the labels

    /// For every selection the detector made on a labelled tap deck: was the
    /// real second tap among the candidates, and did the ranker pick it?
    ///
    /// Prints per session, always. One lap session is recorded with a hand
    /// resting on the chassis and behaves differently from the other three, so a
    /// pooled number here would hide the only thing worth knowing.
    func testSelectionAccuracyAgainstLabels() throws {
        let sessions = try Self.tapDecks()
        try XCTSkipIf(sessions.isEmpty, "no recordings under \(Self.dataRoot.path)")
        let near: Int64 = 60_000_000

        var totalInvoked = 0, totalApplied = 0, totalRecoverable = 0, totalCorrect = 0
        print("  selection audit  (secondOnsetFraction 0.8, directionMinCos 0.5)")
        for s in sessions {
            let samples = try s.samples()
            let inputs = try s.inputs().map(\.event)
            let labelled = try s.labelGroups().filter { $0.count >= 2 }

            let detector = TapDetector(config: Self.tuned())
            var i = 0, j = 0
            while i < samples.count || j < inputs.count {
                let takeInput = i >= samples.count
                    || (j < inputs.count && inputs[j].tNs <= samples[i].tNs)
                if takeInput { detector.ingest(input: inputs[j]); j += 1 }
                else { _ = detector.ingest(sample: samples[i]); i += 1 }
            }
            let selections = detector.drainSelections()
            let groups = detector.drainGroups()
            // How many groups even reach the state selection exists for. This is
            // the ceiling on what ranking can possibly be worth, and it belongs
            // beside the accuracy number: a perfect ranker invoked twice moves
            // detection by two.
            var byCount: [Int: Int] = [:]
            for g in groups { byCount[g.tapCount, default: 0] += 1 }

            var invoked = 0, applied = 0, recoverable = 0, correct = 0, unlabelled = 0
            for sel in selections {
                invoked += 1
                if sel.applied { applied += 1 }
                // The labelled gesture this group belongs to: the one whose
                // first onset is nearest the group's head.
                let match = labelled.min { a, b in
                    abs(a[0].tNs - sel.firstOnsetNs) < abs(b[0].tNs - sel.firstOnsetNs)
                }
                guard let g = match, abs(g[0].tNs - sel.firstOnsetNs) <= near else {
                    unlabelled += 1
                    continue
                }
                let truth = g[1].tNs
                // Could the ranker have got it right at all?
                if sel.candidateOnsetsNs.contains(where: { abs($0 - truth) <= near }) {
                    recoverable += 1
                    if sel.applied, abs(sel.chosenOnsetNs - truth) <= near { correct += 1 }
                }
                let detail = zip(sel.candidateOnsetsNs, sel.cosines).map {
                    String(format: "%+.0f ms cos %+.2f%@", Double($0.0 - truth) / 1e6, $0.1,
                           sel.applied && $0.0 == sel.chosenOnsetNs ? " <-" : "")
                }.joined(separator: ", ")
                print("      count \(sel.originalCount)\(sel.applied ? "" : " (no selection)"): \(detail)")
            }
            totalInvoked += invoked
            totalApplied += applied
            totalRecoverable += recoverable
            totalCorrect += correct
            let pct = recoverable > 0 ? String(format: "%5.1f %%", 100 * Double(correct) / Double(recoverable))
                                      : "   -- "
            let shape = byCount.keys.sorted().map { "\($0)x\(byCount[$0]!)" }.joined(separator: " ")
            print(String(format: "  %-46@ tried %3d  applied %3d  2nd tap present %3d  chosen right %3d  %@  off-label %d   groups %@",
                         s.meta.sessionId as NSString, invoked, applied, recoverable, correct,
                         pct as NSString, unlabelled, shape as NSString))
        }
        let pooled = totalRecoverable > 0 ? Double(totalCorrect) / Double(totalRecoverable) : 0
        print(String(format: "  pooled: tried %d, applied %d, second tap present %d, chosen right %d (%.1f %%)",
                     totalInvoked, totalApplied, totalRecoverable, totalCorrect, 100 * pooled))

        // MEASURED, and it is a negative. Across 123 labelled gestures the
        // ranker is offered a choice nine times, acts three times, and picks the
        // onset nearest the labelled second tap once. The other two fire the
        // first strike plus a ring lobe, and the harness's +/-150 ms match
        // window credits them as detections anyway.
        //
        // Held as equalities so a later change to the front end has to come back
        // here and restate them rather than quietly drifting.
        XCTAssertEqual(totalInvoked, 9)
        XCTAssertEqual(totalApplied, 3)
        XCTAssertEqual(totalRecoverable, 4)
        XCTAssertEqual(totalCorrect, 1)
        XCTAssertEqual(pooled, 0.25, accuracy: 0.001)
    }

    /// The statistic the ranker rests on, measured here rather than taken on
    /// trust: cosine between the lateral direction at the first labelled tap's
    /// peak and at the second's.
    ///
    /// It also pins WHICH sample counts as the peak. Choosing it by total
    /// high-passed energy — z dominates that — reads the lateral direction at
    /// whatever phase the z ring is in, and the same medians come out at -0.06
    /// on soft and -0.39 on one lap deck. Choosing it by lateral energy gives
    /// the numbers below. `SignalChain.lateralEnergy` is lateral because of this.
    func testTheLateralPeakDefinitionIsTheOneThatSeparates() throws {
        let sessions = try Self.tapDecks()
        try XCTSkipIf(sessions.isEmpty, "no recordings under \(Self.dataRoot.path)")

        func lateralAtPeak(_ samples: [AccelSample], around tNs: Int64) -> (x: Double, y: Double)? {
            var chain = SignalChain(tuning: .default)
            var best = -1.0
            var out: (x: Double, y: Double)?
            for s in samples {
                if s.tNs < tNs - 300_000_000 { continue }
                _ = chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                  holdNoiseFloor: false)
                if s.tNs < tNs - 10_000_000 { continue }
                if s.tNs > tNs + 25_000_000 { break }
                if chain.lateralEnergy > best {
                    best = chain.lateralEnergy
                    out = (chain.lateralX, chain.lateralY)
                }
            }
            return out
        }

        print("  cosine between the two strikes of a labelled gesture, lateral peak")
        for s in sessions {
            let samples = try s.samples()
            let groups = try s.labelGroups().filter { $0.count >= 2 }
            guard groups.count >= 10 else { continue }
            var cosines: [Double] = []
            for g in groups {
                guard let a = lateralAtPeak(samples, around: g[0].tNs),
                      let b = lateralAtPeak(samples, around: g[1].tNs) else { continue }
                let na = (a.x * a.x + a.y * a.y).squareRoot()
                let nb = (b.x * b.x + b.y * b.y).squareRoot()
                guard na > 0, nb > 0 else { continue }
                cosines.append((a.x * b.x + a.y * b.y) / (na * nb))
            }
            let median = cosines.sorted()[cosines.count / 2]
            print(String(format: "  %-46@ n %3d  median %+.3f  positive %3d",
                         s.meta.sessionId as NSString, cosines.count, median,
                         cosines.filter { $0 > 0 }.count))
            XCTAssertGreaterThan(median, 0.5, s.meta.sessionId)
        }
    }

    /// The measured train result, held as a regression floor. Detection on lap
    /// goes 59/80 to 66/80 with desk and soft untouched; if a later change moves
    /// any of these, it should have to say so here.
    func testTunedSettingHoldsItsMeasuredNumbers() throws {
        let sessions = try Self.tapDecks()
        try XCTSkipIf(sessions.isEmpty, "no recordings under \(Self.dataRoot.path)")

        var detected: [String: (hit: Int, total: Int)] = [:]
        for s in sessions {
            let samples = try s.samples()
            let inputs = try s.inputs().map(\.event)
            let labelled = try s.labelGroups().filter { $0.count == 2 }
            guard !labelled.isEmpty else { continue }
            let surface = s.meta.surface.rawValue
            let result = TapDetector.replayGroups(samples: samples, inputs: inputs,
                                                  config: Self.tuned())
            var t = detected[surface] ?? (0, 0)
            for g in labelled {
                t.total += 1
                let last = g[1].tNs
                let hits = result.triggers.filter {
                    abs(($0.tapOnsets.last ?? 0) - last) <= 150_000_000
                }
                if hits.count == 1 { t.hit += 1 }
            }
            detected[surface] = t
        }
        // Same +/-150 ms rule the harness scores with, so these track the
        // reported numbers rather than a second definition of "detected".
        XCTAssertEqual(detected["desk"]?.hit, 22)
        XCTAssertEqual(detected["soft"]?.hit, 20)
        XCTAssertEqual(detected["lap"]?.hit, 66)
    }

    // MARK: - Synthetic behaviour

    /// Three strikes 110 ms apart, the middle one struck the other way about.
    /// Onsets and amplitudes are identical; only the direction differs, which is
    /// the whole claim.
    private func threeStrikesMiddleReversed() -> (samples: [AccelSample], onsets: [Int64]) {
        let a = SyntheticStream.amplitude(timesThreshold: 3)
        let onsets = [SyntheticStream.leadInNs,
                      SyntheticStream.leadInNs + 110_000_000,
                      SyntheticStream.leadInNs + 215_000_000]
        var stream = SyntheticStream(
            durationNs: onsets[2] + 1_000_000_000,
            taps: [SyntheticStream.Tap(tNs: onsets[0], amplitude: a),
                   SyntheticStream.Tap(tNs: onsets[1], amplitude: -a),
                   SyntheticStream.Tap(tNs: onsets[2], amplitude: a)])
        stream.noiseAmplitude = 0.002
        return (stream.samples(), onsets)
    }

    /// A three-onset group fires nothing without selection, and fires a double
    /// with it. Synthetic, so the point is the state machine, not the physics.
    func testAnOverLongGroupFiresOnlyWithSelection() {
        let (samples, _) = threeStrikesMiddleReversed()
        let off = TapDetector.replayGroups(samples: samples, inputs: [], config: .default)
        XCTAssertEqual(off.triggers.count, 0)
        XCTAssertEqual(off.groups.map(\.tapCount), [3])

        var cfg = DetectorConfig.default
        cfg.directionSelect = true
        let on = TapDetector.replayGroups(samples: samples, inputs: [], config: cfg)
        XCTAssertEqual(on.triggers.count, 1)
        XCTAssertEqual(on.groups.map(\.tapCount), [2])
    }

    /// It picks by DIRECTION, not by recency or by strength: the candidate
    /// struck the same way as the first survives, the reversed one is dropped.
    func testItKeepsTheCandidateMatchingTheFirstStrike() {
        let (samples, onsets) = threeStrikesMiddleReversed()
        var cfg = DetectorConfig.default
        cfg.directionSelect = true
        let on = TapDetector.replayGroups(samples: samples, inputs: [], config: cfg)
        let fired = on.triggers.first
        XCTAssertEqual(fired?.tapOnsets.count, 2)
        // The crossing lands a sample or two into the strike, so compare against
        // the tap times with a millisecond of slack rather than exactly.
        XCTAssertEqual(Double(fired?.tapOnsets.first ?? 0), Double(onsets[0]), accuracy: 3e6)
        XCTAssertEqual(Double(fired?.tapOnsets.last ?? 0), Double(onsets[2]), accuracy: 3e6)
    }

    /// The cosine floor is a veto: set it above what any candidate reaches and
    /// the group keeps its count and keeps firing nothing.
    func testTheCosineFloorCanVetoEverySelection() {
        let a = SyntheticStream.amplitude(timesThreshold: 3)
        let onsets = [SyntheticStream.leadInNs,
                      SyntheticStream.leadInNs + 110_000_000,
                      SyntheticStream.leadInNs + 215_000_000]
        var stream = SyntheticStream(
            durationNs: onsets[2] + 1_000_000_000,
            taps: [SyntheticStream.Tap(tNs: onsets[0], amplitude: a),
                   SyntheticStream.Tap(tNs: onsets[1], amplitude: -a),
                   SyntheticStream.Tap(tNs: onsets[2], amplitude: -a)])
        stream.noiseAmplitude = 0.002
        let samples = stream.samples()

        var cfg = DetectorConfig.default
        cfg.directionSelect = true
        cfg.directionMinCos = 0.5
        let vetoed = TapDetector.replayGroups(samples: samples, inputs: [], config: cfg)
        XCTAssertEqual(vetoed.groups.map(\.tapCount), [3])
        XCTAssertEqual(vetoed.triggers.count, 0)

        cfg.directionMinCos = -1
        let allowed = TapDetector.replayGroups(samples: samples, inputs: [], config: cfg)
        XCTAssertEqual(allowed.groups.map(\.tapCount), [2])
    }

    /// A count that IS bound is never rewritten. With triple armed, a group of
    /// three stays a triple.
    func testABoundCountIsNeverRewritten() {
        let (samples, _) = threeStrikesMiddleReversed()
        var cfg = DetectorConfig.default
        cfg.directionSelect = true
        cfg.armedTapCounts = [2, 3]
        let on = TapDetector.replayGroups(samples: samples, inputs: [], config: cfg,
                                          armedTapCounts: [2, 3])
        XCTAssertEqual(on.groups.map(\.tapCount), [3])
        XCTAssertEqual(on.triggers.first?.tapCount, 3)
    }

    /// Coherence: a fraction outside (0, 1] and a cosine outside [-1, 1] are
    /// clamped rather than run.
    func testIncoherentKnobsAreClamped() {
        var c = DetectorConfig.default
        c.secondOnsetFraction = 1.5
        c.directionMinCos = 4
        let fixed = c.madeCoherent()
        XCTAssertEqual(fixed.secondOnsetFraction, 1.0)
        XCTAssertEqual(fixed.directionMinCos, -1.0)
        XCTAssertEqual(c.coherenceIssues.count, 2)

        var zero = DetectorConfig.default
        zero.secondOnsetFraction = 0
        XCTAssertEqual(zero.madeCoherent().secondOnsetFraction, 1.0)
    }

    /// The knobs survive a round trip through the settings file, and a file
    /// written before they existed still loads with them off.
    func testCodableRoundTripAndLegacyFile() throws {
        var c = DetectorConfig.default
        c.secondOnsetFraction = 0.8
        c.directionSelect = true
        c.directionMinCos = 0.5
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(DetectorConfig.self, from: data)
        XCTAssertEqual(back, c)

        let legacy = Data(#"{"sensitivity":1.0,"defaultThreshold":0.032,"tapCountToFire":2}"#.utf8)
        let old = try JSONDecoder().decode(DetectorConfig.self, from: legacy)
        XCTAssertEqual(old.secondOnsetFraction, 1.0)
        XCTAssertFalse(old.directionSelect)
    }
}
