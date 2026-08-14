import XCTest
@testable import TunkCore
import TunkFormat
import TunkLabelCore

/// Facts about GROUND TRUTH, not about the detector.
///
/// Round 26 audited the six lap false triggers the resonator front end produces
/// and found that four of them are properties of `labels.jsonl`, not of
/// `TapDetector`. These tests pin the three claims that audit rests on, so a
/// later round cannot quietly relabel the corpus and make the finding evaporate.
/// No detector runs here at all.
///
/// Full write-up: `notes/LAP_FALSE_TRIGGERS.md`.
final class LabelCoverageTests: XCTestCase {
    /// `data/raw`, resolved from this file so the tests read the corpus in
    /// whatever worktree they are running in rather than a hard-coded checkout.
    private var rawRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TunkCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("data/raw")
    }

    private func lapTapDecks() throws -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rawRoot.path) else {
            throw XCTSkip("no corpus at \(rawRoot.path)")
        }
        let dirs = names.filter { $0.hasPrefix("tap_deck__lap__") }.sorted()
        guard !dirs.isEmpty else { throw XCTSkip("no lap tap decks under \(rawRoot.path)") }
        return try dirs.map { try Session(directory: rawRoot.appendingPathComponent($0)) }
    }

    // MARK: - 1. The labelled interval, not the tap, is what the detector loses to

    /// Every gesture the detector misses on the training corpus is one whose
    /// LABELLED inter-tap interval lies outside the join window, and no gesture
    /// labelled inside the window is ever missed.
    ///
    /// Measured at the resonator operating point (`resonatorHz 40, resonatorQ 2,
    /// defaultThreshold 0.011, minThresholdG 0.002`) over `data/raw`:
    ///
    ///     session   groups   labelled gap outside window   missed   loose credits
    ///     13e15a      20                14                   4            6
    ///     ad3fd3      20                 1                   1            0
    ///     3fee5b      20                 3                   2            1
    ///     a4a257      20                 0                   0            0
    ///
    /// The session that scores 20/20 is the one with no out-of-window labels.
    /// This test pins the label side of that table; it does not re-run the
    /// detector, because the point is that the label distribution alone
    /// predicts the score.
    func testOutOfJoinWindowLabelsAreConcentratedInOneLapSession() throws {
        let cfg = DetectorConfig.default
        var perSession: [(String, Int, Int)] = []
        for session in try lapTapDecks() {
            let groups = try session.labelGroups().filter { $0.count >= 2 }
            let outside = groups.filter { g in
                let gap = g[g.count - 1].tNs - g[0].tNs
                return gap < cfg.minInterTapNs || gap > cfg.maxInterTapNs
            }.count
            let id = String(session.meta.sessionId.suffix(6))
            perSession.append((id, groups.count, outside))
            print(String(format: "  %@  %2d groups, %2d labelled outside [%.0f, %.0f] ms",
                         id as NSString, groups.count, outside,
                         Double(cfg.minInterTapNs) / 1e6, Double(cfg.maxInterTapNs) / 1e6))
        }

        let total = perSession.reduce(0) { $0 + $1.2 }
        let groups = perSession.reduce(0) { $0 + $1.1 }
        XCTAssertEqual(groups, 80, "the lap corpus is 80 labelled double taps")
        XCTAssertEqual(total, 18, "18 of 80 lap gestures are labelled outside the join window")

        // Not spread evenly: one session carries 14 of the 18. Posture is a
        // hidden variable and this is where it shows up in the ground truth.
        let worst = perSession.max { $0.2 < $1.2 }!
        XCTAssertEqual(worst.0, "13e15a")
        XCTAssertGreaterThanOrEqual(worst.2, 14)

        // And one lap session has none at all, which is why it scores 20/20.
        XCTAssertTrue(perSession.contains { $0.0 == "a4a257" && $0.2 == 0 })
    }

    // MARK: - 2. Ground truth only exists inside a beep window

    /// `TunkLabel.analyse` iterates `marks` where `kind == "beep"` and searches
    /// only `[beep, beep + 2600 ms]`. Anything the operator does outside those
    /// windows cannot be labelled, so a detector that fires there is scored a
    /// false trigger with no route to credit.
    ///
    /// Measured: the four lap tap decks are 5.95 minutes long and the beep
    /// windows cover 3.47 of them. 41.7 % of the recording the detector is
    /// graded on has no ground truth by construction.
    func testBeepWindowsCoverLessThanTwoThirdsOfEachLapSession() throws {
        let windowNs: Int64 = 2_600_000_000    // TunkLabel's `windowNs` default
        var coveredNs: Int64 = 0
        var totalNs: Int64 = 0
        for session in try lapTapDecks() {
            let beeps = try session.marks().filter { $0.kind == "beep" }
                .map(\.tNs).sorted()
            XCTAssertEqual(beeps.count, 20, "every lap deck prompts 20 gestures")

            var merged: [(Int64, Int64)] = []
            for b in beeps {
                if let last = merged.last, b <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, b + windowNs)
                } else {
                    merged.append((b, b + windowNs))
                }
            }
            let covered = merged.reduce(Int64(0)) { $0 + ($1.1 - $1.0) }
            let span = session.meta.durationNs
            coveredNs += covered
            totalNs += span
            let frac = Double(covered) / Double(span)
            print(String(format: "  %@  labelled %.1f s of %.1f s (%.1f %%)",
                         String(session.meta.sessionId.suffix(6)) as NSString,
                         Double(covered) / 1e9, Double(span) / 1e9, frac * 100))
            XCTAssertLessThan(frac, 0.62, "no lap deck is more than 62 % labelled")
        }
        let overall = Double(coveredNs) / Double(totalNs)
        XCTAssertGreaterThan(overall, 0.55)
        XCTAssertLessThan(overall, 0.60)
    }

    /// The concrete instance: `ad3fd3` opens with two clean transients 166 ms
    /// apart, 170 ms BEFORE its first beep, while the resting attitude never
    /// moves. That is a double tap by every measure the corpus has, and the
    /// labeller cannot see it because no beep has happened yet. The detector
    /// fires on it and is charged a false trigger.
    func testAd3fd3HasAnUnlabelledDoubleTapBeforeItsFirstBeep() throws {
        let session = try lapTapDecks().first { $0.meta.sessionId.hasSuffix("ad3fd3") }!
        let samples = try session.samples()
        let firstBeep = try session.marks().filter { $0.kind == "beep" }.map(\.tNs).min()!

        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let floor = picker.noiseFloor(env)
        // Everything before the first beep: territory `TunkLabel` never inspects.
        let found = picker.peaks(in: samples, env: env, floor: floor,
                                from: 0, to: firstBeep)
            .sorted { $0.tNs < $1.tNs }

        let cfg = DetectorConfig.default
        var pair: (Peak, Peak)?
        for (i, a) in found.enumerated() {
            for b in found[(i + 1)...] {
                let gap = b.tNs - a.tNs
                if gap >= cfg.minInterTapNs, gap <= cfg.maxInterTapNs,
                   a.amplitude >= 0.03, b.amplitude >= 0.03 {
                    pair = (a, b); break
                }
            }
            if pair != nil { break }
        }
        let p = try XCTUnwrap(pair, "expected an unlabelled tap pair before the first beep")
        print(String(format: "  unlabelled pair at %.3f s and %.3f s, %.0f ms apart, %.4f / %.4f g",
                     Double(p.0.tNs) / 1e9, Double(p.1.tNs) / 1e9,
                     Double(p.1.tNs - p.0.tNs) / 1e6, p.0.amplitude, p.1.amplitude))
        XCTAssertLessThan(p.1.tNs, firstBeep, "the pair is entirely before the first beep")
        // Lap taps in this corpus run 0.038-0.048 g. This is one of them.
        XCTAssertGreaterThan(p.0.amplitude, 0.035)
        XCTAssertGreaterThan(p.1.amplitude, 0.035)
    }

    // MARK: - 3. One false trigger really is the machine being moved

    /// `13e15a` ends with the operator moving the chassis: the resting magnitude
    /// climbs from 0.980 g to 1.211 g over the last second and the broadband
    /// envelope ramps monotonically to 0.148 g, three times any lap tap in the
    /// corpus. The detector's last trigger sits inside that ramp.
    ///
    /// Recorded so that a future motion discriminator has a named target, and so
    /// nobody re-classifies this one as a labelling gap. `bulkMotion` at
    /// 0.025 g does NOT suppress it — measured, see `notes/LAP_FALSE_TRIGGERS.md`.
    func test13e15aEndsWithAChassisMoveNotATap() throws {
        let session = try lapTapDecks().first { $0.meta.sessionId.hasSuffix("13e15a") }!
        let samples = try session.samples()
        let lastLabel = try session.labelGroups().flatMap { $0 }.map(\.tNs).max()!
        let fireNs: Int64 = 92_237_860_125     // the sixth false trigger

        XCTAssertGreaterThan(fireNs - lastLabel, 5_000_000_000,
                             "this fires more than 5 s after the last labelled gesture")

        func meanMagnitude(from: Int64, to: Int64) -> Double {
            let win = samples.filter { $0.tNs >= from && $0.tNs < to }
            guard !win.isEmpty else { return 0 }
            return win.reduce(0.0) { acc, s in
                acc + (Double(s.x) * Double(s.x) + Double(s.y) * Double(s.y)
                       + Double(s.z) * Double(s.z)).squareRoot()
            } / Double(win.count)
        }

        let settled = meanMagnitude(from: fireNs - 2_000_000_000, to: fireNs - 1_000_000_000)
        let during = meanMagnitude(from: fireNs, to: fireNs + 250_000_000)
        print(String(format: "  resting |a| %.4f g before, %.4f g during the fire", settled, during))
        XCTAssertEqual(settled, 0.980, accuracy: 0.01, "the machine is at rest a second earlier")
        XCTAssertGreaterThan(during - settled, 0.15,
                             "the gravity vector swings: the chassis is being moved")
    }
}
