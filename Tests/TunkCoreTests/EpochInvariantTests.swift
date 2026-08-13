import CoreGraphics
import TunkCore
import TunkFormat
import XCTest

/// One epoch, one timebase, four files.
///
/// FORMAT.md says every `t_ns` in `accel.bin`, `input.jsonl`, `marks.jsonl` and
/// `labels.jsonl` is nanoseconds since `meta.json → epoch_mach_ns`. Nothing in a
/// recorded session announces a broken epoch: the files still parse, the labeller
/// still runs, and every label lands on the wrong sample. So this records a real
/// short session and cross-checks the four streams against each other.
final class EpochInvariantTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tunk-epoch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    func testEveryStreamSharesTheSessionEpoch() throws {
        let cli = CaptureCLITests()
        let seconds = 3.0

        // A line on stdin becomes an operator_mark stamped from the same clock the
        // sensor callback uses, which is the cross-check this test is built on.
        let markText = "epoch probe"
        let posted = expectation(description: "input event posted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            // A mouse move to where the cursor already is: visible to the event
            // tap, invisible to the operator.
            let at = CGEvent(source: nil)?.location ?? .zero
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at,
                    mouseButton: .left)?.post(tap: .cgSessionEventTap)
            posted.fulfill()
        }

        let run = try cli.capture(["record", "--category", "idle", "--surface", "desk",
                                   "--out", tmp.path, "--duration", "\(Int(seconds))",
                                   "--allow-no-input"],
                                  stdin: markText + "\n", stdinAfter: 1.0)
        wait(for: [posted], timeout: 10)
        XCTAssertEqual(run.status, 0, run.all)

        let dirs = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
        XCTAssertEqual(dirs.count, 1, "expected exactly one session directory:\n\(run.all)")
        let session = try Session(directory: try XCTUnwrap(dirs.first))
        let meta = session.meta

        // meta
        XCTAssertGreaterThan(meta.epochMachNs, 0, "epoch_mach_ns is not a mach timestamp")
        XCTAssertEqual(Double(meta.durationNs) / 1e9, seconds, accuracy: 1.0)

        // accel.bin
        let samples = try session.samples()
        try XCTSkipIf(samples.count < 100,
                      "the accelerometer delivered \(samples.count) samples; no sensor on this host")
        XCTAssertEqual(samples.count, meta.sampleCount)
        let firstNs = samples.first!.tNs
        let lastNs = samples.last!.tNs
        // Relative to the epoch, not absolute mach time. An absolute value here is
        // the classic epoch bug and would be many orders of magnitude larger.
        XCTAssertLessThan(firstNs, 1_000_000_000,
                          "first sample is \(firstNs) ns after the epoch; accel.bin is not epoch-relative")
        XCTAssertGreaterThanOrEqual(firstNs, 0)
        XCTAssertLessThanOrEqual(lastNs, meta.durationNs)
        XCTAssertEqual(Double(lastNs - firstNs) / 1e9, seconds, accuracy: 1.0)
        // arrival_ns is the same clock, a hair after the device timestamp.
        for s in [samples.first!, samples[samples.count / 2], samples.last!] {
            XCTAssertGreaterThanOrEqual(s.arrivalNs, s.tNs)
            XCTAssertLessThan(s.arrivalNs - s.tNs, 50_000_000,
                              "arrival_ns is \(s.arrivalNs - s.tNs) ns after t_ns; different clocks")
        }

        // marks.jsonl — the operator mark must land inside the accel span.
        let marks = try session.marks()
        XCTAssertFalse(marks.isEmpty)
        for m in marks {
            XCTAssertGreaterThanOrEqual(m.tNs, 0, "mark '\(m.kind)' precedes the epoch")
            XCTAssertLessThanOrEqual(m.tNs, meta.durationNs, "mark '\(m.kind)' outlives the session")
        }
        let probe = try XCTUnwrap(marks.first { $0.text == markText },
                                  "the stdin operator mark was not written:\n\(marks.map(\.kind))")
        XCTAssertTrue((firstNs...lastNs).contains(probe.tNs),
                      "operator mark at \(probe.tNs) is outside the accel span \(firstNs)...\(lastNs)")
        // It was typed one second in, so it must land near there and not at 0.
        XCTAssertEqual(Double(probe.tNs) / 1e9, 1.0, accuracy: 1.0)

        // input.jsonl — same clock again. A degraded tap is a permissions problem
        // on the host, not a format problem, so it is called out rather than failed.
        let tapMark = marks.first { $0.kind == "input_tap" }
        let inputs = try session.inputs()
        if tapMark?.text == "degraded" {
            XCTAssertTrue(inputs.isEmpty)
            print("note: event tap degraded on this host; input.jsonl epoch not covered")
        } else {
            XCTAssertFalse(inputs.isEmpty,
                           "the tap was active and an event was posted, but input.jsonl is empty")
            for e in inputs {
                XCTAssertGreaterThanOrEqual(e.tNs, 0)
                XCTAssertLessThanOrEqual(e.tNs, meta.durationNs)
            }
            XCTAssertTrue(inputs.contains { (firstNs...lastNs).contains($0.tNs) },
                          "no input event falls inside the accel span; input.jsonl uses another epoch")
        }

        // labels.jsonl — written by the labeller later, read back through the same
        // Session reader. A label placed on a real sample must resolve to it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.labelsURL.path))
        XCTAssertTrue(try session.labels().isEmpty, "a capture must not invent labels")
        let onset = samples[samples.count / 2].tNs
        try JSONL.write([TapLabel(tNs: onset, group: 0, indexInGroup: 0,
                                  intent: .double, confidence: .humanVerified)],
                        to: session.labelsURL)
        let readBack = try Session(directory: session.directory).labels()
        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(readBack[0].tNs, onset)
        XCTAssertTrue((firstNs...lastNs).contains(readBack[0].tNs))
        let nearest = samples.min { abs($0.tNs - readBack[0].tNs) < abs($1.tNs - readBack[0].tNs) }!
        XCTAssertEqual(nearest.tNs, onset, "a label does not resolve to the sample it was taken from")
    }
}
