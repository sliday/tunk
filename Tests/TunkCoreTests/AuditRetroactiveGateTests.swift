import XCTest
@testable import TunkCore

/// The retroactive gate reaches back `preGateNs` (25 ms), but an onset is
/// published to `drainOnsets()` after `peakHoldNs` (12 ms). A keystroke that
/// lands in the 12...25 ms band after the crossing still clears the group, yet
/// a consumer that drains every sample has already taken the onset as clear.
final class AuditRetroactiveGateTests: XCTestCase {

    private func doubleWithLateKeystroke() -> (samples: [AccelSample], inputs: [InputEvent]) {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let samples = stream.samples()
        // Place the keystroke relative to the DETECTED second crossing so it sits
        // squarely inside the band regardless of where the crossing lands.
        let clean = TapDetector.replay(samples: samples, inputs: [])
        XCTAssertEqual(clean.onsets.count, 2)
        XCTAssertEqual(clean.triggers.count, 1)
        let second = clean.onsets[1].tNs
        let lateNs = (DSPTuning.default.peakHoldNs + DSPTuning.default.preGateNs) / 2
        XCTAssertGreaterThan(lateNs, DSPTuning.default.peakHoldNs)
        XCTAssertLessThan(lateNs, DSPTuning.default.preGateNs)
        return (samples, [InputEvent(tNs: second + lateNs, kind: .keyDown, code: 4)])
    }

    func testReplayHelperKeepsTheRetroactiveGateFlagOnAPublishedOnset() {
        let (samples, inputs) = doubleWithLateKeystroke()
        let result = TapDetector.replay(samples: samples, inputs: inputs)

        XCTAssertTrue(result.triggers.isEmpty, "the retroactive gate clears the group")
        XCTAssertEqual(result.onsets.count, 2)
        XCTAssertFalse(result.onsets[0].suppressedByGate)
        XCTAssertTrue(result.onsets[1].suppressedByGate,
                      "a per-sample drain must see the retracted onset as suppressed")
    }

    func testUndrainedDetectorAlsoKeepsTheFlag() {
        let (samples, inputs) = doubleWithLateKeystroke()
        let detector = TapDetector(config: .default)
        var triggers: [Trigger] = []
        var j = 0
        for s in samples {
            while j < inputs.count, inputs[j].tNs <= s.tNs {
                detector.ingest(input: inputs[j]); j += 1
            }
            if let t = detector.ingest(sample: s) { triggers.append(t) }
        }
        let onsets = detector.drainOnsets()

        XCTAssertTrue(triggers.isEmpty)
        XCTAssertEqual(onsets.count, 2)
        XCTAssertTrue(onsets[1].suppressedByGate)
    }
}
