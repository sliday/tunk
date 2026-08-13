import Foundation
import TunkFormat

/// Writes a round into `web/progress.json` in the shape `web/schema.py` validates
/// (schema 2), so the progress page stops being transcribed by hand.
///
/// Rules taken from `web/README.md` and `web/schema.py`:
///
///  - schema 2 puts a `taps` block on every surface, keyed by tap count
///    (`"1" "2" "3" "any"`), because each count binds to its own action and so
///    carries its own detection rate and its own false triggers.
///  - `value: null` means unmeasured. It is not zero and it is never a pass.
///  - a metric entry may only carry `value`, `n`, `pass`, `note`; a metric key
///    outside `schema.py`'s `METRICS` table is a hard schema error. So the
///    per-count numbers live in the `taps` layer, never in invented keys.
///  - `index.html` is generated. This writer never touches it and prints the
///    `python3 web/render.py` reminder instead.
///
/// A schema-1 file is migrated on read, exactly as `schema.py:migrate` does it:
/// the old flat `metrics` block becomes tap count `"2"`. Unknown top-level keys
/// and unknown keys inside existing rounds survive untouched.
struct ProgressOptions {
    var path: URL
    var round: Int?
    var label: String?
    var headline: String?
    var biggestGap: String?
    var status: String?
    var includePooled: Bool = false
    var replace: Bool = false
}

enum ProgressFeed {
    /// The only tap-count keys `web/schema.py` accepts.
    static let tapKeys = ["1", "2", "3"]

    // MARK: - Entry point

    /// Append one round. Returns the lines to print.
    static func append(report: RunReport, options: ProgressOptions) throws -> [String] {
        var doc = migrate(try load(options.path))

        var rounds = (doc["rounds"] as? [[String: Any]]) ?? []
        let existing = rounds.compactMap { $0["round"] as? Int }
        let roundNumber = options.round ?? ((existing.max() ?? -1) + 1)

        if let dup = rounds.firstIndex(where: { ($0["round"] as? Int) == roundNumber }) {
            guard options.replace else {
                throw CLIError.failed("""
                \(options.path.path) already has round \(roundNumber). \
                Pass --progress-round <n> for a different number, or --progress-replace \
                to overwrite it.
                """)
            }
            rounds.remove(at: dup)
        }

        let round = buildRound(report: report, number: roundNumber, options: options)
        rounds.append(round)
        rounds.sort { (($0["round"] as? Int) ?? 0) < (($1["round"] as? Int) ?? 0) }

        doc["schema"] = 2
        doc["title"] = doc["title"] ?? "Tunk — gauntlet loop"
        doc["pass_line"] = doc["pass_line"] ?? defaultPassLine()
        doc["generated_at"] = iso(Date())
        doc["rounds"] = rounds

        try write(doc, to: options.path)

        let surfaces = (round["surfaces"] as? [String: Any])?.keys.sorted() ?? []
        return [
            "appended round \(roundNumber) (\(round["label"] as? String ?? "")) to \(options.path.path)",
            "  surfaces: \(surfaces.joined(separator: ", "))",
            "  tap counts: \(report.armedCounts.map(String.init).joined(separator: ", ")) armed",
            "  headline: \(round["headline"] as? String ?? "")",
            "  NEXT: `python3 web/schema.py \(options.path.path)` then `python3 web/render.py`,"
                + " or the page keeps showing the previous round.",
        ]
    }

    // MARK: - Round construction

    private static func buildRound(report: RunReport, number: Int,
                                   options: ProgressOptions) -> [String: Any] {
        // Index the per-(surface × count) slices the report already built.
        var slices: [String: [Int: Aggregate]] = [:]
        for a in report.perSurfaceTapCount + report.pooledTapCount {
            guard let n = a.tapCount else { continue }
            slices[a.label, default: [:]][n] = a
        }

        var surfaces: [String: Any] = [:]
        for agg in report.perSurface {
            surfaces[agg.label] = surfaceObject(agg, slices: slices[agg.label] ?? [:])
        }
        // A surface with no sessions still gets a card, all-null. A missing surface
        // on the page reads as "fine", and it is not.
        for s in PassLine.requiredSurfaces where surfaces[s.rawValue] == nil {
            surfaces[s.rawValue] = surfaceObject(Aggregate(label: s.rawValue), slices: [:])
        }
        if options.includePooled {
            surfaces["pooled"] = surfaceObject(report.pooled, slices: slices["pooled"] ?? [:])
        }

        let auto = autoText(report: report)
        var source: [String: Any] = [
            "tool": report.tool,
            "detector": report.detectorBackend,
            "is_stub": report.detectorIsStub,
            "split": report.split,
            "data_root": report.dataRoot,
        ]
        if !report.warnings.isEmpty { source["warnings"] = report.warnings }

        return [
            "round": number,
            "label": options.label ?? auto.label,
            "timestamp": report.generatedAt,
            "status": options.status ?? (report.sessions.isEmpty ? "no_data" : "scored"),
            "headline": options.headline ?? auto.headline,
            "biggest_gap": options.biggestGap ?? auto.gap,
            "source": source,
            "armed_tap_counts": report.armedCounts,
            "dataset": [
                "sessions": report.sessions.count,
                "double_tap_groups": report.pooled.armedGroups,
                "minutes": rounded(report.pooled.durationSeconds / 60, 1),
            ],
            "surfaces": surfaces,
        ]
    }

