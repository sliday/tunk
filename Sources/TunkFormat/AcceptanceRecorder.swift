import Foundation
import TunkCore

/// Writes one FORMAT.md session directory from a stream somebody else already
/// owns, so a live run of the app can leave the same artifact a
/// `tunk-capture` recording leaves.
///
/// ## Why this exists
///
/// The PRD's final acceptance step is a live driving test on the built app.
/// Until now its entire output was a printed hit rate, which is a self-report:
/// a critic could not re-grade it, could not check whether a hit was really a
/// hit, and could not see what the sensor saw. Feeding the same samples,
/// the same input events and the same prompt track into this writer turns that
/// run into a session the corpus tools read like any other.
///
/// ## MARKS, NOT LABELS
///
/// This class writes `marks.jsonl` and leaves `labels.jsonl` **empty**, and
/// that is the whole point. The acceptance test knows when it PROMPTED. It does
/// not know when the operator actually tapped. If it wrote labels derived from
/// its own triggers, the session would grade the detector against itself and
/// every number taken from it afterwards would be circular. Ground truth comes
/// from `tunk-label` reading the `beep` marks, independently, exactly as it does
/// for every other session in the corpus.
///
/// There is no API here that writes a `TapLabel`. Nothing derived from a
/// detector trigger may enter `labels.jsonl`, so the type simply cannot do it.
/// `noteLiveTrigger` exists and records what the live app fired, but it writes a
/// `mark`, never a label, and no labeller reads that mark kind — `tunk-label`
/// keys on `beep` alone.
///
/// ## Clock
///
/// The caller has its own monotonic clock, zeroed at some earlier epoch (the
/// app's `Engine` zeroes at launch). A session's timestamps must start near
/// zero, so this rebases: `startNs` is the caller-clock instant that becomes
/// `t_ns = 0`, and the session's `epoch_mach_ns` is the absolute mach value of
/// that instant. Samples that predate it are dropped rather than written
/// negative.
public final class AcceptanceRecorder {

    public struct Options {
        public var root: URL
        public var category: Category
        public var surface: Surface
        public var split: Split
        public var expectedTriggers: Int
        /// Free text for `meta.json` and the head of `notes.md`. The caller is
        /// expected to name the detector that produced the run; two recordings
        /// made by different detectors are otherwise indistinguishable.
        public var notes: String
        public var toolVersion: String
        public var reportIntervalUs: Int64

        public init(root: URL, category: Category, surface: Surface, split: Split,
                    expectedTriggers: Int, notes: String, toolVersion: String,
                    reportIntervalUs: Int64 = 1250) {
            self.root = root
            self.category = category
            self.surface = surface
            self.split = split
            self.expectedTriggers = expectedTriggers
            self.notes = notes
            self.toolVersion = toolVersion
            self.reportIntervalUs = reportIntervalUs
        }
    }

    public struct Summary: Sendable {
        public var dir: URL
        public var sampleCount: Int
        public var inputCount: Int
        public var markCount: Int
        public var durationNs: Int64
        public var measuredHz: Double
    }

    public let dir: URL
    public let sessionId: String
    /// Absolute mach nanoseconds of this session's `t_ns = 0`.
    public let epochMachNs: Int64

    private let opts: Options
    private let startNs: Int64
    private let clock: () -> Int64
    private let epochWallIso: String

    private let accelWriter: AccelWriter
    private let inputWriter: JSONLWriter<InputRecord>
    private let marksWriter: JSONLWriter<Mark>

    /// Two locks for the same reason `SessionRecorder` uses two: the sensor
    /// callback must never queue behind a JSONL write from the input path.
    private let accelLock = NSLock()
    private let jsonLock = NSLock()

    private var inputCount = 0
    private var markCount = 0
    private var droppedEarly = 0
    private var finished = false
    private var summary: Summary?

