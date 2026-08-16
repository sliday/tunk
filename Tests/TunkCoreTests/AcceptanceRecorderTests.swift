import XCTest
@testable import TunkCore
@testable import TunkFormat

/// The PRD's final acceptance step is a live driving test on the built app. Its
/// whole output used to be a printed hit rate, which is a self-report: a critic
/// could not re-grade it and could not see what the sensor saw.
///
/// `AcceptanceRecorder` is what turns that run into a session the corpus tools
/// read. The property these tests exist to defend is the one that makes the
/// difference between evidence and a circle: it writes MARKS, never LABELS.
final class AcceptanceRecorderTests: XCTestCase {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunk-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Caller clock, as the app's `Engine` provides it: nanoseconds since some
    /// earlier epoch, which is NOT where the session starts.
    private final class FakeClock {
        var now: Int64 = 0
        func read() -> Int64 { now }
    }

    private func makeRecorder(root: URL, category: TunkFormat.Category, expected: Int,
                              clock: FakeClock, startNs: Int64,
                              callerEpochMachNs: Int64 = 1_000_000) throws -> AcceptanceRecorder {
        try AcceptanceRecorder(
            options: .init(root: root, category: category, surface: .desk, split: .train,
                           expectedTriggers: expected,
                           notes: "unit test", toolVersion: "tunk acceptance test"),
            callerEpochMachNs: callerEpochMachNs, startNs: startNs,
            clock: { clock.read() })
    }

    /// Feeds a plausible stream: 796 Hz samples, a couple of key events, and a
    /// prompt track of `groups` beeps.
    private func drive(_ r: AcceptanceRecorder, clock: FakeClock, from startNs: Int64,
                       seconds: Double, groups: Int) {
        let step: Int64 = 1_256_000
        let count = Int(seconds * 1e9 / Double(step))
        let beepEvery = groups > 0 ? count / (groups + 1) : count + 1
        var nextBeep = beepEvery
        var group = 0
        for i in 0..<count {
            let t = startNs + Int64(i) * step
            clock.now = t
            r.ingest(sample: AccelSample(tNs: t, arrivalNs: t + 250_000,
                                         x: 0, y: 0, z: -0.9796))
            if i == 10 {
                r.ingest(input: InputRecord(tNs: t, kind: .keyDown, code: 4))
            }
            if i == 20 {
                r.ingest(input: InputRecord(tNs: t, kind: .keyUp, code: 4))
            }
            if i == nextBeep, group < groups {
                r.mark(kind: "prompt", text: "double-tap", group: group)
                r.mark(kind: "beep", group: group)
                group += 1
                nextBeep += beepEvery
            }
        }
        clock.now = startNs + Int64(count) * step
    }

    /// The artifact has to be a session, not a pile of files that resemble one.
    func testItWritesASessionTheHarnessCanRead() throws {
        let root = try scratch()
        let clock = FakeClock()
        // The caller's clock has been running for 90 s before the session starts,
        // which is exactly what happens on the second phase of a real run.
        let start: Int64 = 90_000_000_000
        let r = try makeRecorder(root: root, category: .tapDeck, expected: 3,
                                 clock: clock, startNs: start)
        r.mark(kind: "input_tap", text: "active")
        drive(r, clock: clock, from: start, seconds: 6, groups: 3)
        let summary = r.finish(reason: "test")

        let session = try Session(directory: summary.dir)
        let samples = try session.samples()
        XCTAssertEqual(samples.count, session.meta.sampleCount,
                       "meta.sample_count must match the file, or verify fails it")
        XCTAssertGreaterThan(samples.count, 4000)

        // Rebased: a session's timestamps start at its own epoch, not the
        // caller's. `duration_ns` has to agree with the accel span or the
        // harness reports a session that lasted 96 s and recorded 6.
        XCTAssertLessThan(samples[0].tNs, 2_000_000)
        XCTAssertEqual(session.meta.epochMachNs, 1_000_000 + start)
        let span = Double(samples.last!.tNs - samples.first!.tNs) / 1e9
        XCTAssertEqual(Double(session.meta.durationNs) / 1e9, span, accuracy: 1.5)

        // Monotonic, and every record the fixed width FORMAT.md freezes.
        let bytes = try Data(contentsOf: session.accelURL).count
        XCTAssertEqual(bytes % AccelSample.byteWidth, 0)
        for i in 1..<samples.count {
            XCTAssertGreaterThanOrEqual(samples[i].tNs, samples[i - 1].tNs)
        }
    }

