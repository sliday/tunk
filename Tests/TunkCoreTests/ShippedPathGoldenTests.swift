import XCTest
@testable import TunkCore

/// A signature of what the shipped detector does to a battery of SYNTHETIC
/// gestures, recorded so that a change meant to be off by default can be shown
/// to be off.
///
/// Deliberately written against the public detector surface only, with no
/// mention of any newer knob, so this file can be checked out on an older
/// revision and run there verbatim. That is how the numbers below were
/// verified: they were recorded on the shipped path and re-run against the
/// revision before `secondTapBarFraction` existed.
final class ShippedPathGoldenTests: XCTestCase {

    private func signature(first: Double, second: Double, spacingNs: Int64) -> String {
        let t0 = SyntheticStream.leadInNs
        let stream = SyntheticStream(
            durationNs: t0 + 1_500_000_000,
            taps: [SyntheticStream.Tap(tNs: t0,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: first)),
                   SyntheticStream.Tap(tNs: t0 + spacingNs,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: second))])
        let out = TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                           config: .default)
        let onsets = out.onsets.map { String(format: "%.0f/%.4f/%@", Double($0.tNs - t0) / 1e6,
                                             $0.strength, $0.suppressedByGate ? "g" : "-") }
        let groups = out.groups.map { String(format: "%.0f/%d/%.4f/%@", Double($0.tNs - t0) / 1e6,
                                             $0.tapCount, $0.score, $0.fired ? "fired" : "-") }
        let triggers = out.triggers.map { String(format: "%.0f/%.4f", Double($0.tNs - t0) / 1e6, $0.score) }
        return "onsets[" + onsets.joined(separator: " ") + "] "
             + "groups[" + groups.joined(separator: " ") + "] "
             + "triggers[" + triggers.joined(separator: " ") + "]"
    }

    func testTheShippedPathIsUnchanged() {
        let expected: [String: String] = [
            "1.2/0.8/160": "onsets[1/0.0373/-] groups[222/1/0.0373/-] triggers[]",
            "1.2/0.9/160": "onsets[1/0.0373/-] groups[222/1/0.0373/-] triggers[]",
            "1.2/1.1/160": "onsets[1/0.0373/- 162/0.0332/-] groups[383/2/0.0332/fired] triggers[383/0.0332]",
            "1.2/1.1/400": "onsets[1/0.0373/- 402/0.0323/-] groups[222/1/0.0373/- 623/1/0.0323/-] triggers[]",
            "2.0/0.8/160": "onsets[1/0.0630/-] groups[222/1/0.0630/-] triggers[]",
            "3.0/0.8/160": "onsets[1/0.0951/-] groups[222/1/0.0951/-] triggers[]",
            "3.0/2.0/160": "onsets[1/0.0951/- 160/0.0607/-] groups[381/2/0.0607/fired] triggers[381/0.0607]",
        ]
        for (key, want) in expected.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/")
            let got = signature(first: Double(parts[0])!, second: Double(parts[1])!,
                                spacingNs: Int64(parts[2])! * 1_000_000)
            XCTAssertEqual(got, want, "fixture \(key)")
        }
    }
}
