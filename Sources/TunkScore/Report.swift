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
    var pooled: Aggregate
    var perSurface: [Aggregate]
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

    static func build(dataRoot: URL, split: String, config: DetectorConfig,
                      scores: [SessionScore], warnings: [String]) -> RunReport {
        let (pooled, surfaces, categories) = aggregate(scores)
        let (verdict, checks) = PassLine.verdict(perSurface: surfaces, pooled: pooled)
        var warn = warnings
        if DetectorFactory.isStub {
            warn.insert("Graded the HARNESS STUB detector, not a shipping detector. "
                        + "These numbers say nothing about the real build.", at: 0)
        }
        if scores.isEmpty {
            warn.append("No sessions found under \(dataRoot.path). Nothing was graded.")
        }
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
            pooled: pooled,
            perSurface: Surface.allCases.compactMap { surfaces[$0.rawValue] },
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
        out += "\n## Per category\n\n"
        out += aggregateTable(r.perCategory)

        out += "\n## Per session\n\n"
        out += "| session | surface | category | dur | groups | detected | triggers | FP | lat p50 | lat p95 | gaps |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|\n"
        for s in r.sessions {
            out += "| `\(s.sessionId)` | \(s.surface) | \(s.category) | "
            out += String(format: "%.0f s", s.durationSeconds) + " | "
            out += "\(s.doubleGroups) | \(s.detectedGroups) | \(s.triggerCount) | \(s.falsePositives) | "
            out += "\(Fmt.msOpt(Percentile.of(s.latenciesNs, 0.5))) | "
            out += "\(Fmt.msOpt(Percentile.of(s.latenciesNs, 0.95))) | \(s.gapCount) |\n"
        }
        out += "\nLatency is `trigger.t_ns - labelled second onset`, over matched groups whose "
        out += "label confidence is not `prompt_window`.\n"
        return out
    }

    private static func aggregateTable(_ aggs: [Aggregate]) -> String {
        var out = "| scope | sessions | dur (min) | double groups | detected | rate | triggers | FP | FP/20min | lat p50 | lat p95 | lat max |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for a in aggs {
            out += "| \(a.label) | \(a.sessions) | "
            out += String(format: "%.1f", a.durationSeconds / 60) + " | "
            out += "\(a.doubleGroups) | \(a.detectedGroups) | \(Fmt.pct(a.detectionRate)) | "
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
        out += "sessions    \(r.sessions.count)   wall time "
        out += String(format: "%.1f min\n", r.pooled.durationSeconds / 60)
        out += "\n"
        out += pad("scope", 10) + pad("sess", 6) + pad("groups", 8) + pad("det", 6)
        out += pad("rate", 10) + pad("trig", 6) + pad("FP", 5) + pad("FP/20m", 9)
        out += pad("p50", 10) + pad("p95", 10) + "max\n"
        for a in [r.pooled] + r.perSurface {
            out += pad(a.label, 10) + pad("\(a.sessions)", 6) + pad("\(a.doubleGroups)", 8)
            out += pad("\(a.detectedGroups)", 6) + pad(Fmt.pct(a.detectionRate), 10)
            out += pad("\(a.triggerCount)", 6) + pad("\(a.falsePositives)", 5)
            out += pad(Fmt.num(a.falsePositivesPer20Min), 9)
            out += pad(Fmt.msOpt(a.latencyP50Ns), 10) + pad(Fmt.msOpt(a.latencyP95Ns), 10)
            out += Fmt.msOpt(a.latencyMaxNs) + "\n"
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
