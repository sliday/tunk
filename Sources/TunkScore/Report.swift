import Foundation
import TunkCore
import TunkFormat

struct RunReport: Codable {
    var tool: String
    var generatedAt: String
    var dataRoot: String
    var split: String
    var detectorBackend: String
    var detectorIsStub: Bool
    var matchWindowMs: Double
    var config: DetectorConfig
    /// Tap counts the detector was treated as armed for. Everything else must never
    /// fire, and a trigger with an un-armed tap count is a false trigger.
    var armedCounts: [Int]
    var pooled: Aggregate
    var perSurface: [Aggregate]
    /// One aggregate per (surface × tap count), plus one per (pooled × tap count).
    /// This is what `web/ingest.py` and `--progress-json` turn into the page's
    /// per-tap-count columns.
    var perSurfaceTapCount: [Aggregate]
    /// The same slices rolled up across surfaces. Kept out of `perSurfaceTapCount`
    /// so a consumer that turns that array into surface cards does not grow a
    /// "pooled" card it never asked for.
    var pooledTapCount: [Aggregate]
    var perCategory: [Aggregate]
    var sessions: [SessionScore]
    var checks: [Check]
    var verdict: RunVerdict
    var warnings: [String]
}

enum Reporter {
    static func aggregate(_ scores: [SessionScore]) -> (pooled: Aggregate, surfaces: [String: Aggregate], categories: [String: Aggregate]) {
        var pooled = Aggregate(label: "pooled")
        var surfaces: [String: Aggregate] = [:]
        var categories: [String: Aggregate] = [:]
        for s in scores {
            pooled.add(s)
            surfaces[s.surface, default: Aggregate(label: s.surface)].add(s)
            categories[s.category, default: Aggregate(label: s.category)].add(s)
        }
        return (pooled, surfaces, categories)
    }

    /// Slice every scope by tap count. A count appears when it is armed, when
    /// something was labelled for it, or when something fired it — the three ways
    /// it can carry a number worth reading.
    static func tapCountSlices(_ scores: [SessionScore], policy: ScoringPolicy)
        -> (perSurface: [Aggregate], pooled: [Aggregate]) {
        var counts = Set(policy.armedCounts)
        for s in scores {
            for c in s.perCount where c.labelledGroups > 0 || c.triggers > 0 { counts.insert(c.count) }
        }
        var perSurface: [Aggregate] = []
        var pooledOut: [Aggregate] = []
        for n in counts.sorted() {
            var pooled = Aggregate(label: "pooled")
            var bySurface: [String: Aggregate] = [:]
            for s in scores {
                pooled.addSlice(s, count: n, armed: policy.isArmed(n))
                bySurface[s.surface, default: Aggregate(label: s.surface)]
                    .addSlice(s, count: n, armed: policy.isArmed(n))
            }
            for surf in Surface.allCases {
                if let a = bySurface[surf.rawValue] { perSurface.append(a) }
            }
            for (k, a) in bySurface.sorted(by: { $0.key < $1.key })
            where Surface(rawValue: k) == nil { perSurface.append(a) }
            if !scores.isEmpty { pooledOut.append(pooled) }
        }
        return (perSurface, pooledOut)
    }

    static func build(dataRoot: URL, split: String, config: DetectorConfig,
                      policy: ScoringPolicy, scores: [SessionScore],
                      warnings: [String]) -> RunReport {
        let (pooled, surfaces, categories) = aggregate(scores)
        let (verdict, checks) = PassLine.verdict(perSurface: surfaces, pooled: pooled)
        var warn = warnings
        for s in scores { warn.append(contentsOf: s.labelIssues) }
        // A non-shipped front end cannot be read off `config`: the filter design
        // lives in `DSPTuning`, which the report's config block does not carry.
        // Name it, or a resonator run and a shipped run produce reports that
        // differ only in their numbers.
        if DetectorFactory.tuning != DSPTuning.default {
            warn.insert("FRONT END IS NOT THE SHIPPED ONE: "
                        + ConfigIO.describeFrontEnd(DetectorFactory.tuning), at: 0)
        }
        if DetectorFactory.isStub {
            warn.insert("Graded the HARNESS STUB detector, not a shipping detector. "
                        + "These numbers say nothing about the real build.", at: 0)
        }
        if scores.isEmpty {
            warn.append("No sessions found under \(dataRoot.path). Nothing was graded.")
        }
        let slices = tapCountSlices(scores, policy: policy)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return RunReport(
            tool: "tunk-score \(TunkScoreVersion.string)",
            generatedAt: iso.string(from: Date()),
            dataRoot: dataRoot.path,
            split: split,
            detectorBackend: DetectorFactory.backendName,
            detectorIsStub: DetectorFactory.isStub,
            matchWindowMs: Double(Scoring.matchWindowNs) / 1e6,
            config: config,
            armedCounts: policy.armedCounts,
            pooled: pooled,
            perSurface: Surface.allCases.compactMap { surfaces[$0.rawValue] },
            perSurfaceTapCount: slices.perSurface,
            pooledTapCount: slices.pooled,
            perCategory: categories.keys.sorted().map { categories[$0]! },
            sessions: scores,
            checks: checks,
            verdict: verdict,
            warnings: warn
        )
    }

