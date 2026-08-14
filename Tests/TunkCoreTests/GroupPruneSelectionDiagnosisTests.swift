import XCTest
@testable import TunkCore
import TunkFormat

/// Diagnostic on RECORDED training data: when a group holds a real second strike
/// AND ring ripple, does the ranker keep the strike?
///
/// The harness cannot answer this on the shipped config, because the shipped
/// config almost never produces an over-long group: across all 14 training
/// sessions there is exactly ONE group of three, so a detection number computed
/// from it is a number computed from n = 1.
///
/// So this test manufactures the condition the mechanism was built for, the one
/// every re-arm mechanism ran into: it re-arms early, so the detector hears the
/// first strike's ripple as well as the second strike and groups of three and
/// four appear. Then it asks the only question pruning has to answer — of the
/// candidates in that group, is the one nearest the labelled second tap the one
/// the ranker keeps?
///
/// Two controls run alongside the three shape statistics, and they are the point
/// of the test. `CONTROL_last` keeps the newest candidate and reads no signal at
/// all. `CONTROL_strength` keeps the biggest, which is amplitude — the thing
/// four earlier mechanisms were built on and which was measured shut. A shape
/// statistic that does not beat both has bought nothing.
///
/// The amplitude-matched slice is where the shape statistics were originally
/// measured: contests whose candidates sit within 1.5x of each other in
/// envelope. Outside that band amplitude answers the question on its own, so a
/// pooled number flatters whichever statistic correlates with size.
///
/// This is a MEASUREMENT, not a shipped path. These re-arm tunings are not
/// something this build ships; they exist here to make contests to rank.
final class GroupPruneSelectionDiagnosisTests: XCTestCase {

    /// How close a candidate must be to the labelled onset to count as it.
    private static let matchNs: Int64 = 60_000_000
    /// Candidates within this ratio of each other count as amplitude-matched.
    private static let amplitudeBand = 1.5
    /// Re-arm levels that manufacture contests. The shipped value is 0.4, which
    /// produces almost none; every value here is deliberately deafer-to-nothing.
    private static let releaseFractions = [0.6, 0.75, 0.9]

    private static let rankers: [(name: String, value: Int)] = [
        ("cos_first_xy", 1),
        ("crest", 2),
        ("crest_inv", -2),
        ("decay_resid", 3),
        ("combined", 4),
        ("CONTROL_last", 5),
        ("CONTROL_strength", 6),
    ]

    private struct Tally {
        var contests = 0
        var matchedContests = 0
        var hits: [String: Int] = [:]
        var matchedHits: [String: Int] = [:]

        mutating func add(_ o: Tally) {
            contests += o.contests
            matchedContests += o.matchedContests
            for (k, v) in o.hits { hits[k, default: 0] += v }
            for (k, v) in o.matchedHits { matchedHits[k, default: 0] += v }
        }
    }