    /// The one design rule. The test knows when it PROMPTED, not when anybody
    /// tapped; labels derived from its own triggers would grade the detector
    /// against itself, and every number taken from the session afterwards would
    /// be circular.
    func testItWritesMarksAndNeverLabels() throws {
        let root = try scratch()
        let clock = FakeClock()
        let r = try makeRecorder(root: root, category: .tapDeck, expected: 2,
                                 clock: clock, startNs: 0)
        drive(r, clock: clock, from: 0, seconds: 4, groups: 2)
        // The live detector firing must not change the answer.
        r.noteLiveTrigger(atNs: 1_500_000_000, lastOnsetNs: 1_400_000_000, tapCount: 2)
        r.noteLiveTrigger(atNs: 2_500_000_000, lastOnsetNs: 2_400_000_000, tapCount: 2)
        let summary = r.finish(reason: "test")

        let session = try Session(directory: summary.dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.labelsURL.path),
                      "labels.jsonl must exist, so the labeller has somewhere to write")
        XCTAssertEqual(try session.labels().count, 0,
                       "and must be EMPTY: ground truth comes from tunk-label reading "
                     + "the beep marks, never from what the detector fired")
        XCTAssertEqual(try Data(contentsOf: session.labelsURL).count, 0)

        let marks = try session.marks()
        XCTAssertEqual(marks.filter { $0.kind == "beep" }.count, 2)
        XCTAssertEqual(marks.filter { $0.kind == "live_trigger" }.count, 2)
        // The labeller keys on `beep` alone (Sources/TunkLabel/main.swift). A
        // live trigger sitting under any other kind cannot become ground truth.
        XCTAssertTrue(marks.filter { $0.kind == "live_trigger" }.allSatisfy { $0.group == nil },
                      "a live trigger carries no group, so it cannot be mistaken for a "
                    + "prompt the labeller should search around")
    }

    /// What `tunk-capture verify` asserts about a tap session: one beep per
    /// expected trigger, each in its own group.
    func testBeepsMatchExpectedTriggersOnATapSession() throws {
        let root = try scratch()
        let clock = FakeClock()
        let r = try makeRecorder(root: root, category: .tapDeck, expected: 4,
                                 clock: clock, startNs: 0)
        drive(r, clock: clock, from: 0, seconds: 8, groups: 4)
        let session = try Session(directory: r.finish(reason: "test").dir)

        let beeps = session.meta.category.isTapCategory
            ? try session.marks().filter { $0.kind == "beep" } : []
        XCTAssertEqual(beeps.count, session.meta.expectedTriggers)
        XCTAssertEqual(Set(beeps.compactMap(\.group)).count, beeps.count)
    }

    /// The typing phase is a different category from the tap phase, and its
    /// expectation is zero: any trigger in it is a false positive.
    func testTypingPhaseExpectsNothingToFire() throws {
        let root = try scratch()
        let clock = FakeClock()
        let r = try makeRecorder(root: root, category: .typing, expected: 0,
                                 clock: clock, startNs: 0)
        drive(r, clock: clock, from: 0, seconds: 3, groups: 0)
        let session = try Session(directory: r.finish(reason: "test").dir)

        XCTAssertEqual(session.meta.expectedTriggers, 0)
        XCTAssertFalse(session.meta.category.isTapCategory)
        XCTAssertEqual(try session.labels().count, 0)
    }

    /// The input gate is what stops typing firing Tunk. A typing recording
    /// without input events cannot be replayed honestly.
    func testInputEventsTravelWithTheSamples() throws {
        let root = try scratch()
        let clock = FakeClock()
        let start: Int64 = 5_000_000_000
        let r = try makeRecorder(root: root, category: .typing, expected: 0,
                                 clock: clock, startNs: start)
        drive(r, clock: clock, from: start, seconds: 2, groups: 0)
        let session = try Session(directory: r.finish(reason: "test").dir)

        let inputs = try session.inputs()
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.allSatisfy { $0.kind.gatesDetection })
        XCTAssertTrue(inputs.allSatisfy { $0.tNs >= 0 && $0.tNs <= session.meta.durationNs },
                      "rebased into the session window, or verify reports events "
                    + "outside it and the gate replays at the wrong moment")
    }

    /// Samples whose device timestamp predates the session start are dropped.
    /// Writing them negative would break the monotonic-and-in-range checks the
    /// harness makes.
    func testSamplesBeforeTheStartAreDroppedNotWrittenNegative() throws {
        let root = try scratch()
        let clock = FakeClock()
        let start: Int64 = 1_000_000_000
        let r = try makeRecorder(root: root, category: .typing, expected: 0,
                                 clock: clock, startNs: start)
        // Three stragglers stamped just before the session opened.
        for back in [3_000_000, 2_000_000, 1_000_000] as [Int64] {
            r.ingest(sample: AccelSample(tNs: start - back, arrivalNs: start - back,
                                         x: 0, y: 0, z: -0.98))
        }
        r.ingest(input: InputRecord(tNs: start - 4_000_000, kind: .keyDown, code: 4))
        drive(r, clock: clock, from: start, seconds: 1, groups: 0)
        let session = try Session(directory: r.finish(reason: "test").dir)

        let samples = try session.samples()
        XCTAssertTrue(samples.allSatisfy { $0.tNs >= 0 })
        XCTAssertEqual(samples.count, session.meta.sampleCount)
        XCTAssertTrue(try session.inputs().allSatisfy { $0.tNs >= 0 })
    }

    /// The end of the argument: `tunk-capture verify` is the gate every session
    /// in the corpus goes through, and a writer whose output it rejects is worth
    /// nothing. This drives the real writer and hands the result to the real
    /// binary.
    ///
    /// Skipped rather than failed when `bin/tunk-capture` is not built, so a
    /// fresh checkout does not fail on a missing artifact. Run `./bin/refresh.sh`.
    func testTheHarnessAcceptsWhatThisWrites() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TunkCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let tool = repo.appendingPathComponent("bin/tunk-capture")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path),
                          "bin/tunk-capture is not built; run ./bin/refresh.sh")

        let root = try scratch()
        let clock = FakeClock()
        let r = try makeRecorder(root: root, category: .tapDeck, expected: 3,
                                 clock: clock, startNs: 0)
        r.mark(kind: "input_tap", text: "active")
        drive(r, clock: clock, from: 0, seconds: 8, groups: 3)
        let dir = r.finish(reason: "test").dir

        let p = Process()
        p.executableURL = tool
        p.arguments = ["verify", dir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "tunk-capture verify rejected the session:\n\(text)")
        XCTAssertFalse(text.contains("FAIL"), text)
    }

    /// `finish` runs from the normal path and could run from a signal handler.
    func testFinishIsIdempotent() throws {
        let root = try scratch()
        let clock = FakeClock()
        let r = try makeRecorder(root: root, category: .typing, expected: 0,
                                 clock: clock, startNs: 0)
        drive(r, clock: clock, from: 0, seconds: 1, groups: 0)
        let first = r.finish(reason: "test")
        let second = r.finish(reason: "again")
        XCTAssertEqual(first.sampleCount, second.sampleCount)
        XCTAssertEqual(first.dir, second.dir)
        // Anything arriving after the seal is discarded rather than appended to
        // a closed file.
        r.ingest(sample: AccelSample(tNs: 9_000_000_000, arrivalNs: 9_000_000_000,
                                     x: 0, y: 0, z: -0.98))
        let session = try Session(directory: first.dir)
        XCTAssertEqual(try session.samples().count, first.sampleCount)
    }
}