    // MARK: - Rendering

    static func markdown(_ r: RunReport) -> String {
        var out = ""
        out += "# tunk-score run\n\n"
        out += "- generated: `\(r.generatedAt)`\n"
        out += "- data root: `\(r.dataRoot)` (split `\(r.split)`)\n"
        out += "- detector: `\(r.detectorBackend)`\n"
        out += "- armed tap counts: `\(r.armedCounts.map(String.init).joined(separator: ", "))` "
        out += "(any other tap count that fires is a false trigger)\n"
        out += "- match window: ±\(String(format: "%.0f", r.matchWindowMs)) ms\n"
        out += "- sessions graded: \(r.sessions.count), wall time "
        out += String(format: "%.1f min\n", r.pooled.durationSeconds / 60)
        out += "\n**VERDICT: \(r.verdict.rawValue)**\n\n"

        if !r.warnings.isEmpty {
            out += "## Warnings\n\n"
            for w in r.warnings { out += "- \(w)\n" }
            out += "\n"
        }

        out += "## Pass line\n\n"
        out += "| scope | check | requirement | actual | status |\n|---|---|---|---|---|\n"
        for c in r.checks {
            let mark = c.status == .pass ? "pass" : (c.status == .fail ? "**FAIL**" : "_no data_")
            out += "| \(c.scope) | \(c.name) | \(c.requirement) | \(c.actual) | \(mark) |\n"
        }
        out += "\n"

        out += "## Per surface\n\n"
        out += aggregateTable([r.pooled] + r.perSurface)

        out += "\n## Per tap count\n\n"
        out += countTable(scope: "pooled", agg: r.pooled)
        for a in r.perSurface {
            out += "\n" + countTable(scope: a.label, agg: a)
        }
        out += "\nA trigger is attributed to the number of taps it fired. A trigger of an "
        out += "un-armed count, or a trigger that fires the wrong count on a labelled gesture, "
        out += "is a false trigger against the count it fired.\n"

        out += "\n## Per category\n\n"
        out += aggregateTable(r.perCategory)

        out += "\n## Per session\n\n"
        out += "| session | surface | category | dur | armed groups | detected | must-not-fire | fired anyway | triggers | FP | lat p50 | lat p95 | gaps |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for s in r.sessions {
            out += "| `\(s.sessionId)` | \(s.surface) | \(s.category) | "
            out += String(format: "%.0f s", s.durationSeconds) + " | "
            out += "\(s.armedGroups) | \(s.detectedGroups) | \(s.mustNotFireGroups) | "
            out += "\(s.mustNotFireViolations) | \(s.triggerCount) | \(s.falsePositives) | "
            out += "\(Fmt.msOpt(Percentile.of(s.latenciesNs, 0.5))) | "
            out += "\(Fmt.msOpt(Percentile.of(s.latenciesNs, 0.95))) | \(s.gapCount) |\n"
        }
        out += "\nLatency is `trigger.t_ns - labelled last onset`, over matched groups whose "
        out += "label confidence is not `prompt_window`.\n"
        return out
    }

    static func countTable(scope: String, agg: Aggregate) -> String {
        let rows = agg.perCount.filter { $0.armed || $0.labelledGroups > 0 || $0.triggers > 0 }
        guard !rows.isEmpty else { return "**\(scope)** — no tap counts observed or armed.\n" }
        var out = "**\(scope)**\n\n"
        out += "| taps | armed | labelled | detected | rate | missed | ambig | must-not-fire | fired anyway | triggers | false triggers | FT/20min | lat p50 | lat p95 |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for c in rows.sorted(by: { $0.count < $1.count }) {
            out += "| \(c.count) | \(c.armed ? "yes" : "**no**") | \(c.labelledGroups) | "
            out += "\(c.detectedGroups) | \(Fmt.pct(c.detectionRate)) | \(c.missedGroups) | "
            out += "\(c.ambiguousGroups) | \(c.mustNotFireGroups) | \(c.mustNotFireViolations) | "
            out += "\(c.triggers) | \(c.falseTriggers) | "
            out += "\(Fmt.num(agg.falseTriggersPer20Min(count: c.count))) | "
            out += "\(Fmt.msOpt(c.latencyP50Ns)) | \(Fmt.msOpt(c.latencyP95Ns)) |\n"
        }
        return out
    }

    private static func aggregateTable(_ aggs: [Aggregate]) -> String {
        var out = "| scope | sessions | dur (min) | armed groups | detected | rate | triggers | FP | FP/20min | lat p50 | lat p95 | lat max |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for a in aggs {
            out += "| \(a.label) | \(a.sessions) | "
            out += String(format: "%.1f", a.durationSeconds / 60) + " | "
            out += "\(a.armedGroups) | \(a.detectedGroups) | \(Fmt.pct(a.detectionRate)) | "
            out += "\(a.triggerCount) | \(a.falsePositives) | \(Fmt.num(a.falsePositivesPer20Min)) | "
            out += "\(Fmt.msOpt(a.latencyP50Ns)) | \(Fmt.msOpt(a.latencyP95Ns)) | \(Fmt.msOpt(a.latencyMaxNs)) |\n"
        }
        return out
    }

    static func console(_ r: RunReport) -> String {
        var out = ""
        for w in r.warnings { out += "!! \(w)\n" }
        out += "\n"
        out += "data root   \(r.dataRoot)  (split \(r.split))\n"
        out += "detector    \(r.detectorBackend)\n"
        out += "armed       \(r.armedCounts.map(String.init).joined(separator: ", ")) tap(s)"
        out += "   — any other tap count that fires is a false trigger\n"
        out += "sessions    \(r.sessions.count)   wall time "
        out += String(format: "%.1f min\n", r.pooled.durationSeconds / 60)
        out += "\n"
        out += pad("scope", 10) + pad("sess", 6) + pad("groups", 8) + pad("det", 6)
        out += pad("rate", 10) + pad("trig", 6) + pad("FP", 5) + pad("FP/20m", 9)
        out += pad("p50", 10) + pad("p95", 10) + "max\n"
        for a in [r.pooled] + r.perSurface {
            out += pad(a.label, 10) + pad("\(a.sessions)", 6) + pad("\(a.armedGroups)", 8)
            out += pad("\(a.detectedGroups)", 6) + pad(Fmt.pct(a.detectionRate), 10)
            out += pad("\(a.triggerCount)", 6) + pad("\(a.falsePositives)", 5)
            out += pad(Fmt.num(a.falsePositivesPer20Min), 9)
            out += pad(Fmt.msOpt(a.latencyP50Ns), 10) + pad(Fmt.msOpt(a.latencyP95Ns), 10)
            out += Fmt.msOpt(a.latencyMaxNs) + "\n"
        }

        out += "\nper tap count\n"
        out += pad("scope", 10) + pad("taps", 6) + pad("armed", 7) + pad("labelled", 10)
        out += pad("det", 6) + pad("rate", 10) + pad("trig", 6) + pad("false", 7)
        out += pad("FT/20m", 9) + "p95\n"
        for a in [r.pooled] + r.perSurface {
            let rows = a.perCount.filter { $0.armed || $0.labelledGroups > 0 || $0.triggers > 0 }
            for c in rows.sorted(by: { $0.count < $1.count }) {
                out += pad(a.label, 10) + pad("\(c.count)", 6) + pad(c.armed ? "yes" : "NO", 7)
                out += pad("\(c.labelledGroups)", 10) + pad("\(c.detectedGroups)", 6)
                out += pad(Fmt.pct(c.detectionRate), 10) + pad("\(c.triggers)", 6)
                out += pad("\(c.falseTriggers)", 7)
                out += pad(Fmt.num(a.falseTriggersPer20Min(count: c.count)), 9)
                out += Fmt.msOpt(c.latencyP95Ns) + "\n"
            }
        }

        out += "\npass line\n"
        for c in r.checks {
            let mark = c.status == .pass ? "  ok  " : (c.status == .fail ? " FAIL " : " ---- ")
            out += "[\(mark)] \(pad(c.scope, 8)) \(pad(c.name, 40)) \(c.requirement)  ->  \(c.actual)\n"
        }
        out += "\nVERDICT: \(r.verdict.rawValue)\n"
        return out
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }

    static func writeJSON(_ r: RunReport, to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(r).write(to: url)
    }
}

enum TunkScoreVersion {
    static let string = "0.1.0"
}