    private static func surfaceObject(_ a: Aggregate, slices: [Int: Aggregate]) -> [String: Any] {
        var taps: [String: Any] = [
            // "any" holds the numbers that belong to no single count: the whole
            // session's false-trigger load, whichever gesture produced it.
            "any": ["metrics": metrics(a, note: allCountsNote(a))],
        ]
        for (n, slice) in slices where tapKeys.contains("\(n)") {
            taps["\(n)"] = ["metrics": metrics(slice, note: countNote(slice))]
        }

        var tapGroups: [String: Int] = [:]
        for (n, slice) in slices { tapGroups["\(n)"] = slice.labelledGroups }

        var coverage: [String: Any] = [
            "sessions": a.sessions,
            "minutes": rounded(a.durationSeconds / 60, 1),
            "typing_minutes": rounded(a.typingSeconds / 60, 1),
            "confound_minutes": rounded(a.confoundSeconds / 60, 1),
            "double_tap_groups": a.count(2)?.labelledGroups ?? 0,
        ]
        if !tapGroups.isEmpty { coverage["tap_groups"] = tapGroups }

        return ["coverage": coverage, "taps": taps]
    }

    /// The eight keys `web/schema.py` knows. Anything else is a schema error there,
    /// so nothing else is written.
    private static func metrics(_ a: Aggregate, note: String?) -> [String: Any] {
        var detectionNote = note
        if a.armed == false {
            detectionNote = "not armed — this gesture must never fire, so it has no detection target"
        } else if a.armedGroups == 0 {
            detectionNote = detectionNote ?? "no labelled groups in this scope"
        }
        return [
            "detection_rate": entry(a.armedGroups == 0 ? nil : (a.detectionRate ?? 0) * 100,
                                    n: a.armedGroups, note: detectionNote),
            "false_triggers_typing": entry(a.typingSessions == 0 ? nil : Double(a.typingFalsePositives),
                                           n: a.typingSessions,
                                           note: a.typingSessions == 0 ? "no typing sessions in this scope" : nil),
            "false_triggers_confound": entry(a.confoundSessions == 0 ? nil : Double(a.confoundFalsePositives),
                                             n: a.confoundSessions,
                                             note: a.confoundSessions == 0 ? "no confound sessions in this scope" : nil),
            "false_triggers_per_20min": entry(a.falsePositivesPer20Min, n: a.sessions,
                                              note: falseTriggerNote(a)),
            "latency_p50_ms": entry(ms(a.latencyP50Ns), n: a.latenciesNs.count),
            "latency_p95_ms": entry(ms(a.latencyP95Ns), n: a.latenciesNs.count),
            "latency_max_ms": entry(ms(a.latencyMaxNs), n: a.latenciesNs.count),
            // tunk-score replays a detector; it never posts a key event. The
            // emission tests own this number, so it stays null rather than a zero
            // the page would render as a pass.
            "stuck_modifiers": entry(nil, n: 0,
                                     note: "replay does not emit keys; graded by the emission tests"),
        ]
    }

    private static func allCountsNote(_ a: Aggregate) -> String? {
        let parts = a.perCount
            .filter { $0.armed || $0.labelledGroups > 0 || $0.triggers > 0 }
            .sorted { $0.count < $1.count }
            .map { "\($0.count)-tap \($0.detectedGroups)/\($0.labelledGroups)\($0.armed ? "" : " [not armed]")" }
        guard !parts.isEmpty else { return nil }
        return "all armed counts together — " + parts.joined(separator: ", ")
    }

    private static func countNote(_ a: Aggregate) -> String? {
        guard a.armed == false else { return nil }
        return "\(a.tapCount ?? 0)-tap is not armed; \(a.labelledGroups) labelled gesture(s) here "
            + "must never fire"
    }

