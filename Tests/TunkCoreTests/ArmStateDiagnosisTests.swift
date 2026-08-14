import XCTest
@testable import TunkCore
import TunkFormat

/// Throwaway diagnostic: for every MISSED labelled gesture, was the detector
/// disarmed when the second tap arrived, or was the tap genuinely too weak?
/// Those two have opposite fixes, and the project has been assuming the second.
final class ArmStateDiagnosisTests: XCTestCase {
    /// Recorded baseline, measured 2026-08-14 on the shipped config. These are
    /// upper bounds, not equalities: a mechanism that re-arms on a decaying tail
    /// should drive `deaf` down, and that must pass, while any change that makes
    /// the detector deafer must fail here loudly.
    func testDeafSecondTapsDoNotGrow() throws {
        let tally = try Self.tally(config: .default, label: "shipped")
        XCTAssertEqual(tally["desk"]?.deaf, 0, "a hard desk has never been deaf")
        XCTAssertLessThanOrEqual(tally["soft"]?.deaf ?? 99, 3)
        XCTAssertLessThanOrEqual(tally["lap"]?.deaf ?? 99, 12)
        // The point of the split: on soft, EVERY miss is deafness, not weakness.
        XCTAssertEqual(tally["soft"]?.weak, 0)
    }

    /// The same tally with `tailRearmNs` on at its best measured setting. Every
    /// bound here is the shipped number, so this fails the moment the mechanism
    /// stops paying for itself in the currency it was built for.
    func testTailRearmDrivesDeafnessDown() throws {
        var cfg = DetectorConfig.default
        cfg.tailRearmNs = 200_000_000
        let tally = try Self.tally(config: cfg, label: "tailRearm 200 ms")
        XCTAssertEqual(tally["desk"]?.deaf, 0)
        XCTAssertLessThanOrEqual(tally["soft"]?.deaf ?? 99, 3)
        // Was 12 with the shipped re-arm rule; measured 10 at 200 ms.
        XCTAssertLessThanOrEqual(tally["lap"]?.deaf ?? 99, 10)
        // Deafness must not have been traded for weakness: a second tap the
        // detector now hears must not be reclassified rather than recovered.
        XCTAssertEqual(tally["soft"]?.weak, 0)
        XCTAssertLessThanOrEqual(tally["lap"]?.weak ?? 99, 13)
    }

    /// data/raw in whichever checkout this test file lives in. It used to be an
    /// absolute path into the main working copy, which meant a worktree scored
    /// somebody else's bytes.
    static var rawRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TunkCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("data/raw").path + "/"
    }

    static func tally(config: DetectorConfig, label: String)
        throws -> [String: (deaf: Int, weak: Int, hit: Int)]
    {
        let root = rawRoot
        let fm = FileManager.default
        let dirs = try fm.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()

        var tally: [String: (deaf: Int, weak: Int, hit: Int)] = [:]
        for name in dirs {
            let surface = name.split(separator: "_").filter { !$0.isEmpty }[2]
            let session = try Session(directory: URL(fileURLWithPath: root + name))
            let samples = try session.samples()
            let groups = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !groups.isEmpty else { continue }

            // Replay once, recording arm-state and envelope at every sample.
            let d = TapDetector(config: config)
            var armedAt: [Bool] = []; armedAt.reserveCapacity(samples.count)
            var envAt: [Double] = []; envAt.reserveCapacity(samples.count)
            var thrAt: [Double] = []; thrAt.reserveCapacity(samples.count)
            var fired = 0
            for s in samples {
                if d.ingest(sample: s) != nil { fired += 1 }
                armedAt.append(d.isArmedForTesting)
                envAt.append(d.envelopeForTesting)
                thrAt.append(d.activeThreshold)
            }
            let onsets = Set(d.drainOnsets().filter { !$0.suppressedByGate }.map(\.tNs))

            var t = tally[String(surface)] ?? (0, 0, 0)
            for g in groups {
                let second = g[1].tNs
                // Did the detector declare an onset within +/-60 ms of tap two?
                let sawIt = onsets.contains { abs($0 - second) < 60_000_000 }
                if sawIt { t.hit += 1; continue }
                // It did not. Was it disarmed across that whole window?
                var i = 0
                while i < samples.count, samples[i].tNs < second - 30_000_000 { i += 1 }
                var j = i
                var wasArmed = false
                var peakEnv = 0.0, barThen = 0.0
                while j < samples.count, samples[j].tNs <= second + 30_000_000 {
                    if armedAt[j] { wasArmed = true }
                    peakEnv = max(peakEnv, envAt[j]); barThen = max(barThen, thrAt[j])
                    j += 1
                }
                // Deaf = never armed anywhere near tap two, AND the transient
                // was in fact big enough to have crossed had it been listening.
                if !wasArmed && peakEnv >= barThen { t.deaf += 1 } else { t.weak += 1 }
            }
            tally[String(surface)] = t
        }
        print("  [\(label)]")
        for (surface, t) in tally.sorted(by: { $0.key < $1.key }) {
            let total = t.deaf + t.weak + t.hit
            print(String(format: "  %-5@  gestures %3d   2nd tap seen %3d   DEAF %3d   weak %3d",
                         surface as NSString, total, t.hit, t.deaf, t.weak))
        }
        return tally
    }
}
