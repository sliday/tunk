import XCTest
@testable import TunkCore
import TunkFormat

/// Re-measurement of the shelved motion gate at the RESONATOR operating point,
/// recorded 2026-08-14. It is a negative, and these tests exist so nobody
/// re-derives the sweep.
///
/// The gate (`DetectorConfig.motionGateG`) was built for "I moved my laptop and
/// it counted as a tap" and shelved at 0.030 because it separated synthetic
/// lifts and cost a loud surface four of ten deliberate doubles. The resonator
/// front end moved the whole amplitude scale afterwards (`defaultThreshold`
/// 0.032 -> 0.011), and four of the six lap false triggers it leaves sit
/// 0.5-5.3 s from any labelled tap, which is what chassis motion between
/// prompted taps would look like. So it was re-swept.
///
/// **`bulkMotion` does not see it.** The statistic is computed from the RAW
/// magnitude, upstream of the high pass and of the resonator, so the new
/// operating point did not move it at all — only the population of onsets
/// reaching the gate changed. Graded on `data/raw` at
/// `resonatorHz 40, resonatorQ 2, defaultThreshold 0.011, minThresholdG 0.002`:
///
///     motionGateG   lap detection   lap false triggers
///     0 (shipped)   73/80           6
///     0.021-0.030   73/80           5
///     0.015         3 fewer pooled  4
///     0.010         23 fewer pooled 4
///
/// One of six, free; the second one costs gestures. Signals here are REAL.
final class MotionGateAtResonatorTests: XCTestCase {

