import XCTest

/// End-to-end tests for the scoring harness, `Sources/TunkScore/**`.
///
/// `TunkScore` is an executable target, so it cannot be imported. These tests
/// drive the built binary instead, which has the side benefit of testing what a
/// critic actually runs rather than a library the CLI wraps.
///
/// Build first — `swift test` alone does not build an executable the test target
/// does not depend on:
///
///     swift build --scratch-path .build-score
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --scratch-path .build-score
final class ScoreHarnessCLITests: XCTestCase {

    // MARK: - Fixtures

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/TunkCoreTests/ScoreHarnessCLITests.swift
            .deletingLastPathComponent()     // Tests/TunkCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    /// `tunk-score` sits next to the xctest bundle in the same build directory.
    private func binary() throws -> URL {
        let dir = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent()
        let exe = dir.appendingPathComponent("tunk-score")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw XCTSkip("""
            tunk-score is not built at \(exe.path).
            Run `swift build --scratch-path <same scratch path>` first; `swift test`
            does not build an executable the test target does not depend on.
            """)
        }
        return exe
    }

    @discardableResult
    private func run(_ exe: URL, _ args: [String],
                     file: StaticString = #filePath, line: UInt = #line) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func scratchDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunk-score-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (obj as? [String: Any]) ?? [:]
    }

    // MARK: - The harness grades itself

    /// `selftest` plants a known number of gestures into synthetic sessions on
    /// disk in the FORMAT.md layout and asserts the harness reports exactly what
    /// was planted. If it fails, its own output names the assertion.
    func testSelfTestPasses() throws {
        let exe = try binary()
        let dir = try scratchDir("selftest")
        let (status, out) = try run(exe, ["selftest", "--detector", "stub",
                                          "--dir", dir.appendingPathComponent("s").path])
        XCTAssertEqual(status, 0, "selftest failed:\n\(out)")
        XCTAssertTrue(out.contains("SELFTEST PASS"), out)
    }

    // MARK: - The regression: a single tap must never fire

    /// A trigger within ±150 ms of a labelled **single** tap used to claim that
    /// group, which made it "matched" and therefore not a false positive, while
    /// the detection denominator counted only `intent == double` groups. The
    /// trigger disappeared from both numbers.
    ///
    /// Fixture: `Synth.singleTapsWithBounce` plants five deliberate single taps,
    /// each preceded by a stray knock, so a double-tap detector pairs them and
    /// fires right on the labelled single onset.
    func testTriggerOnALabelledSingleTapIsCountedAsAFalseTrigger() throws {
        let exe = try binary()
        let dir = try scratchDir("singles")
        let scratch = dir.appendingPathComponent("plant")
        try run(exe, ["selftest", "--detector", "stub", "--keep", "--dir", scratch.path])

        let reportURL = dir.appendingPathComponent("run.json")
        let (_, out) = try run(exe, ["run",
                                     "--data", scratch.appendingPathComponent("counts").path,
                                     "--detector", "stub",
                                     "--json", reportURL.path])
        let report = try json(reportURL)
        let pooled = (report["pooled"] as? [String: Any]) ?? [:]

        XCTAssertEqual(pooled["triggerCount"] as? Int, 5, "planted 5 firings\n\(out)")
        XCTAssertEqual(pooled["falsePositives"] as? Int, 5,
                       "every trigger sits on a labelled single tap, which must never fire\n\(out)")
        XCTAssertEqual(pooled["armedGroups"] as? Int, 0,
                       "a labelled single tap is not a detection target while 2-tap is armed")
        XCTAssertEqual(pooled["mustNotFireGroups"] as? Int, 9, "5 singles + 4 triples")
        XCTAssertEqual(pooled["mustNotFireViolations"] as? Int, 5)

        // ...and the false triggers are attributed to the count that fired.
        let perCount = (pooled["perCount"] as? [[String: Any]]) ?? []
        let two = perCount.first { $0["count"] as? Int == 2 }
        XCTAssertEqual(two?["falseTriggers"] as? Int, 5)
        let one = perCount.first { $0["count"] as? Int == 1 }
        XCTAssertEqual(one?["labelledGroups"] as? Int, 5)
        XCTAssertEqual(one?["falseTriggers"] as? Int, 0, "nothing fired a single tap")

        // The pass line has to see it, not just the JSON.
        let checks = (report["checks"] as? [[String: Any]]) ?? []
        let failing = checks.filter { $0["status"] as? String == "fail" }
            .compactMap { $0["name"] as? String }
        XCTAssertTrue(failing.contains("false triggers per 20 min, 2-tap"), "\(failing)")
        XCTAssertTrue(failing.contains("labelled must-not-fire gestures that fired"), "\(failing)")
    }

    /// Every armed count gets its own detection rate and its own false-trigger
    /// rate, so single-tap can be judged on its own before it ships.
    func testPerTapCountMetricsSplitByArmedCount() throws {
        let exe = try binary()
        let dir = try scratchDir("counts")
        let scratch = dir.appendingPathComponent("plant")
        try run(exe, ["selftest", "--detector", "stub", "--keep", "--dir", scratch.path])

        let reportURL = dir.appendingPathComponent("run.json")
        try run(exe, ["run",
                      "--data", scratch.appendingPathComponent("counts").path,
                      "--detector", "stub", "--armed", "1,2,3",
                      "--json", reportURL.path])
        let report = try json(reportURL)
        XCTAssertEqual(report["armedCounts"] as? [Int], [1, 2, 3])

        let slices = (report["perSurfaceTapCount"] as? [[String: Any]]) ?? []
        func slice(_ surface: String, _ n: Int) -> [String: Any]? {
            slices.first { $0["label"] as? String == surface && $0["tapCount"] as? Int == n }
        }
        // Planted on desk: 5 single-tap gestures, 4 triple-tap gestures, 0
        // doubles. These are facts about the fixture and do not move.
        XCTAssertEqual(slice("desk", 1)?["labelledGroups"] as? Int, 5)
        XCTAssertEqual(slice("desk", 3)?["labelledGroups"] as? Int, 4)
        XCTAssertEqual(slice("desk", 2)?["labelledGroups"] as? Int, 0)

        // This block used to assert "the stub fires two taps, so the singles are
        // missed and the firings are false triggers charged to the 2-tap count",
        // which was only true because `--armed` never reached the detector: the
        // grader was told 1,2,3 while the detector stayed on its config's 2. The
        // override now writes config.armedTapCounts, so the stub really is armed
        // for 1, 2 and 3, and the firings land on count 1 instead.
        //
        // Asserting the stub's exact firing pattern would just re-pin whatever
        // the stub happens to do, so assert the property that must hold for any
        // detector: nothing may be charged to a count that was not armed.
        for n in [1, 2, 3] {
            XCTAssertNotNil(slice("desk", n), "armed count \(n) must appear in the breakdown")
        }
        let unarmedFalsePositives = slices
            .filter { ($0["tapCount"] as? Int).map { !(1...3).contains($0) } ?? false }
            .compactMap { $0["falsePositives"] as? Int }
            .reduce(0, +)
        XCTAssertEqual(unarmedFalsePositives, 0,
                       "a count outside the armed set must not accumulate false positives")

        // And the point of the fix: the detector genuinely fires singles now, so
        // the 2-tap count no longer collects the singles' firings.
        XCTAssertEqual(slice("desk", 2)?["falsePositives"] as? Int, 0,
                       "with 1 armed, single-tap firings belong to count 1, not count 2")
    }

    // MARK: - The progress feed

    /// `--progress-json` must produce a file `web/schema.py` accepts, or the page
    /// silently keeps showing the previous round.
    func testProgressFeedValidatesAgainstTheWebSchema() throws {
        let exe = try binary()
        let dir = try scratchDir("progress")
        let scratch = dir.appendingPathComponent("plant")
        try run(exe, ["selftest", "--detector", "stub", "--keep", "--dir", scratch.path])

        let feed = dir.appendingPathComponent("progress.json")
        let (_, out) = try run(exe, ["run",
                                     "--data", scratch.appendingPathComponent("sessions").path,
                                     "--detector", "stub", "--armed", "1,2",
                                     "--progress-json", feed.path,
                                     "--progress-label", "unit test round"])
        XCTAssertTrue(out.contains("appended round 0"), out)

        let doc = try json(feed)
        XCTAssertEqual(doc["schema"] as? Int, 2)
        let rounds = (doc["rounds"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rounds.count, 1)
        let round = rounds[0]
        for key in ["round", "label", "timestamp", "headline", "biggest_gap", "surfaces"] {
            XCTAssertNotNil(round[key], "round is missing \(key), which web/README.md requires")
        }
        let surfaces = (round["surfaces"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(surfaces.keys), ["desk", "soft", "lap"],
                       "a surface missing from the page reads as fine, and it is not")
        let desk = (surfaces["desk"] as? [String: Any]) ?? [:]
        let taps = (desk["taps"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(taps["1"], "single tap needs its own column")
        XCTAssertNotNil(taps["2"])
        XCTAssertNotNil(taps["any"])
        let stuck = ((taps["2"] as? [String: Any])?["metrics"] as? [String: Any])?["stuck_modifiers"]
        XCTAssertTrue(((stuck as? [String: Any])?["value"] as? NSNull) != nil,
                      "tunk-score never emits a key, so this must be null, never a passing zero")

        // The web owner's validator is the contract. Run it.
        let schema = repoRoot.appendingPathComponent("web/schema.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: schema.path),
                          "web/schema.py is absent; skipping the cross-check")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        py.arguments = ["python3", schema.path, feed.path]
        let pipe = Pipe()
        py.standardOutput = pipe
        py.standardError = pipe
        try py.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        py.waitUntilExit()
        XCTAssertEqual(py.terminationStatus, 0, "web/schema.py rejected the feed:\n\(text)")
    }

    /// An accidental re-run must not quietly rewrite a round the operator already
    /// read on their phone.
    func testProgressFeedRefusesToOverwriteARoundWithoutReplace() throws {
        let exe = try binary()
        let dir = try scratchDir("progress-dup")
        let scratch = dir.appendingPathComponent("plant")
        try run(exe, ["selftest", "--detector", "stub", "--keep", "--dir", scratch.path])
        let data = scratch.appendingPathComponent("sessions").path
        let feed = dir.appendingPathComponent("progress.json")

        try run(exe, ["run", "--data", data, "--detector", "stub",
                      "--progress-json", feed.path])
        let (status, out) = try run(exe, ["run", "--data", data, "--detector", "stub",
                                          "--progress-json", feed.path, "--progress-round", "0"])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(out.contains("already has round 0"), out)

        let (okStatus, _) = try run(exe, ["run", "--data", data, "--detector", "stub",
                                          "--progress-json", feed.path,
                                          "--progress-round", "0", "--progress-replace"])
        XCTAssertNotEqual(okStatus, 64, "--progress-replace should be accepted")
        let rounds = (try json(feed)["rounds"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rounds.count, 1, "replace must not append a duplicate")
    }

    /// `--armed` is the only knob that decides what may fire, so a typo in it must
    /// stop the run rather than quietly change what got measured.
    func testArmedRejectsGarbage() throws {
        let exe = try binary()
        let (status, out) = try run(exe, ["run", "--data", "data/raw", "--armed", "two"])
        XCTAssertEqual(status, 64, out)
        XCTAssertTrue(out.contains("--armed expects"), out)
    }
}
