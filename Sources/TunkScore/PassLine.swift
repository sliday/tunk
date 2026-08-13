import Foundation
import TunkFormat

/// The pass line from FORMAT.md, as code. A check with no data behind it is never
/// a pass: the run comes back INCOMPLETE, which is not the same as FAIL and must
/// not be reported as one.
enum CheckStatus: String, Codable { case pass, fail, noData = "no_data" }

struct Check: Codable {
    var name: String
    var scope: String
    var requirement: String
    var actual: String
    var status: CheckStatus
}

enum RunVerdict: String, Codable { case pass = "PASS", fail = "FAIL", incomplete = "INCOMPLETE" }

enum PassLine {
    static let detectionRateFloor = 0.98
    static let latencyP95CeilingNs: Int64 = 250_000_000
    static let falsePositivesPer20MinCeiling = 1.0
    static let requiredSurfaces: [Surface] = [.desk, .soft, .lap]

    /// Build the checks for one scope (a surface, or the pooled set).
    static func checks(for agg: Aggregate, scope: String) -> [Check] {
        var out: [Check] = []

        out.append(Check(
            name: "detection rate, all armed gestures",
            scope: scope,
            requirement: "≥ 98 %",
            actual: agg.armedGroups == 0 ? "no labelled groups for an armed tap count"
                : String(format: "%.2f %% (%d/%d)", (agg.detectionRate ?? 0) * 100,
                         agg.detectedGroups, agg.armedGroups),
            status: agg.armedGroups == 0 ? .noData
                : ((agg.detectionRate ?? 0) + 1e-9 >= detectionRateFloor ? .pass : .fail)
        ))

        out.append(contentsOf: perCountChecks(for: agg, scope: scope))

        out.append(Check(
            name: "false triggers, typing sessions",
            scope: scope,
            requirement: "= 0",
            actual: agg.typingSessions == 0 ? "no typing sessions"
                : "\(agg.typingFalsePositives) in \(agg.typingSessions) session(s)",
            status: agg.typingSessions == 0 ? .noData : (agg.typingFalsePositives == 0 ? .pass : .fail)
        ))

        out.append(Check(
            name: "false triggers, confound sessions",
            scope: scope,
            requirement: "= 0",
            actual: agg.confoundSessions == 0 ? "no confound sessions"
                : "\(agg.confoundFalsePositives) in \(agg.confoundSessions) session(s)",
            status: agg.confoundSessions == 0 ? .noData : (agg.confoundFalsePositives == 0 ? .pass : .fail)
        ))

        out.append(Check(
            name: "false triggers per 20 min, all sessions",
            scope: scope,
            requirement: "< 1",
            actual: agg.falsePositivesPer20Min.map { String(format: "%.2f (%d in %.1f min)",
                        $0, agg.falsePositives, agg.durationSeconds / 60) } ?? "no duration",
            status: agg.durationSeconds <= 0 ? .noData
                : ((agg.falsePositivesPer20Min ?? 0) < falsePositivesPer20MinCeiling ? .pass : .fail)
        ))

        out.append(Check(
            name: "latency p95",
            scope: scope,
            requirement: "≤ 250 ms",
            actual: agg.latencyP95Ns.map { Fmt.ms($0) } ?? "no matched groups",
            status: agg.latencyP95Ns == nil ? .noData
                : (agg.latencyP95Ns! <= latencyP95CeilingNs ? .pass : .fail)
        ))

        out.append(Check(
            name: "replay delivery order violations",
            scope: scope,
            requirement: "= 0",
            actual: "\(agg.deliveryOrderViolations)",
            status: agg.sessions == 0 ? .noData : (agg.deliveryOrderViolations == 0 ? .pass : .fail)
        ))

        return out
    }