    /// - Parameters:
    ///   - callerEpochMachNs: absolute mach ns at which the caller's clock reads 0.
    ///   - startNs: caller-clock instant that becomes this session's `t_ns = 0`.
    ///   - clock: caller-clock now, used to stamp marks and to close the session.
    public init(options: Options, callerEpochMachNs: Int64, startNs: Int64,
                clock: @escaping () -> Int64) throws {
        self.opts = options
        self.startNs = startNs
        self.clock = clock
        self.epochMachNs = callerEpochMachNs + startNs

        let stamp = AcceptanceRecorder.stampFormatter.string(from: Date())
        let short = String(UInt32.random(in: 0...0xFF_FFFF), radix: 16)
        self.sessionId = "\(options.category.rawValue)__\(options.surface.rawValue)"
            + "__\(stamp)__\(String(repeating: "0", count: max(0, 6 - short.count)) + short)"
        self.dir = options.root.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        self.epochWallIso = AcceptanceRecorder.isoFormatter.string(from: Date())
        self.accelWriter = try AccelWriter(url: dir.appendingPathComponent("accel.bin"))
        self.inputWriter = try JSONLWriter<InputRecord>(url: dir.appendingPathComponent("input.jsonl"))
        self.marksWriter = try JSONLWriter<Mark>(url: dir.appendingPathComponent("marks.jsonl"))
        // Created empty and left empty. `tunk-label` fills it in from the marks.
        FileManager.default.createFile(atPath: dir.appendingPathComponent("labels.jsonl").path,
                                       contents: Data())
    }

    // MARK: - live stream

    public func ingest(sample: AccelSample) {
        let t = sample.tNs - startNs
        accelLock.lock()
        defer { accelLock.unlock() }
        guard !finished else { return }
        // A device timestamp can trail the arrival that opened the session by a
        // few hundred microseconds. Dropping those beats writing negatives.
        guard t >= 0 else { droppedEarly += 1; return }
        accelWriter.append(AccelSample(tNs: t, arrivalNs: sample.arrivalNs - startNs,
                                       x: sample.x, y: sample.y, z: sample.z))
    }

    public func ingest(input record: InputRecord) {
        let t = record.tNs - startNs
        guard t >= 0 else { return }
        var out = record
        out.tNs = t
        jsonLock.lock()
        defer { jsonLock.unlock() }
        guard !finished else { return }
        try? inputWriter.append(out)
        inputCount += 1
    }

    /// Stamps a mark at the caller's current time, or at `at` in caller-clock ns.
    ///
    /// Callers writing a `beep` must play the sound FIRST and call this after —
    /// see `Sources/TunkCapture/Commands.swift`. A stalled audio path once put
    /// every mark 16 s ahead of what the operator heard, which moved every
    /// gesture outside the labeller's window and turned a session into labels
    /// for silence.
    public func mark(kind: String, text: String? = nil, group: Int? = nil, at: Int64? = nil) {
        let m = Mark(tNs: max(0, (at ?? clock()) - startNs), kind: kind, text: text, group: group)
        jsonLock.lock()
        defer { jsonLock.unlock() }
        guard !finished else { return }
        try? marksWriter.append(m)
        markCount += 1
    }

    /// What the LIVE detector fired, recorded as a mark so a critic can compare
    /// it against a replay of the same file.
    ///
    /// Not ground truth and not readable as such: it lands in `marks.jsonl`
    /// under a kind no labeller looks at, `labels.jsonl` stays empty, and
    /// `tunk-label` derives onsets from `beep` marks alone. Delete this method
    /// before letting anything downstream key on it.
    public func noteLiveTrigger(atNs: Int64, lastOnsetNs: Int64, tapCount: Int) {
        mark(kind: "live_trigger",
             text: "taps=\(tapCount) latency_ms="
                 + String(format: "%.1f", Double(atNs - lastOnsetNs) / 1e6),
             at: atNs)
    }

    public var counts: (samples: Int, inputs: Int, marks: Int) {
        accelLock.lock()
        let s = accelWriter.count
        accelLock.unlock()
        jsonLock.lock()
        let i = inputCount
        let m = markCount
        jsonLock.unlock()
        return (s, i, m)
    }