    private func dataRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TunkCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("data/raw")
    }

    /// The shipped tuning with an earlier re-arm. The debounce stays at the
    /// shipped 100 ms on purpose: shortening it does NOT lengthen groups, since
    /// onsets closer than `minInterTapNs` abort the group outright and
    /// `minInterTapNs` cannot legally sit below the debounce. Ripple has to
    /// arrive at the debounce period to chain, which is exactly the "metronome
    /// at the debounce period" the earlier re-arm mechanisms measured.
    private func tuning(releaseFraction: Double) -> DSPTuning {
        var t = DSPTuning.default
        t.releaseFraction = releaseFraction
        return t
    }

    func testWhichRankerPicksTheRealSecondStrike() throws {
        let fm = FileManager.default
        let root = dataRoot()
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            throw XCTSkip("no data/raw beside this checkout")
        }
        let dirs = names.filter { $0.hasPrefix("tap_deck__") }.sorted()
        guard !dirs.isEmpty else { throw XCTSkip("no tap decks under data/raw") }

        var perSession: [(id: String, tally: Tally)] = []
        var perSurface: [String: Tally] = [:]

        for name in dirs {
            let session = try Session(directory: root.appendingPathComponent(name))
            let surface = session.meta.surface.rawValue
            let samples = try session.samples()
            let labels = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !labels.isEmpty else { continue }

            var sessionTally = Tally()
            for release in Self.releaseFractions {
                let dsp = tuning(releaseFraction: release)

                // The same filter the detector runs, so the shape samples the
                // ranker reads here are the ones it would read live.
                var chain = SignalChain(tuning: dsp)
                var shape: [GroupPrune.ShapeSample] = []
                shape.reserveCapacity(samples.count)
                for s in samples {
                    chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                  holdNoiseFloor: false)
                    shape.append(.init(tNs: s.tNs, x: chain.highPassX,
                                       y: chain.highPassY, z: chain.highPassZ))
                }

                let replay = TapDetector.replayGroups(samples: samples, inputs: [],
                                                      config: .default, tuning: dsp,
                                                      armedTapCounts: [2])
                var strengthAt: [Int64: Double] = [:]
                for o in replay.onsets { strengthAt[o.tNs] = o.strength }

                for group in replay.groups where group.tapCount >= 3
                    && group.tapOnsets.count == group.tapCount {
                    let onsets = group.tapOnsets
                    // The labelled gesture this group sits on: the one whose
                    // second onset is nearest the group's first candidate.
                    guard let label = labels.min(by: {
                        abs($0[1].tNs - onsets[0]) < abs($1[1].tNs - onsets[0])
                    }) else { continue }
                    let truth = label[1].tNs
                    let matching = onsets.indices.filter {
                        $0 > 0 && abs(onsets[$0] - truth) <= Self.matchNs
                    }
                    // A contest needs exactly one right answer to rank towards.
                    guard matching.count == 1 else { continue }
                    let answer = matching[0]

                    let strengths = onsets.map { strengthAt[$0] ?? 0 }
                    let candidates = Array(strengths.dropFirst())
                    let lo = candidates.min() ?? 0, hi = candidates.max() ?? 0
                    let amplitudeMatched = lo > 0 && hi / lo <= Self.amplitudeBand

                    sessionTally.contests += 1
                    if amplitudeMatched { sessionTally.matchedContests += 1 }
                    for (rankerName, value) in Self.rankers {
                        let kept = GroupPrune.select(onsets: onsets, strengths: strengths,
                                                     target: 2, samples: shape,
                                                     peakHoldNs: dsp.peakHoldNs, ranker: value)
                        guard kept?.contains(answer) == true else { continue }
                        sessionTally.hits[rankerName, default: 0] += 1
                        if amplitudeMatched { sessionTally.matchedHits[rankerName, default: 0] += 1 }
                    }
                }
            }

            perSession.append((session.meta.sessionId, sessionTally))
            var s = perSurface[surface] ?? Tally()
            s.add(sessionTally)
            perSurface[surface] = s
        }

        func row(_ label: String, _ tally: Tally, matched: Bool) -> String {
            let n = matched ? tally.matchedContests : tally.contests
            var out = String(format: "  %-46@ n=%3d", label as NSString, n)
            for (name, _) in Self.rankers {
                let h = (matched ? tally.matchedHits[name] : tally.hits[name]) ?? 0
                let pct = n == 0 ? 0 : 100.0 * Double(h) / Double(n)
                out += String(format: "  %@ %2d %5.1f%%", name, h, pct)
            }
            return out
        }

        var pooled = Tally()
        for s in perSurface.values { pooled.add(s) }

        print("\n  SELECTION ACCURACY — does the ranker keep the real second strike?")
        print("  recorded training data, re-arm levels \(Self.releaseFractions) "
              + "(shipped is \(DSPTuning.default.releaseFraction), which makes almost no contests)")
        print("  ALL CONTESTS")
        for s in perSession.sorted(by: { $0.id < $1.id }) { print(row(s.id, s.tally, matched: false)) }
        for (surface, s) in perSurface.sorted(by: { $0.key < $1.key }) {
            print(row("SURFACE " + surface, s, matched: false))
        }
        print(row("POOLED", pooled, matched: false))
        print("  AMPLITUDE-MATCHED CONTESTS (candidates within \(Self.amplitudeBand)x)")
        for s in perSession.sorted(by: { $0.id < $1.id }) { print(row(s.id, s.tally, matched: true)) }
        for (surface, s) in perSurface.sorted(by: { $0.key < $1.key }) {
            print(row("SURFACE " + surface, s, matched: true))
        }
        print(row("POOLED", pooled, matched: true))

        // Recorded 2026-08-14 on data/raw, 41 contests: cos_first_xy 56.1 %,
        // crest 24.4 %, crest inverted 75.6 %, decay residual 39.0 %, combined
        // 39.0 %, keep-the-latest 75.6 %, keep-the-strongest 100 %.
        //
        // Chance is 50 % — every contest here has two candidates — so the
        // strongest single statistic this project has found is a coin flip at
        // the job it was supposed to be good at, and both controls beat it. The
        // bands below are wide enough to survive noise and tight enough that a
        // change in the feature math cannot pass unnoticed.
        XCTAssertGreaterThan(pooled.contests, 20, "too few contests to say anything")
        let accuracy = { (name: String) -> Double in
            Double(pooled.hits[name] ?? 0) / Double(pooled.contests)
        }
        XCTAssertEqual(accuracy("cos_first_xy"), 0.56, accuracy: 0.12)
        XCTAssertEqual(accuracy("crest"), 0.24, accuracy: 0.12)
        XCTAssertEqual(accuracy("decay_resid"), 0.39, accuracy: 0.12)
        XCTAssertGreaterThanOrEqual(accuracy("CONTROL_last"), accuracy("cos_first_xy"),
                                    "a ranker that reads no signal is still ahead")
        XCTAssertEqual(accuracy("CONTROL_strength"), 1.0,
                       "in every contest this corpus can produce, the real second strike is "
                       + "the biggest candidate — so these contests cannot validate a SHAPE "
                       + "ranker, and a pooled number that flatters one is flattering amplitude")
    }
}
