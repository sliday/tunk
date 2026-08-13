import XCTest

/// End-to-end tests for the `tunk-capture` command line.
///
/// These drive the real binary rather than a copy of its parser, because the
/// failure being guarded against is an operator typing a command and the tool
/// doing something else. An earlier build accepted any `--word` it was handed:
/// `guide --category typing --duration 60` silently recorded all twelve phases
/// at their default lengths, which cost an hour of recording. Every case below
/// asserts the tool refuses loudly instead.
final class CaptureCLITests: XCTestCase {

    // MARK: - Harness

    struct Run {
        var status: Int32
        var out: String
        var err: String
        var all: String { out + err }
    }

    /// The `tunk-capture` built alongside this test bundle.
    static let binary: URL? = {
        let here = Bundle(for: CaptureCLITests.self).bundleURL.deletingLastPathComponent()
        let candidates = [here.appendingPathComponent("tunk-capture"),
                          repoRoot.appendingPathComponent("bin/tunk-capture")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TunkCoreTests/CaptureCLITests.swift
            .deletingLastPathComponent()         // Tests/TunkCoreTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // repo
    }

    @discardableResult
    func capture(_ args: [String], stdin: String? = nil, stdinAfter: Double = 0,
                 file: StaticString = #filePath, line: UInt = #line) throws -> Run {
        guard let bin = CaptureCLITests.binary else {
            throw XCTSkip("tunk-capture was not built next to the test bundle")
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = CaptureCLITests.repoRoot
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = i
        // Drain both pipes off-thread; a full pipe buffer would deadlock the child.
        var outData = Data(), errData = Data()
        let lock = NSLock()
        o.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); outData.append(d); lock.unlock()
        }
        e.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); errData.append(d); lock.unlock()
        }
        try p.run()
        if let stdin {
            DispatchQueue.global().asyncAfter(deadline: .now() + stdinAfter) {
                try? i.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            }
        }
        p.waitUntilExit()
        // Give the readability handlers a moment to drain the tail.
        Thread.sleep(forTimeInterval: 0.1)
        o.fileHandleForReading.readabilityHandler = nil
        e.fileHandleForReading.readabilityHandler = nil
        try? i.fileHandleForWriting.close()
        lock.lock(); defer { lock.unlock() }
        return Run(status: p.terminationStatus,
                   out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }

    func assertRejected(_ args: [String], mentioning needles: [String],
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try capture(args)
        XCTAssertNotEqual(r.status, 0,
                          "`tunk-capture \(args.joined(separator: " "))` was accepted:\n\(r.all)",
                          file: file, line: line)
        for needle in needles {
            XCTAssertTrue(r.all.contains(needle),
                          "error text does not mention '\(needle)':\n\(r.all)",
                          file: file, line: line)
        }
    }

    // MARK: - Unknown flags

    /// The exact command from the bad recording plan. It must not start a run.
    func testGuideRejectsRecordOnlyCategoryFlag() throws {
        try assertRejected(["guide", "--category", "typing", "--surface", "desk", "--duration", "60"],
                           mentioning: ["unknown flag --category", "--only"])
    }

    func testUnknownFlagSuggestsTheNearestRealOne() throws {
        try assertRejected(["record", "--catgory", "typing", "--surface", "desk"],
                           mentioning: ["unknown flag --catgory", "Did you mean --category"])
    }

    func testUnknownFlagListsWhatTheSubcommandAccepts() throws {
        let r = try capture(["guide", "--surface", "desk", "--only", "typing", "--nonsense", "1"])
        XCTAssertNotEqual(r.status, 0)
        for expected in ["--only", "--taps", "--typing-sec", "--duration", "--out"] {
            XCTAssertTrue(r.all.contains(expected), "help text is missing \(expected):\n\(r.all)")
        }
    }

    func testFlagBelongingToAnotherSubcommandSaysSo() throws {
        try assertRejected(["record", "--category", "typing", "--surface", "desk", "--taps", "20"],
                           mentioning: ["unknown flag --taps", "`guide`"])
    }

    func testPositionalArgumentIsRejected() throws {
        try assertRejected(["record", "--category", "typing", "--surface", "desk", "300"],
                           mentioning: ["no positional argument"])
    }

    // MARK: - Values

    func testValueFlagWithNoValueIsRejected() throws {
        try assertRejected(["guide", "--surface", "desk", "--taps"],
                           mentioning: ["--taps needs a value"])
    }

    /// `--taps --surface desk` used to record zero taps. The next token is a flag,
    /// so it is a missing value, not a value.
    func testValueFlagFollowedByAnotherFlagIsRejected() throws {
        try assertRejected(["guide", "--taps", "--surface", "desk"],
                           mentioning: ["--taps needs a value"])
    }

    func testNonNumericValueIsRejected() throws {
        try assertRejected(["guide", "--surface", "desk", "--only", "typing", "--duration", "abc"],
                           mentioning: ["--duration expects a number"])
    }

    func testUnknownCategoryInOnlyIsRejected() throws {
        try assertRejected(["guide", "--surface", "desk", "--only", "tap_dekc"],
                           mentioning: ["unknown category", "tap_dekc"])
    }

    func testUnknownSurfaceIsRejected() throws {
        try assertRejected(["guide", "--surface", "table"],
                           mentioning: ["unknown surface"])
    }

    // MARK: - --duration on guide

    func testDurationOverridesEveryTimedPhase() throws {
        let r = try capture(["guide", "--surface", "desk", "--duration", "7",
                             "--only", "typing,trackpad,idle", "--dry-run"])
        XCTAssertEqual(r.status, 0, r.all)
        let phaseLines = r.all.components(separatedBy: "\n")
            .filter { $0.range(of: "^ +[0-9]+\\. ", options: .regularExpression) != nil }
        XCTAssertEqual(phaseLines.count, 3, r.all)
        for l in phaseLines {
            XCTAssertTrue(l.hasSuffix("7 s"), "phase was not set to 7 s: '\(l)'")
        }
    }

    func testDurationConflictsWithPerPhaseFlags() throws {
        try assertRejected(["guide", "--surface", "desk", "--only", "typing",
                            "--duration", "5", "--typing-sec", "9"],
                           mentioning: ["--duration", "--typing-sec"])
    }

    /// `--duration` cannot change a prompted tap phase, so asking for it is a
    /// mistake worth naming rather than ignoring.
    func testDurationOnTapOnlyRunNamesTapsInstead() throws {
        try assertRejected(["guide", "--surface", "desk", "--only", "tap_deck", "--duration", "30"],
                           mentioning: ["--taps"])
    }

    func testTapsWithNoTapPhaseIsRejected() throws {
        try assertRejected(["guide", "--surface", "desk", "--only", "typing", "--taps", "20"],
                           mentioning: ["--taps only applies"])
    }

    func testPhaseLengthFlagWithNoMatchingPhaseIsRejected() throws {
        try assertRejected(["guide", "--surface", "desk", "--only", "typing", "--confound-sec", "90"],
                           mentioning: ["--confound-sec only applies"])
    }

    // MARK: - verify

    func testVerifyAllReportsAnEmptyRootInsteadOfPassing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tunk-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try capture(["verify", "--out", dir.path, "--all"])
        XCTAssertNotEqual(r.status, 0, r.all)
        XCTAssertTrue(r.all.contains("no sessions found"), r.all)
    }

    // MARK: - The recording plan itself

    /// Every command in notes/RECORDING_PLAN.md, run as written with `--dry-run`
    /// appended. The plan is what the operator follows; if it drifts away from the
    /// CLI again, this fails instead of an hour of recording.
    func testEveryCommandInTheRecordingPlanRuns() throws {
        let planURL = CaptureCLITests.repoRoot.appendingPathComponent("notes/RECORDING_PLAN.md")
        let text = try String(contentsOf: planURL, encoding: .utf8)
        let commands = CaptureCLITests.captureCommands(inShell: text)
        XCTAssertGreaterThan(commands.count, 10, "found almost no commands in RECORDING_PLAN.md")

        var checked = 0
        for argv in commands {
            guard let sub = argv.first else { continue }
            // doctor and verify touch the sensor or the dataset; the flags are still
            // validated, but only guide/record can be dry-run to completion.
            guard sub == "guide" || sub == "record" else {
                let r = try capture(argv + ["--help"])
                XCTAssertEqual(r.status, 0, "RECORDING_PLAN command `\(argv.joined(separator: " "))` "
                               + "names an unknown subcommand:\n\(r.all)")
                checked += 1
                continue
            }
            let r = try capture(argv + ["--dry-run"])
            XCTAssertEqual(r.status, 0,
                           "RECORDING_PLAN command failed:\n  tunk-capture \(argv.joined(separator: " "))\n\(r.all)")
            checked += 1
        }
        XCTAssertEqual(checked, commands.count)
    }

    /// Pull `tunk-capture ...` invocations out of the plan's shell blocks, joining
    /// continuation lines and expanding the one shell variable it defines.
    static func captureCommands(inShell text: String) -> [[String]] {
        var vars = [String: String]()
        var joined = [[String]]()
        var pending = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\\") {
                pending += String(line.dropLast()) + " "
                continue
            }
            let full = pending + line
            pending = ""
            if let m = full.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) {
                let name = String(full[m.lowerBound..<full.index(before: m.upperBound)])
                vars[name] = String(full[m.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                continue
            }
            guard let r = full.range(of: "tunk-capture ") else { continue }
            let tail = String(full[r.upperBound...])
            var argv = [String]()
            for token in tail.split(separator: " ").map(String.init) where !token.isEmpty {
                if token.hasPrefix("$") {
                    argv += (vars[String(token.dropFirst())] ?? "").split(separator: " ").map(String.init)
                } else {
                    argv.append(token)
                }
            }
            if !argv.isEmpty { joined.append(argv) }
        }
        return joined
    }
}
