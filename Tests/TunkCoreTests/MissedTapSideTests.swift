import XCTest
@testable import TunkCore
import TunkFormat

/// Diagnostic: for every MISSED gesture, was it the FIRST tap the detector
/// never saw, or the second? Twelve mechanisms have targeted the second tap.
/// Nobody checked the split.
final class MissedTapSideTests: XCTestCase {
    /// Recorded 2026-08-14 on the shipped config. Desk and soft miss nothing;
    /// lap misses 17, and 14 of those are the SECOND tap. Held as upper bounds
    /// so a change that starts losing first taps fails loudly.
    func testMissesAreSecondTapNotFirst() throws {
        let root = "/Users/stas/Playground/tunk/data/raw/"
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()
        var tally: [String: (first: Int, second: Int, both: Int, hit: Int)] = [:]
        for name in dirs {
            let surface = String(name.split(separator: "_").filter { !$0.isEmpty }[2])
            let session = try Session(directory: URL(fileURLWithPath: root + name))
            let samples = try session.samples()
            let groups = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !groups.isEmpty else { continue }
            let d = TapDetector(config: .default)
            var fired: [Int64] = []
            for s in samples { if let t = d.ingest(sample: s) { fired.append(t.tNs) } }
            let onsets = d.drainOnsets().filter { !$0.suppressedByGate }.map(\.tNs)
            func saw(_ t: Int64) -> Bool { onsets.contains { abs($0 - t) < 60_000_000 } }

            var v = tally[surface] ?? (0, 0, 0, 0)
            for g in groups {
                // Did a trigger land on this gesture at all?
                let hit = fired.contains { abs($0 - g[1].tNs) < 300_000_000 }
                if hit { v.hit += 1; continue }
                let sawFirst = saw(g[0].tNs), sawSecond = saw(g[1].tNs)
                if !sawFirst && !sawSecond { v.both += 1 }
                else if !sawFirst { v.first += 1 }
                else if !sawSecond { v.second += 1 }
                else { v.both += 0 }   // both seen but no trigger: a grouping failure
            }
            tally[surface] = v
        }
        XCTAssertEqual(tally["desk"]?.first, 0)
        XCTAssertEqual(tally["soft"]?.first, 0)
        XCTAssertLessThanOrEqual(tally["lap"]?.first ?? 99, 3,
                                 "lap first-tap misses should not grow")
        XCTAssertLessThanOrEqual(tally["lap"]?.second ?? 99, 14)
        for (surface, v) in tally.sorted(by: { $0.key < $1.key }) {
            let missed = v.first + v.second + v.both
            print(String(format: "  %-5@  detected %3d   missed %3d  ->  FIRST tap unseen %2d   second unseen %2d   neither seen %2d   both seen but not grouped %2d",
                         surface as NSString, v.hit, missed, v.first, v.second, v.both,
                         max(0, missed - v.first - v.second - v.both)))
        }
    }
}
