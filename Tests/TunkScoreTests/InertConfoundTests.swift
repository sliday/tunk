import XCTest
@testable import TunkScore
import TunkCore
import TunkFormat

/// A confound session is a promise that something happened in the room. This
/// suite is here because one session in `data/raw` breaks that promise and was
/// being credited anyway: `confound_music__desk__20260813-213400__93cb8f` has a
/// p99.9 sample step of 0.0007 g, below both idle sessions (0.0014, 0.0026),
/// and zero transients. It ran 0.6 minutes and bought "0 false triggers".
final class InertConfoundTests: XCTestCase {

    private func samples(count: Int, stepG: Double) -> [AccelSample] {
        var out = [AccelSample]()
        out.reserveCapacity(count)
        for i in 0..<count {
            // Square wave: every consecutive pair differs by exactly stepG on
            // one axis, so the p99.9 has to land on it.
            let t = Int64(i) * 1_256_000
            let z = Float(i % 2 == 0 ? 1.0 : 1.0 + stepG)
            out.append(AccelSample(tNs: t, arrivalNs: t, x: 0, y: 0, z: z))
        }
        return out
    }

    func testDisturbanceMeasuresTheStepItIsGiven() {
        let d = Replay.disturbanceP999(of: samples(count: 4000, stepG: 0.01))
        XCTAssertEqual(d, 0.01, accuracy: 0.0005)
    }

    /// Short files have no p99.9 worth reading. Reporting 0 makes them inert,
    /// which is the safe direction: they are not credited either way.
    func testTooShortToJudgeReportsNoEvidence() {
        XCTAssertEqual(Replay.disturbanceP999(of: samples(count: 100, stepG: 0.05)), 0)
    }

    func testAQuietRoomLabelledConfoundIsInert() {
        var s = score(category: "confound_music", disturbance: 0.0007)
        XCTAssertTrue(s.confoundIsInert)
        s.disturbanceP999 = 0.0076          // the real music session
        XCTAssertFalse(s.confoundIsInert)
    }

    /// The floor applies to confound sessions only. A quiet idle recording is
    /// exactly what idle is supposed to be, and a quiet tap deck is a different
    /// failure that the detection rate already reports.
    func testTheFloorDoesNotTouchOtherCategories() {
        for category in ["idle", "typing", "tap_deck"] {
            XCTAssertFalse(score(category: category, disturbance: 0.0001).confoundIsInert,
                           "\(category) must not be judged against the confound floor")
        }
    }

    func testAnInertSessionIsExcludedFromTheClaimAndNamed() {
        var agg = Aggregate(label: "pooled")
        agg.add(score(category: "confound_music", disturbance: 0.0007))   // inert
        agg.add(score(category: "confound_music", disturbance: 0.0076))   // real

        XCTAssertEqual(agg.confoundSessions, 1)
        XCTAssertEqual(agg.inertConfoundSessions, 1)
        XCTAssertEqual(agg.confoundSeconds, 600, accuracy: 0.5,
                       "the inert session's minutes must not pad the denominator")

        let check = try? XCTUnwrap(PassLine.checks(for: agg, scope: "pooled")
            .first { $0.name == "false triggers, confound sessions" })
        XCTAssertEqual(check?.status, .pass)
        XCTAssertTrue(check?.actual.contains("1 inert") ?? false,
                      "the exclusion has to be visible in the report, got: \(check?.actual ?? "-")")
    }

    /// The failure this closes: every confound session inert used to read as a
    /// green pass. It has to read as no data, or a mis-recorded evening looks
    /// exactly like a passing one.
    func testAllInertReadsAsNoDataRatherThanPass() {
        var agg = Aggregate(label: "pooled")
        agg.add(score(category: "confound_music", disturbance: 0.0007))
        agg.add(score(category: "confound_handling", disturbance: 0.0001))

        let check = PassLine.checks(for: agg, scope: "pooled")
            .first { $0.name == "false triggers, confound sessions" }
        XCTAssertEqual(check?.status, .noData)
        XCTAssertTrue(check?.actual.contains("all 2 were inert") ?? false,
                      "got: \(check?.actual ?? "-")")
    }

    // MARK: -

    private func score(category: String, disturbance: Double) -> SessionScore {
        SessionScore(sessionId: "t", category: category, surface: "desk", split: "raw",
                     expectedTriggers: 0, durationSeconds: 600, sampleCount: 480_000,
                     inputCount: 0, gatingInputCount: 0, ungatedSeconds: 600,
                     gapCount: 0, largestGapNs: 0, unsortedSamples: 0, unsortedInputs: 0,
                     deliveryOrderViolations: 0, disturbanceP999: disturbance,
                     armedCounts: [2], armedGroups: 0, detectedGroups: 0,
                     ambiguousGroups: 0, mustNotFireGroups: 0, mustNotFireViolations: 0,
                     triggerCount: 0, falsePositives: 0, latencyExcluded: 0,
                     latenciesNs: [], perCount: [], groups: [], triggers: [],
                     labelIssues: [])
    }
}