    private var rawRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // TunkCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("data/raw")
    }

    private func lapDecks() throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: rawRoot.path)
            .filter { $0.hasPrefix("tap_deck__lap__") }.sorted()
        guard !names.isEmpty else { throw XCTSkip("no lap tap decks under \(rawRoot.path)") }
        return names.map { rawRoot.appendingPathComponent($0) }
    }

    /// The operating point the resonator was graded at. Both refits are forced:
    /// a narrow band costs a broadband strike about 3x, so the bar and its
    /// sanity floor move with the stage or the detector goes deaf.
    private func operatingPoint(gate: Double) -> (DetectorConfig, DSPTuning) {
        var tuning = DSPTuning.default
        tuning.resonatorHz = 40
        tuning.resonatorQ = 2
        tuning.minThresholdG = 0.002
        var config = DetectorConfig.default
        config.defaultThreshold = 0.011
        config.motionGateG = gate
        return (config, tuning)
    }

    /// Triggers fired, and how many labelled 2-tap gestures one was matched to.
    /// The matching rule is the harness's own (`Scoring`): a trigger belongs to
    /// a group when its LAST onset is within ±150 ms of the group's last
    /// labelled onset, and each trigger can be claimed once.
    private func replayLap(gate: Double) throws -> (triggers: Int, heard: Int, groups: Int) {
        var triggers = 0, heard = 0, groups = 0
        let (config, tuning) = operatingPoint(gate: gate)
        for dir in try lapDecks() {
            let session = try Session(directory: dir)
            let samples = try session.samples()
            let labelled = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !labelled.isEmpty else { continue }
            let d = TapDetector(config: config, tuning: tuning)
            var fired: [Trigger] = []
            for s in samples { if let t = d.ingest(sample: s) { fired.append(t) } }
            triggers += fired.count
            groups += labelled.count

            var claimed = [Bool](repeating: false, count: fired.count)
            for g in labelled {
                let last = g[1].tNs
                let best = fired.indices
                    .filter { !claimed[$0] && abs((fired[$0].tapOnsets.last ?? fired[$0].tNs) - last)
                                <= 150_000_000 }
                    .min { abs((fired[$0].tapOnsets.last ?? fired[$0].tNs) - last)
                             < abs((fired[$1].tapOnsets.last ?? fired[$1].tNs) - last) }
                if let i = best { claimed[i] = true; heard += 1 }
            }
        }
        return (triggers, heard, groups)
    }

    /// The whole result, end to end. A gate above every lap gesture's own
    /// bulk motion removes exactly ONE of the lap triggers and costs nothing;
    /// every lower value that removes a second one also stops a real gesture
    /// from being heard.
    func testTheGateRemovesOneLapTriggerAndThenStartsEatingGestures() throws {
        let off = try replayLap(gate: 0)
        XCTAssertEqual(off.groups, 80, "the lap corpus is four decks of twenty")
        XCTAssertEqual(off.heard, 73, "lap detection at the resonator operating point")

        let free = try replayLap(gate: 0.021)
        XCTAssertEqual(free.triggers, off.triggers - 1,
                       "0.021 should remove exactly one lap trigger")
        XCTAssertEqual(free.heard, off.heard,
                       "and it must cost no gesture: that is the only reason to look at it")

        // Anything strong enough to remove a second one is already deaf.
        for gate in [0.016, 0.014, 0.012, 0.010, 0.008] {
            let r = try replayLap(gate: gate)
            print(String(format: "  gate %.3f  triggers %3d  gestures heard %2d/%d",
                         gate, r.triggers, r.heard, r.groups))
            if r.triggers <= off.triggers - 2 {
                XCTAssertLessThan(r.heard, off.heard,
                                  "a gate at \(gate) removed a second trigger for free, "
                                  + "which the 2026-08-14 sweep says is impossible")
            }
        }
    }

    /// Why it cannot do better: measured at the crossing of every onset the
    /// detector declared, `bulkMotion` at the spurious triggers sits INSIDE the
    /// distribution at real lap taps rather than above it.
    ///
    /// Recorded 2026-08-14, lap, max over the two onsets of a group:
    ///
    ///     real detections n=73   p05 0.0018  p50 0.0054  p95 0.0106  max 0.0153
    ///     the six false   n= 6       0.0060  0.0063  0.0073  0.0076  0.0108  0.0364
    ///
    /// Five of the six sit between the real p60 and the real p96. Only the
    /// sixth clears the whole distribution, and that one is the trigger the
    /// gate at 0.021 removes.
    func testSpuriousOnsetsAreNotWhereTheChassisMoved() throws {
        var onLabel: [Double] = []
        var offLabel: [Double] = []
        let (config, tuning) = operatingPoint(gate: 0)

        for dir in try lapDecks() {
            let session = try Session(directory: dir)
            let samples = try session.samples()
            let labels = try session.labelGroups().flatMap { $0 }.map(\.tNs)
            guard !samples.isEmpty, !labels.isEmpty else { continue }

            let d = TapDetector(config: config, tuning: tuning)
            for s in samples { _ = d.ingest(sample: s) }
            let onsets = Set(d.drainOnsets().filter { !$0.suppressedByGate }.map(\.tNs))

            // Second pass for the statistic itself: `bulkMotion` is not logged
            // per onset, so replay the chain and read it at the same samples.
            var chain = SignalChain(tuning: tuning)
            for s in samples {
                chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                              holdNoiseFloor: false)
                guard onsets.contains(s.tNs) else { continue }
                let nearest = labels.map { abs($0 - s.tNs) }.min() ?? .max
                if nearest < 60_000_000 { onLabel.append(chain.bulkMotion) }
                else if nearest > 150_000_000 { offLabel.append(chain.bulkMotion) }
            }
        }

        func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted()
            return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
        }
        XCTAssertGreaterThan(onLabel.count, 100, "expected the real lap taps to dominate")
        XCTAssertGreaterThanOrEqual(offLabel.count, 3, "expected some onsets far from any label")
        print(String(format: "  bulkMotion on labelled taps n=%d  p05 %.5f p50 %.5f p95 %.5f max %.5f",
                     onLabel.count, pct(onLabel, 0.05), pct(onLabel, 0.5),
                     pct(onLabel, 0.95), onLabel.max() ?? 0))
        print(String(format: "  bulkMotion far from a label n=%d  p50 %.5f max %.5f",
                     offLabel.count, pct(offLabel, 0.5), offLabel.max() ?? 0))

        // The load-bearing claim: the typical onset far from a label is no more
        // "moving" than the typical real tap. If this ever flips, the gate is
        // worth re-sweeping and this test is the place that says so.
        XCTAssertLessThan(pct(offLabel, 0.5), pct(onLabel, 0.95),
                          "spurious onsets separated on bulk motion; re-sweep the gate")
    }

    /// The gate still ships OFF, and nothing here proposes changing that:
    /// 6 lap false triggers to 5 is 13.08 to 10.90 per 20 min against a bar of
    /// under 1, on training data, from a single event.
    func testTheGateStillShipsOff() {
        XCTAssertEqual(DetectorConfig.default.motionGateG, 0, accuracy: 1e-9)
    }
}
