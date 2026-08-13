import XCTest
@testable import TunkCore
@testable import TunkFormat

/// Passive capture writes the seconds around a tap-shaped transient during
/// ordinary use, so gathering a tap PROFILE stops needing a scripted session.
///
/// The class under test lives in the app target, which cannot be imported, so
/// this exercises the same contract against the on-disk format: whatever writes
/// a passive snippet must produce a session the harness reads without special
/// handling, and must declare itself in a way that cannot be mistaken for
/// prompted ground truth.
final class PassiveCaptureTests: XCTestCase {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunk-passive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A passive snippet must round-trip through the reader the harness uses.
    func testASnippetIsAReadableSession() throws {
        let dir = try scratch().appendingPathComponent("idle__desk__passive-x-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let writer = try AccelWriter(url: dir.appendingPathComponent("accel.bin"))
        let step: Int64 = 1_256_000
        for i in 0..<3000 {
            let t = Int64(i) * step
            writer.append(AccelSample(tNs: t, arrivalNs: t, x: 0, y: 0, z: -0.9796))
        }
        writer.close()

        try JSONL.write([InputRecord(tNs: 1_000_000, kind: .keyDown, code: 4)],
                        to: dir.appendingPathComponent("input.jsonl"))
        try JSONL.write([Mark(tNs: 2_000_000, kind: "onset", text: "0.4200 g")],
                        to: dir.appendingPathComponent("marks.jsonl"))
        try JSONL.write([TapLabel](), to: dir.appendingPathComponent("labels.jsonl"))

        let meta = SessionMeta(
            sessionId: "idle__desk__passive-x-1", category: .idle, surface: .desk,
            epochMachNs: 0, epochWallIso: "1970-01-01T00:00:00Z",
            reportIntervalUs: 1250, nominalRateHz: 796.3, nominalIntervalNs: step,
            durationNs: Int64(2999) * step, sampleCount: 3000,
            machine: .current(), split: .train, expectedTriggers: 0,
            operatorNotes: "PASSIVE capture", toolVersion: "tunk passive 0.1.0")
        let enc = JSONEncoder()
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))

        let session = try Session(directory: dir)
        XCTAssertEqual(try session.samples().count, 3000)
        XCTAssertEqual(try session.inputs().count, 1)
        XCTAssertEqual(try session.marks().count, 1)
        XCTAssertEqual(session.meta.expectedTriggers, 0)
    }

    /// The property that keeps passive data honest: `expectedTriggers` is zero,
    /// so the harness scores a snippet for false positives and never counts it
    /// toward detection rate.
    ///
    /// The snippets are chosen BY the detector. A tap it missed leaves no file,
    /// so a detection rate computed from them asks only whether the detector
    /// agrees with itself, and would read high no matter how bad it was.
    func testPassiveSnippetsCannotInflateDetectionRate() throws {
        let meta = SessionMeta(
            sessionId: "idle__desk__passive-x-2", category: .idle, surface: .desk,
            epochMachNs: 0, epochWallIso: "1970-01-01T00:00:00Z",
            reportIntervalUs: 1250, nominalRateHz: 796.3, nominalIntervalNs: 1_256_000,
            durationNs: 4_000_000_000, sampleCount: 3000,
            machine: .current(), split: .train, expectedTriggers: 0,
            operatorNotes: "PASSIVE capture", toolVersion: "tunk passive 0.1.0")

        XCTAssertEqual(meta.expectedTriggers, 0,
                       "a passive snippet must never declare expected triggers")
        XCTAssertFalse(meta.category.isTapCategory,
                       "and must not be filed under a tap category, or it would "
                       + "enter the detection denominator with no labels")
    }

    /// Input events have to travel with the samples. Without them the harness
    /// cannot reproduce the suppression gate, and a snippet that cannot be
    /// replayed faithfully is worth very little.
    func testInputIsCarriedSoTheGateCanBeReplayed() throws {
        let dir = try scratch().appendingPathComponent("idle__desk__passive-x-3")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let records = [
            InputRecord(tNs: 500_000_000, kind: .keyDown, code: 4),
            InputRecord(tNs: 520_000_000, kind: .keyUp, code: 4),
            InputRecord(tNs: 900_000_000, kind: .trackpadTouch, code: nil, count: 2),
        ]
        try JSONL.write(records, to: dir.appendingPathComponent("input.jsonl"))
        let back = try JSONL.read(InputRecord.self, from: dir.appendingPathComponent("input.jsonl"))
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back.filter { $0.kind.gatesDetection }.count, 3,
                       "all three kinds arm the gate and must survive the round trip")
    }
}