    private static func falseTriggerNote(_ a: Aggregate) -> String? {
        if let n = a.tapCount {
            return a.armed == false && a.triggerCount > 0
                ? "\(a.triggerCount) trigger(s) fired \(n) tap(s) while \(n)-tap is not armed"
                : nil
        }
        let rows = a.perCount.filter { $0.armed || $0.triggers > 0 }.sorted { $0.count < $1.count }
        guard !rows.isEmpty else { return nil }
        return "by tap count: " + rows.map { c in
            "\(c.count)-tap \(c.falseTriggers)\(c.armed ? "" : " [not armed]")"
        }.joined(separator: ", ")
    }

    private static func entry(_ value: Double?, n: Int, note: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["value": value.map { rounded($0, 2) as Any } ?? NSNull(), "n": n]
        if let note { out["note"] = note }
        return out
    }

    // MARK: - Auto-written prose

    /// The critic overwrites these with `--progress-headline` / `--progress-gap`.
    /// The auto version never invents good news: with no data it says so.
    private static func autoText(report: RunReport) -> (label: String, headline: String, gap: String) {
        let armed = report.armedCounts.map { "\($0)-tap" }.joined(separator: "/")
        let label = "\(report.detectorIsStub ? "stub" : "detector"), armed \(armed)"

        if report.sessions.isEmpty {
            return (label,
                    "no data — no sessions under \(report.dataRoot)",
                    "Nothing has been measured. No session exists under \(report.dataRoot), so every "
                    + "metric on this round is unmeasured, not passing.")
        }

        let fails = report.checks.filter { $0.status == .fail }
        let noData = report.checks.filter { $0.status == .noData }
        let stub = report.detectorIsStub ? "STUB detector — says nothing about the real build. " : ""

        let headline: String
        switch report.verdict {
        case .pass:
            headline = "\(stub)PASS across \(report.sessions.count) sessions, armed \(armed)"
        case .fail:
            headline = "\(stub)FAIL — \(fails.count) check(s) below the line, armed \(armed)"
        case .incomplete:
            headline = "\(stub)INCOMPLETE — \(noData.count) check(s) had no data behind them"
        }

        let gap: String
        if let worst = fails.first {
            gap = "\(worst.scope): \(worst.name) — required \(worst.requirement), got \(worst.actual)."
                + (fails.count > 1 ? " \(fails.count - 1) further check(s) also failing." : "")
        } else if let missing = noData.first {
            gap = "\(missing.scope): \(missing.name) has no data behind it (\(missing.actual)). "
                + "Unmeasured is not passing."
        } else {
            gap = "No check is below the line on this data. The gap is the data itself: "
                + "confirm coverage on all three surfaces before calling it."
        }
        return (label, headline, gap)
    }

    // MARK: - File IO

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.failed("\(url.path) is not a JSON object; refusing to overwrite it")
        }
        return obj
    }

    /// Same move as `web/schema.py:migrate`. A schema-1 round graded double-tap
    /// only, so its flat `metrics` block becomes tap count `"2"`. Nothing is
    /// invented: the file gains empty columns, not data.
    private static func migrate(_ doc: [String: Any]) -> [String: Any] {
        guard (doc["schema"] as? Int) == 1 else { return doc }
        var out = doc
        var rounds = (doc["rounds"] as? [[String: Any]]) ?? []
        for i in rounds.indices {
            guard var surfaces = rounds[i]["surfaces"] as? [String: Any] else { continue }
            for (name, raw) in surfaces {
                guard var surf = raw as? [String: Any],
                      let metrics = surf["metrics"], surf["taps"] == nil else { continue }
                surf["taps"] = ["2": ["metrics": metrics]]
                surf.removeValue(forKey: "metrics")
                surfaces[name] = surf
            }
            rounds[i]["surfaces"] = surfaces
        }
        out["rounds"] = rounds
        out["schema"] = 2
        return out
    }

    private static func write(_ doc: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// Mirrors the pass line in FORMAT.md. Only written when the file has none.
    private static func defaultPassLine() -> [String: Any] {
        [
            "detection_rate": ["op": ">=", "value": PassLine.detectionRateFloor * 100, "unit": "%"],
            "false_triggers_typing": ["op": "==", "value": 0, "unit": ""],
            "false_triggers_confound": ["op": "==", "value": 0, "unit": ""],
            "false_triggers_per_20min": ["op": "<",
                                         "value": PassLine.falsePositivesPer20MinCeiling,
                                         "unit": "/20min"],
            "latency_p95_ms": ["op": "<=",
                               "value": Double(PassLine.latencyP95CeilingNs) / 1e6, "unit": "ms"],
            "stuck_modifiers": ["op": "==", "value": 0, "unit": ""],
        ]
    }

    // MARK: - Small helpers

    private static func ms(_ ns: Int64?) -> Double? { ns.map { Double($0) / 1e6 } }

    private static func rounded(_ v: Double, _ digits: Int) -> Double {
        let f = pow(10.0, Double(digits))
        return (v * f).rounded() / f
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }
}
