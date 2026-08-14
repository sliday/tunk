import Foundation
import TunkCore
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

    /// A session has to hold at least this much recorded time before an absence
    /// of false triggers in it means anything. Below this the check reports no
    /// data rather than a pass, so an empty or truncated recording cannot be
    /// mistaken for a clean one.
    static let minimumMeaningfulSeconds: Double = 5.0
    static let requiredSurfaces: [Surface] = [.desk, .soft, .lap]

    /// Build the checks for one scope (a surface, or the pooled set).
    /// " — 2 of 19 credits disagree by > 40 ms", or empty when none do.
    static func cleanSuffix(for agg: Aggregate) -> String {
        let loose = agg.perCount.reduce(0) { $0 + $1.creditsOver40ms }
        guard loose > 0 else { return "" }
        return String(format: " — %d of %d credits disagree with the label by > 40 ms",
                      loose, agg.detectedGroups)
    }

    /// The filter coefficients are computed once, from `DSPTuning.sampleRateHz`.
    /// A recording at a materially different rate is therefore replayed through
    /// a chain tuned for a rate it does not have, and nothing downstream notices:
    /// the gap check compares against the session's OWN measured cadence, so a
    /// uniformly half-rate stream has no gaps at all.
    ///
    /// Measured by decimating the corpus 2:1 to 398 Hz: pooled detection falls
    /// 82.11 % to 72.36 %, soft 100 % to 50 %, p95 latency unchanged, gapCount
    /// zero on every session. Every existing check passes while the detector is
    /// quietly crippled. This is that check.
    static let sampleRateTolerance = 0.10

    static func checks(for agg: Aggregate, scope: String) -> [Check] {
        var out: [Check] = []

        out.append(Check(
            name: "detection rate, all armed gestures",
            scope: scope,
            requirement: "≥ 98 %",
            // The contract rate decides pass or fail, per FORMAT.md. The clean
            // count rides alongside it because the contract credits a trigger on
            // the strength of ONE number — its last onset against the label's
            // last — and a lap ring lobe sits about 25 ms from its strike, so a
            // credit disagreeing by 40-60 ms can be firing on the wrong
            // transient and still count. Printing only the contract rate is how
            // a front-end change once read as three recovered gestures when one
            // was clean.
            actual: agg.armedGroups == 0 ? "no labelled groups for an armed tap count"
                : String(format: "%.2f %% (%d/%d)%@", (agg.detectionRate ?? 0) * 100,
                         agg.detectedGroups, agg.armedGroups,
                         Self.cleanSuffix(for: agg)),
            status: agg.armedGroups == 0 ? .noData
                : ((agg.detectionRate ?? 0) + 1e-9 >= detectionRateFloor ? .pass : .fail)
        ))

        // Sample rate against the rate the filters were designed for.
        let expected = DSPTuning.default.sampleRateHz
        let measured = agg.durationSeconds > 0
            ? Double(agg.sampleCount) / agg.durationSeconds : 0
        let ratio = expected > 0 ? measured / expected : 0
        out.append(Check(
            name: "sample rate matches the filter design",
            scope: scope,
            requirement: String(format: "%.0f Hz ± %.0f %%", expected, sampleRateTolerance * 100),
            actual: agg.durationSeconds <= 0 ? "no samples"
                : String(format: "%.1f Hz (%.0f %% of design)", measured, ratio * 100),
            status: agg.durationSeconds <= 0 ? .noData
                : (abs(ratio - 1) <= sampleRateTolerance ? .pass : .fail)
        ))

        out.append(contentsOf: perCountChecks(for: agg, scope: scope))

        // The make-or-break metric. An empty or near-empty typing session must
        // never be able to satisfy it — this is the one check where a false
        // green is worse than no answer at all.
        out.append(Check(
            name: "false triggers, typing sessions",
            scope: scope,
            requirement: "= 0",
            actual: agg.typingSessions == 0 ? "no typing sessions"
                : agg.typingSeconds < minimumMeaningfulSeconds
                    ? String(format: "%d typing session(s) holding only %.1f s of data",
                             agg.typingSessions, agg.typingSeconds)
                    : String(format: "%d in %d session(s), %.1f min (%.1f min un-gated)",
                             agg.typingFalsePositives, agg.typingSessions,
                             agg.typingSeconds / 60, agg.typingUngatedSeconds / 60),
            status: agg.typingSessions == 0 || agg.typingSeconds < minimumMeaningfulSeconds
                ? .noData : (agg.typingFalsePositives == 0 ? .pass : .fail)
        ))

        // Counting sessions is not enough. A session file with zero samples in
        // it is still one session, and it used to satisfy this check outright:
        // an empty directory bought a green "0 false triggers in 1 session".
        // Recorded seconds is the thing that makes the check mean something.
        //
        // Recorded seconds was not enough either. A full-length recording of a
        // quiet room is still a quiet room, and `data/raw` holds one: a
        // `confound_music` session whose loudest sample step is 0.0007 g, below
        // both idle sessions. It ran the clock and bought the same green. Any
        // confound session that never disturbed the chassis is dropped from the
        // count here and named in the text, so an operator who mis-records one
        // reads "1 inert" instead of a pass.
        let inertNote = agg.inertConfoundSessions == 0 ? ""
            : String(format: " — %d inert session(s) excluded (nothing above an idle room)",
                     agg.inertConfoundSessions)
        out.append(Check(
            name: "false triggers, confound sessions",
            scope: scope,
            requirement: "= 0",
            actual: agg.confoundSessions == 0
                ? (agg.inertConfoundSessions == 0 ? "no confound sessions"
                   : String(format: "no usable confound sessions — all %d were inert",
                            agg.inertConfoundSessions))
                : agg.confoundSeconds < minimumMeaningfulSeconds
                    ? String(format: "%d confound session(s) holding only %.1f s of data",
                             agg.confoundSessions, agg.confoundSeconds)
                    : String(format: "%d in %d session(s), %.1f min",
                             agg.confoundFalsePositives, agg.confoundSessions,
                             agg.confoundSeconds / 60) + inertNote,
            status: agg.confoundSessions == 0 || agg.confoundSeconds < minimumMeaningfulSeconds
                ? .noData : (agg.confoundFalsePositives == 0 ? .pass : .fail)
        ))

        out.append(Check(
            name: "false triggers per 20 min, all sessions",
            scope: scope,
            requirement: "< 1",
            actual: agg.durationSeconds < minimumMeaningfulSeconds
                ? String(format: "only %.1f s of recorded data", agg.durationSeconds)
                : agg.falsePositivesPer20Min.map { String(format: "%.2f (%d in %.1f min)",
                        $0, agg.falsePositives, agg.durationSeconds / 60) } ?? "no duration",
            status: agg.durationSeconds < minimumMeaningfulSeconds ? .noData
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
                    actual: agg.durationSeconds < minimumMeaningfulSeconds
                        ? String(format: "only %.1f s of recorded data", agg.durationSeconds)
                        : rate.map { String(format: "%.2f (%d in %.1f min)", $0, c.falseTriggers,
                                            agg.durationSeconds / 60) } ?? "no duration",
                    status: agg.durationSeconds < minimumMeaningfulSeconds ? .noData
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
