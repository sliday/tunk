import XCTest
@testable import TunkCore
@testable import TunkFormat

/// The onset-to-snippet path, end to end.
///
/// `PassiveCapture` shipped with its header saying this path "has not been
/// exercised end to end, because doing so needs an onset, and an onset needs a
/// real tap". That conflated a real TAP with a real ONSET. The detector will
/// produce genuine onsets from synthetic samples all day, and the collector
/// cannot tell where its samples came from — so the wiring is testable, and was
/// simply living in an executable target that no test can import.
///
/// It now lives in TunkFormat, and this drives the same sequence `Engine` does:
/// every sample into the detector and the collector, every declared onset into
/// `noteCandidate`.
final class PassiveCaptureEndToEndTests: XCTestCase {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunk-passive-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Drive a real gesture through a real detector and require a snippet on
    /// disk that the harness can read.
    func testARealOnsetWritesAReadableSnippet() throws {
        let root = try scratch()
        let capture = PassiveCapture(config: .init(preRollSeconds: 0.4,
                                                   postRollSeconds: 0.4,
                                                   outputRoot: root))
        let detector = TapDetector(config: .default)
        // The tail matters: a snippet is flushed when a sample arrives past the
        // post-roll deadline, so a stream that stops at the last tap writes
        // nothing and the test would pass by never exercising the flush.
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 3_000_000_000)
        stream.taps.append(.init(tNs: SyntheticStream.leadInNs,
                                 amplitude: SyntheticStream.amplitude(timesThreshold: 2.0)))
        stream.taps.append(.init(tNs: SyntheticStream.leadInNs + 150_000_000,
                                 amplitude: SyntheticStream.amplitude(timesThreshold: 2.0)))

        var onsets = 0
        for sample in stream.samples() {
            _ = detector.ingest(sample: sample)
            capture.ingest(sample: sample)
            for onset in detector.drainOnsets() {
                onsets += 1
                capture.noteCandidate(atNs: onset.tNs, strength: onset.strength,
                                      suppressed: onset.suppressedByGate)
            }
        }
        XCTAssertGreaterThan(onsets, 0, "the fixture produced no onset, so this test "
                             + "would pass without exercising anything")
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(dirs.count, 1, "expected exactly one snippet, got \(dirs)")

        // The point of the test: it must be a session the harness reads with no
        // special handling.
        let session = try Session(directory: root.appendingPathComponent(dirs[0]))
        XCTAssertGreaterThan(try session.samples().count, 0)
        XCTAssertEqual(session.meta.expectedTriggers, 0,
                       "a passive snippet must never contribute to detection rate")
        let marks = try session.marks()
        XCTAssertTrue(marks.contains { $0.kind == "onset" },
                      "the onset that caused the snippet must be recorded in it")
    }

    /// The cap is what stops an afternoon of ordinary use filling the disk.
    func testTheSnippetCapHolds() throws {
        let root = try scratch()
        let capture = PassiveCapture(config: .init(preRollSeconds: 0.2,
                                                   postRollSeconds: 0.2,
                                                   maxSnippets: 1,
                                                   outputRoot: root))
        let detector = TapDetector(config: .default)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 8_000_000_000)
        for i in 0..<6 {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * 1_200_000_000,
                                     amplitude: SyntheticStream.amplitude(timesThreshold: 2.0)))
        }
        for sample in stream.samples() {
            _ = detector.ingest(sample: sample)
            capture.ingest(sample: sample)
            for onset in detector.drainOnsets() {
                capture.noteCandidate(atNs: onset.tNs, strength: onset.strength,
                                      suppressed: onset.suppressedByGate)
            }
        }
        XCTAssertLessThanOrEqual(capture.snippetsWritten, 1)
    }
}
