import XCTest
@testable import TunkCore
import TunkFormat

/// What the tail model does to the deaf/weak split, and to the count each
/// labelled gesture ends up with. Diagnostic: prints, asserts only that it ran.
///
/// The second table is the one that matters. Re-arming earlier can only help if
/// the recovered onset lands as tap TWO; if the tail crosses the bar first, the
/// same gesture arrives as a three-onset group and fires nothing, which reads as
/// a detection loss even though the detector heard more.
final class TailModelDiagnosisTests: XCTestCase {
    struct Tally { var deaf = 0, weak = 0, hit = 0, two = 0, three = 0, oneOrNone = 0 }

    static func dataRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/raw").path + "/"
    }

    /// Replay every training tap deck under `config` and split each labelled
    /// two-tap gesture: was its second tap heard, and how many ungated onsets
    /// did the detector end up with across the gesture?
    static func measure(config: DetectorConfig) throws -> [String: Tally] {
        let root = dataRoot()
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()
        var tally: [String: Tally] = [:]

        for name in dirs {
            let surface = String(name.split(separator: "_").filter { !$0.isEmpty }[2])
            let session = try Session(directory: URL(fileURLWithPath: root + name))
            let samples = try session.samples()
            let groups = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !groups.isEmpty else { continue }

            let d = TapDetector(config: config)
            var armedAt: [Bool] = []; armedAt.reserveCapacity(samples.count)
            var envAt: [Double] = []; envAt.reserveCapacity(samples.count)
            var thrAt: [Double] = []; thrAt.reserveCapacity(samples.count)
            for s in samples {
                _ = d.ingest(sample: s)
                armedAt.append(d.isArmedForTesting)
                envAt.append(d.envelopeForTesting)
                thrAt.append(d.activeThreshold)
            }
            let ungated = d.drainOnsets().filter { !$0.suppressedByGate }.map(\.tNs)

            var t = tally[surface] ?? Tally()
            for g in groups {
                let first = g[0].tNs, second = g[1].tNs
                let inGesture = ungated.filter { $0 >= first - 40_000_000 && $0 <= second + 60_000_000 }
                switch inGesture.count {
                case 0, 1: t.oneOrNone += 1
                case 2: t.two += 1
                default: t.three += 1
                }

                if inGesture.contains(where: { abs($0 - second) < 60_000_000 }) { t.hit += 1; continue }
                var i = 0
                while i < samples.count, samples[i].tNs < second - 30_000_000 { i += 1 }
                var j = i, wasArmed = false, peakEnv = 0.0, barThen = 0.0
                while j < samples.count, samples[j].tNs <= second + 30_000_000 {
                    if armedAt[j] { wasArmed = true }
                    peakEnv = max(peakEnv, envAt[j]); barThen = max(barThen, thrAt[j])
                    j += 1
                }
                if !wasArmed && peakEnv >= barThen { t.deaf += 1 } else { t.weak += 1 }
            }
            tally[surface] = t
        }
        return tally
    }

    static func print(_ label: String, _ tally: [String: Tally]) {
        Swift.print("  \(label)")
        for (surface, t) in tally.sorted(by: { $0.key < $1.key }) {
            let total = t.deaf + t.weak + t.hit
            Swift.print(String(format: "    %-5@ gestures %3d  2nd seen %3d  DEAF %3d  weak %3d   |  onsets in gesture: <=1 %3d  2 %3d  >=3 %3d",
                               surface as NSString, total, t.hit, t.deaf, t.weak,
                               t.oneOrNone, t.two, t.three))
        }
    }

    func testTailModelSettingsAgainstDeafness() throws {
        var cases: [(String, DetectorConfig)] = [("OFF (shipped)", .default)]
        for (m, n, tauMs) in [(0.5, 0.0, 0), (0.3, 0.5, 0), (0.5, 0.0, 150),
                              (0.5, 0.5, 150), (1.0, 0.0, 250), (2.0, 0.0, 150)] {
            var c = DetectorConfig.default
            c.tailRearmFraction = m
            c.tailOnsetFraction = n
            c.tailDecayTauNs = Int64(tauMs) * 1_000_000
            cases.append(("rearm \(m) onset \(n) tau \(tauMs) ms", c))
        }
        for (label, config) in cases {
            Self.print(label, try Self.measure(config: config))
        }
    }
}