    // MARK: - sealing

    /// Flush and seal. Idempotent, so a signal handler and the normal path can
    /// both call it.
    @discardableResult
    public func finish(reason: String) -> Summary {
        jsonLock.lock()
        if finished, let s = summary { jsonLock.unlock(); return s }
        jsonLock.unlock()

        mark(kind: "phase", text: "end:\(reason)")

        accelLock.lock()
        jsonLock.lock()
        finished = true
        let durationNs = clock() - startNs
        accelWriter.flush()
        let count = accelWriter.count
        let firstNs = accelWriter.firstNs
        let lastNs = accelWriter.lastNs
        accelWriter.close()
        inputWriter.close()
        marksWriter.close()
        let inputs = inputCount
        let marks = markCount
        let dropped = droppedEarly
        jsonLock.unlock()
        accelLock.unlock()

        let span = Double(lastNs - firstNs) / 1e9
        let hz = (count > 1 && span > 0) ? Double(count - 1) / span : 0
        // The measured cadence, not the requested one, exactly as
        // `SessionRecorder` records it: the harness sizes its gap threshold off
        // what the device actually delivered.
        let rateHz = hz > 0 ? (hz * 10).rounded() / 10 : 796.3
        let intervalNs = Int64((1e9 / rateHz).rounded())

        let meta = SessionMeta(
            sessionId: sessionId,
            category: opts.category,
            surface: opts.surface,
            epochMachNs: epochMachNs,
            epochWallIso: epochWallIso,
            reportIntervalUs: opts.reportIntervalUs,
            nominalRateHz: rateHz,
            nominalIntervalNs: intervalNs,
            durationNs: durationNs,
            sampleCount: count,
            machine: .current(),
            split: opts.split,
            expectedTriggers: opts.expectedTriggers,
            operatorNotes: opts.notes,
            toolVersion: opts.toolVersion)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
        writeNotes(reason: reason, hz: hz, inputs: inputs, dropped: dropped)

        let s = Summary(dir: dir, sampleCount: count, inputCount: inputs, markCount: marks,
                        durationNs: durationNs, measuredHz: hz)
        jsonLock.lock(); summary = s; jsonLock.unlock()
        return s
    }

    private func writeNotes(reason: String, hz: Double, inputs: Int, dropped: Int) {
        var lines = [
            "# \(sessionId)",
            "",
            "- category: \(opts.category.rawValue) (\(opts.category.title))",
            "- surface: \(opts.surface.rawValue) (\(opts.surface.title))",
            "- expected_triggers: \(opts.expectedTriggers)",
            "- ended: \(reason)",
            String(format: "- measured rate: %.1f Hz", hz),
            "",
            "## Ground truth is NOT in this directory yet",
            "",
            "labels.jsonl is empty on purpose. This recording carries the prompt",
            "track only: a `beep` mark at the instant the cue was audible, which",
            "is when the operator was asked to tap, not when they tapped. Turn",
            "that into onsets the same way every other session in the corpus gets",
            "them:",
            "",
            // Absolute, because the session is not written under the repo and a
            // relative path here would be wrong from every directory but one.
            "    bin/tunk-label check \(dir.path)",
            "    bin/tunk-label run   \(dir.path)",
            "",
            "`live_trigger` marks, if present, record what the LIVE detector fired",
            "during the run. They are evidence to compare a replay against, never",
            "ground truth: no labeller reads them, and labelling from them would",
            "grade the detector against itself.",
        ]
        if inputs == 0 {
            lines += [
                "",
                "## WARNING: input.jsonl is empty",
                "",
                "`tunk-capture verify` fails a non-idle session with no input",
                "events, because the suppression gate cannot be replayed without",
                "them. Nothing touched the keyboard or trackpad while this ran.",
            ]
        }
        if dropped > 0 {
            lines.append("")
            lines.append("- \(dropped) samples predating the session start were dropped, not written negative.")
        }
        if !opts.notes.isEmpty {
            lines.append("")
            lines.append(opts.notes)
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
