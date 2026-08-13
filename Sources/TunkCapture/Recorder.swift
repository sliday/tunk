import Foundation
import TunkCore
import TunkFormat
import TunkIMU

/// Records one session directory: accel.bin, input.jsonl, marks.jsonl, an empty
/// labels.jsonl, notes.md and meta.json. Every file shares one epoch and one
/// timebase, per FORMAT.md.
///
/// Writers are appended to live, so a session killed with Ctrl-C or a crash still
/// leaves everything up to that instant on disk. `finish()` is idempotent and safe
/// to call from a signal handler.
final class SessionRecorder {
    struct Options {
        var root: URL
        var category: Category
        var surface: Surface
        var split: Split
        var notes: String = ""
        var expectedTriggers: Int = 0
        var reportIntervalUs: Int64 = 1250
        var captureInput: Bool = true
        var requireInput: Bool = true
        var captureTouches: Bool = true
    }

    struct Summary {
        var dir: URL
        var sampleCount: Int
        var inputCount: Int
        var markCount: Int
        var durationNs: Int64
        var gapCount: UInt64
        var measuredHz: Double
        var inputTapActive: Bool
    }

    let opts: Options
    let dir: URL
    let sessionId: String
    let epochMachNs: Int64
    private let epochWallIso: String

    private let source: AccelSource
    private let accelWriter: AccelWriter
    private let inputWriter: JSONLWriter<InputRecord>
    private let marksWriter: JSONLWriter<Mark>
    /// Two locks, not one: the sensor callback must never queue behind a JSONL
    /// write from the event tap. `finished` is written while holding both, in the
    /// order accel-then-json.
    private let accelLock = NSLock()
    private let jsonLock = NSLock()

    private var tap: InputTap?
    private var inputCount = 0
    private var markCount = 0
    private var finished = false
    private var summary: Summary?
    private(set) var inputTapActive = false

    init(opts: Options) throws {
        self.opts = opts
        let stamp = SessionRecorder.stampFormatter.string(from: Date())
        let short = String(UInt32.random(in: 0...0xFF_FFFF), radix: 16).leftPadded(to: 6, with: "0")
        self.sessionId = "\(opts.category.rawValue)__\(opts.surface.rawValue)__\(stamp)__\(short)"
        self.dir = opts.root.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        self.epochWallIso = SessionRecorder.isoFormatter.string(from: Date())
        self.epochMachNs = MachClock.nowNanos()
        self.source = AccelSource(reportIntervalUs: opts.reportIntervalUs)
        self.accelWriter = try AccelWriter(url: dir.appendingPathComponent("accel.bin"))
        self.inputWriter = try JSONLWriter<InputRecord>(url: dir.appendingPathComponent("input.jsonl"))
        self.marksWriter = try JSONLWriter<Mark>(url: dir.appendingPathComponent("marks.jsonl"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("labels.jsonl").path,
                                       contents: Data())
    }

    /// Nanoseconds since the session epoch. The single clock, per FORMAT.md.
    var nowNs: Int64 { MachClock.nowNanos() - epochMachNs }

    /// Opens the sensor and the event tap. Call before the script starts; the tap
    /// delivers on the main run loop, which must be running.
    func start() throws {
        if opts.captureInput {
            let t = InputTap(clock: { [weak self] in self?.nowNs ?? 0 },
                             captureTouches: opts.captureTouches) { [weak self] rec in
                self?.writeInput(rec)
            }
            do {
                try t.start()
                tap = t
                inputTapActive = true
            } catch {
                if opts.requireInput { throw error }
                inputTapActive = false
            }
        }
        mark(kind: "input_tap", text: inputTapActive ? "active" : "degraded")
        mark(kind: "phase", text: "start:\(opts.category.rawValue)")

        try source.start(epochMachNs: epochMachNs) { [weak self] s in
            guard let self else { return }
            self.accelLock.lock()
            if !self.finished { self.accelWriter.append(s) }
            self.accelLock.unlock()
        }
    }

    private func writeInput(_ rec: InputRecord) {
        jsonLock.lock(); defer { jsonLock.unlock() }
        guard !finished else { return }
        try? inputWriter.append(rec)
        inputCount += 1
    }

    func mark(kind: String, text: String? = nil, group: Int? = nil, at tNs: Int64? = nil) {
        let m = Mark(tNs: tNs ?? nowNs, kind: kind, text: text, group: group)
        jsonLock.lock(); defer { jsonLock.unlock() }
        guard !finished else { return }
        try? marksWriter.append(m)
        markCount += 1
    }

    var liveCounts: (samples: Int, inputs: Int) {
        accelLock.lock()
        let s = accelWriter.count
        accelLock.unlock()
        jsonLock.lock()
        let i = inputCount
        jsonLock.unlock()
        return (s, i)
    }

    /// Flush and seal the session. Idempotent; safe from the SIGINT handler.
    @discardableResult
    func finish(reason: String) -> Summary {
        jsonLock.lock()
        if finished, let s = summary { jsonLock.unlock(); return s }
        jsonLock.unlock()

        mark(kind: "phase", text: "end:\(reason)")

        tap?.stop()
        source.stop()

        accelLock.lock()
        jsonLock.lock()
        finished = true
        let durationNs = MachClock.nowNanos() - epochMachNs
        accelWriter.flush()
        let count = accelWriter.count
        let firstNs = accelWriter.firstNs
        let lastNs = accelWriter.lastNs
        accelWriter.close()
        inputWriter.close()
        marksWriter.close()
        let inputs = inputCount
        let marks = markCount
        jsonLock.unlock()
        accelLock.unlock()

        let span = Double(lastNs - firstNs) / 1e9
        let hz = (count > 1 && span > 0) ? Double(count - 1) / span : 0
        // FORMAT.md's example carries the measured cadence here (796.3 Hz /
        // 1_256_000 ns), not the requested one, so the harness sizes its gap
        // threshold off what the device actually delivered.
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
            machine: MachineInfo.current(),
            split: opts.split,
            expectedTriggers: opts.expectedTriggers,
            operatorNotes: opts.notes,
            toolVersion: toolVersion
        )
        writeMeta(meta)
        writeNotes(reason: reason, hz: hz)

        let s = Summary(dir: dir, sampleCount: count, inputCount: inputs, markCount: marks,
                        durationNs: durationNs, gapCount: source.snapshotStats().gapCount,
                        measuredHz: hz, inputTapActive: inputTapActive)
        jsonLock.lock(); summary = s; jsonLock.unlock()
        return s
    }

    private func writeMeta(_ meta: SessionMeta) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(meta) else { return }
        try? data.write(to: dir.appendingPathComponent("meta.json"))
    }

    private func writeNotes(reason: String, hz: Double) {
        var lines = [
            "# \(sessionId)",
            "",
            "- surface: \(opts.surface.rawValue) (\(opts.surface.title))",
            "- category: \(opts.category.rawValue) (\(opts.category.title))",
            "- ended: \(reason)",
            String(format: "- measured rate: %.1f Hz", hz),
            "- input tap: \(inputTapActive ? "active" : "DEGRADED — input.jsonl is not usable")",
        ]
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

extension String {
    func leftPadded(to n: Int, with c: Character) -> String {
        count >= n ? self : String(repeating: c, count: n - count) + self
    }
}
