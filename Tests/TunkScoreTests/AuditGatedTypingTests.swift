import XCTest
@testable import TunkScore
import TunkCore
import TunkFormat

/// "Zero false triggers while typing" is only evidence for the seconds in which
/// the input gate let the detector fire. A typing session whose keystrokes
/// shadow the whole recording gives the detector no chance to misfire, so its
/// zero says nothing. The pass line printed the un-gated seconds but did not
/// consult them: 0.0 min un-gated still read as a pass.
final class AuditGatedTypingTests: XCTestCase {

    func testFullyGatedTypingSessionIsNotEvidenceOfZeroFalseTriggers() {
        var agg = Aggregate(label: "desk")
        agg.add(typing(durationSeconds: 51, ungatedSeconds: 0))

        let check = PassLine.checks(for: agg, scope: "desk")
            .first { $0.name == "false triggers, typing sessions" }
        XCTAssertEqual(check?.status, .noData,
                       "0 s of un-gated exposure cannot pass, got: \(check?.actual ?? "-")")
        XCTAssertTrue(check?.actual.contains("un-gated") ?? false,
                      "the report has to say why, got: \(check?.actual ?? "-")")
    }

    func testTypingSessionWithMeaningfulExposureStillPasses() {
        var agg = Aggregate(label: "desk")
        agg.add(typing(durationSeconds: 51, ungatedSeconds: 8))

        let check = PassLine.checks(for: agg, scope: "desk")
            .first { $0.name == "false triggers, typing sessions" }
        XCTAssertEqual(check?.status, .pass, "got: \(check?.actual ?? "-")")
    }

    // MARK: -

    private func typing(durationSeconds: Double, ungatedSeconds: Double) -> SessionScore {
        SessionScore(sessionId: "t", category: "typing", surface: "desk", split: "raw",
                     expectedTriggers: 0, durationSeconds: durationSeconds,
                     sampleCount: Int(durationSeconds * 796),
                     inputCount: 510, gatingInputCount: 510, ungatedSeconds: ungatedSeconds,
                     gapCount: 0, largestGapNs: 0, unsortedSamples: 0, unsortedInputs: 0,
                     deliveryOrderViolations: 0, disturbanceP999: 0.01,
                     armedCounts: [2], armedGroups: 0, detectedGroups: 0,
                     ambiguousGroups: 0, mustNotFireGroups: 0, mustNotFireViolations: 0,
                     triggerCount: 0, falsePositives: 0, latencyExcluded: 0,
                     latenciesNs: [], perCount: [], groups: [], triggers: [],
                     labelIssues: [])
    }
}