    /// Per-tap-count rows. Under the Back Tap model each armed count is its own
    /// gesture with its own bound action, so each gets its own detection rate and
    /// its own false-trigger rate. The 1-tap row is the one that decides whether
    /// single-tap ships, so it is never folded into the pooled number.
    static func perCountChecks(for agg: Aggregate, scope: String) -> [Check] {
        var out: [Check] = []
        let interesting = agg.perCount
            .filter { $0.armed || $0.labelledGroups > 0 || $0.triggers > 0 }
            .sorted { $0.count < $1.count }

        for c in interesting where c.armed {
            out.append(Check(
                name: "detection rate, \(c.count)-tap",
                scope: scope,
                requirement: "≥ 98 %",
                actual: c.labelledGroups == 0 ? "no labelled \(c.count)-tap groups"
                    : String(format: "%.2f %% (%d/%d)", (c.detectionRate ?? 0) * 100,
                             c.detectedGroups, c.labelledGroups),
                status: c.labelledGroups == 0 ? .noData
                    : ((c.detectionRate ?? 0) + 1e-9 >= detectionRateFloor ? .pass : .fail)
            ))
        }

        for c in interesting {
            let rate = agg.falseTriggersPer20Min(count: c.count)
            if c.armed {
                out.append(Check(
                    name: "false triggers per 20 min, \(c.count)-tap",
                    scope: scope,
                    requirement: "< 1",
                    actual: rate.map { String(format: "%.2f (%d in %.1f min)", $0, c.falseTriggers,
                                              agg.durationSeconds / 60) } ?? "no duration",
                    status: agg.durationSeconds <= 0 ? .noData
                        : ((rate ?? 0) < falsePositivesPer20MinCeiling ? .pass : .fail)
                ))
            } else {
                // Not armed: the count must never fire at all, so the bar is zero
                // triggers, not a rate.
                out.append(Check(
                    name: "triggers on un-armed \(c.count)-tap",
                    scope: scope,
                    requirement: "= 0",
                    actual: "\(c.triggers) trigger(s) fired \(c.count) tap(s)",
                    status: c.triggers == 0 ? .pass : .fail
                ))
            }
        }

        // A labelled gesture the detector is not armed for is a trap, not a target.
        if agg.mustNotFireGroups > 0 {
            out.append(Check(
                name: "labelled must-not-fire gestures that fired",
                scope: scope,
                requirement: "= 0",
                actual: "\(agg.mustNotFireViolations) of \(agg.mustNotFireGroups) group(s)",
                status: agg.mustNotFireViolations == 0 ? .pass : .fail
            ))
        }

        return out
    }

    /// Typing and confound false triggers, plus detection rate, are graded per
    /// surface *separately* per FORMAT.md, not on the pooled average.
    static func verdict(perSurface: [String: Aggregate], pooled: Aggregate) -> (RunVerdict, [Check]) {
        var all: [Check] = []
        for s in requiredSurfaces {
            if let agg = perSurface[s.rawValue] {
                all.append(contentsOf: checks(for: agg, scope: s.rawValue))
            } else {
                all.append(Check(name: "surface coverage", scope: s.rawValue,
                                 requirement: "at least one session",
                                 actual: "none recorded", status: .noData))
            }
        }
        all.append(contentsOf: checks(for: pooled, scope: "pooled"))

        if all.contains(where: { $0.status == .fail }) { return (.fail, all) }
        if all.contains(where: { $0.status == .noData }) { return (.incomplete, all) }
        return (.pass, all)
    }
}

enum Fmt {
    static func ms(_ ns: Int64) -> String { String(format: "%.1f ms", Double(ns) / 1e6) }
    static func msOpt(_ ns: Int64?) -> String { ns.map(ms) ?? "—" }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.2f %%", $0 * 100) } ?? "—" }
    static func num(_ v: Double?, _ digits: Int = 2) -> String {
        v.map { String(format: "%.\(digits)f", $0) } ?? "—"
    }
    static func secs(_ s: Double) -> String { String(format: "%.1f s", s) }
}
