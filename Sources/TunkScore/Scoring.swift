import Foundation
import TunkCore
import TunkFormat

/// Matching and metric definitions, straight out of the Scoring section of
/// FORMAT.md. Nothing here is negotiable by a builder; if a number looks wrong,
/// argue with the definition, not with this file.
enum Scoring {
    /// FORMAT.md: a labelled group counts as detected when exactly one trigger has
    /// its last tap onset within +/-150 ms of the labelled last onset.
    static let matchWindowNs: Int64 = 150_000_000

    /// How far the trigger's onset vector may drift from the labelled one
    /// before the credit is flagged as landing on different physical events.
    ///
    /// This is `TunkLabel.minGapNs`: the smallest spacing at which the labeller
    /// itself will call two peaks two separate taps. Any disagreement smaller
    /// than that is the same strike attributed to a different crest, which is
    /// jitter, not a mis-credit.
    static let onsetAgreementNs: Int64 = 80_000_000
}

/// Which tap counts the detector is allowed to fire on this run.
///
/// The detector is being generalised to the iPhone Back Tap model: single, double
/// and triple each bind to their own action. Everything that is *not* armed must
/// never fire, so the policy is what turns a labelled gesture into either a
/// detection denominator or a must-not-fire trap.
///
/// The default comes from `DetectorConfig.armedTapCounts`, the same stored set
/// the detector fires on; `--armed 1,2,3` overrides it. Reading `tapCountToFire`
/// here instead was lossy — that accessor is `armedTapCounts.min()`, so a config
/// armed for 1 and 2 graded as if only 1 were armed, and every real double-tap
/// became a must-not-fire violation.
struct ScoringPolicy: Codable, Equatable {
    /// Sorted, unique.
    let armedCounts: [Int]

    init(armedCounts: [Int]) {
        self.armedCounts = Array(Set(armedCounts.filter { $0 >= 1 })).sorted()
    }

    func isArmed(_ n: Int) -> Bool { armedCounts.contains(n) }

    static func from(config: DetectorConfig, override: [Int]?) -> ScoringPolicy {
        ScoringPolicy(armedCounts: override ?? config.armedTapCounts.sorted())
    }

    /// Parse `--armed 1,2,3`.
    static func parse(_ raw: String) throws -> [Int] {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { throw CLIError.usage("--armed needs at least one tap count") }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 1 else {
                throw CLIError.usage("--armed expects comma-separated tap counts >= 1, got '\(p)'")
            }
            out.append(n)
        }
        return out
    }

    var text: String { armedCounts.map(String.init).joined(separator: ",") }
}

/// Why a labelled group was or was not detected. `explain` prints this verbatim.
enum GroupVerdict: String, Codable {
    case detected
    /// Credited, but the trigger's onsets do not line up with the labelled ones.
    ///
    /// Matching tests one number: the trigger's LAST onset against the label's
    /// last onset. It never looks at the others. So a trigger built from the
    /// first strike plus a ring lobe can be credited with detecting a gesture
    /// whose real second strike arrived later — the right verdict on the wrong
    /// physical event. Measured on training data: 2 of 20 soft credits.
    ///
    /// These still count as detections, because the detector did fire once
    /// inside a gesture the operator actually made, and FORMAT.md's contract
    /// says so. They are counted separately as well, so a reader can see how
    /// much of a detection rate rests on them.
    case detectedLooseOnsets
    /// The group is armed, and nothing fired on it.
    case missed
    /// More than one trigger landed in the window: not "exactly one", so the group
    /// is not detected and the surplus triggers count as false positives.
    case ambiguous
    /// The group is a gesture the detector is not armed for (a labelled single tap
    /// while only double is armed), or `intent = none`. Nothing may fire here.
    case mustNotFire
    /// Same as `mustNotFire`, except something fired anyway. Every trigger in that
    /// window is a false positive. This is the case the old scorer swallowed.
    case firedWhenItMustNot
}

struct GroupOutcome: Codable {
    var group: Int
    /// Onsets in the labelled group. This, not the `intent` word, is what the
    /// harness scores against, so a three-onset group is a 3-tap gesture.
    var tapCount: Int
    var intent: String
    var confidence: String
    var firstOnsetNs: Int64?
    /// Last labelled onset of the group. Matching is measured against this.
    var lastOnsetNs: Int64
    var armed: Bool
    var verdict: GroupVerdict
    /// Triggers of any tap count inside the +/-150 ms window.
    var nearbyTriggers: Int
    /// Unclaimed triggers inside the window whose tap count matches this group.
    var candidateTriggers: Int
    /// Unclaimed triggers inside the window that fired a *different* number of taps.
    /// A 2-tap trigger sitting on a labelled single tap lands here, and stays a
    /// false positive.
    var wrongCountTriggers: Int
    var matchedTriggerIndex: Int?
    /// `trigger.t_ns - labelled last onset`. The honest latency: measured against
    /// ground truth, not against the detector's own idea of the onset.
    var latencyNs: Int64?
    /// `detector last onset - labelled last onset`, for onset-accuracy debugging.
    var onsetErrorNs: Int64?
    /// Spread of (trigger onset i - labelled onset i) across the whole vector.
    /// Zero-ish means the trigger fired on the same physical strikes the label
    /// names; large means it fired on different ones and was credited anyway,
    /// because matching only ever tested the last onset.
    var onsetSpreadNs: Int64?
}

struct TriggerOutcome: Codable {
    var index: Int
    var tNs: Int64
    var tapOnsets: [Int64]
    /// How many taps this trigger fired on. False triggers are attributed to it.
    var tapCount: Int
    var score: Double
    var matchedGroup: Int?
    var isFalsePositive: Bool
    /// Distance to the nearest labelled last onset, when there is one.
    var nearestLabelNs: Int64?
    /// Plain English, for the critic. Empty when the trigger matched.
    var falseTriggerReason: String
}

/// Per-tap-count breakdown. The single-tap row is the number that decides whether
/// single-tap ships at all, so it is a first-class metric, not a footnote.
struct CountStats: Codable {
    var count: Int
    var armed: Bool
    /// Labelled gesture groups with this many onsets (`intent != none`).
    var labelledGroups = 0
    var detectedGroups = 0
    /// Of `detectedGroups`, those credited on an onset vector that disagrees
    /// with the labelled one by more than `Scoring.onsetAgreementNs`. Counted so
    /// a detection rate can be read strictly as well as by the contract.
    var looseOnsetCredits = 0
    /// Onset spreads of every credit, so a reader can see HOW MUCH the trigger's
    /// onsets disagreed with the label rather than only whether they crossed one
    /// line. The 80 ms line is the labeller's own two-tap floor and is
    /// defensible, but a lap ring lobe sits about 25 ms from its strike, so a
    /// credit disagreeing by 40-60 ms may still be firing on a lobe two steps
    /// away and pass. That case is real: two of three held-out lap gestures a
    /// front-end change recovered had spreads of 41.3 and 61.3 ms. Publishing
    /// the distribution stops one threshold from having to carry the argument.
    var onsetSpreadsNs: [Int64] = []
    var ambiguousGroups = 0
    var missedGroups = 0
    /// Labelled groups of this count that the detector is not armed for.
    var mustNotFireGroups = 0
    /// ...of which something fired on anyway.
    var mustNotFireViolations = 0
    /// Triggers whose `tapCount` is this count.
    var triggers = 0
    /// ...that matched no labelled group of the same count. The false-trigger
    /// number, attributed to the count that fired.
    var falseTriggers = 0
    var latencyExcluded = 0
    var latenciesNs: [Int64] = []

    init(count: Int, armed: Bool) {
        self.count = count
        self.armed = armed
    }

    var detectionRate: Double? {
        guard armed, labelledGroups > 0 else { return nil }
        return Double(detectedGroups) / Double(labelledGroups)
    }
    /// Detection rate counting only credits whose onsets line up with the label.
    /// Reported beside `detectionRate`, never instead of it: the contract in
    /// FORMAT.md defines the headline, and replacing it silently would be the
    /// same sin the harness exists to prevent.
    var strictDetectionRate: Double? {
        guard armed, labelledGroups > 0 else { return nil }
        return Double(detectedGroups - looseOnsetCredits) / Double(labelledGroups)
    }
    /// Credits whose onsets disagree with the label by more than 40 ms — half
    /// the labeller's two-tap floor, and above the ~25 ms lap ring-lobe spacing.
    /// Reported alongside, never instead of, the contract rate.
    var creditsOver40ms: Int { onsetSpreadsNs.filter { $0 > 40_000_000 }.count }
    var onsetSpreadP50Ns: Int64? { Percentile.of(onsetSpreadsNs, 0.50) }
    var onsetSpreadMaxNs: Int64? { onsetSpreadsNs.max() }
    var latencyP50Ns: Int64? { Percentile.of(latenciesNs, 0.50) }
    var latencyP95Ns: Int64? { Percentile.of(latenciesNs, 0.95) }
    var latencyMaxNs: Int64? { latenciesNs.max() }

    mutating func merge(_ o: CountStats) {
        armed = armed || o.armed
        labelledGroups += o.labelledGroups
        detectedGroups += o.detectedGroups
        looseOnsetCredits += o.looseOnsetCredits
        onsetSpreadsNs.append(contentsOf: o.onsetSpreadsNs)
        ambiguousGroups += o.ambiguousGroups
        missedGroups += o.missedGroups
        mustNotFireGroups += o.mustNotFireGroups
        mustNotFireViolations += o.mustNotFireViolations
        triggers += o.triggers
        falseTriggers += o.falseTriggers
        latencyExcluded += o.latencyExcluded
        latenciesNs.append(contentsOf: o.latenciesNs)
    }

    enum CodingKeys: String, CodingKey {
        case count, armed, labelledGroups, detectedGroups, looseOnsetCredits
        case onsetSpreadsNs, creditsOver40ms, onsetSpreadP50Ns, onsetSpreadMaxNs
        case ambiguousGroups, missedGroups
        case mustNotFireGroups, mustNotFireViolations, triggers, falseTriggers
        case latencyExcluded, latenciesNs
        case detectionRate, strictDetectionRate, latencyP50Ns, latencyP95Ns, latencyMaxNs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encode(armed, forKey: .armed)
        try c.encode(labelledGroups, forKey: .labelledGroups)
        try c.encode(detectedGroups, forKey: .detectedGroups)
        try c.encode(looseOnsetCredits, forKey: .looseOnsetCredits)
        try c.encode(onsetSpreadsNs, forKey: .onsetSpreadsNs)
        try c.encode(creditsOver40ms, forKey: .creditsOver40ms)
        try c.encodeIfPresent(onsetSpreadP50Ns, forKey: .onsetSpreadP50Ns)
        try c.encodeIfPresent(onsetSpreadMaxNs, forKey: .onsetSpreadMaxNs)
        try c.encode(ambiguousGroups, forKey: .ambiguousGroups)
        try c.encode(missedGroups, forKey: .missedGroups)
        try c.encode(mustNotFireGroups, forKey: .mustNotFireGroups)
        try c.encode(mustNotFireViolations, forKey: .mustNotFireViolations)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(falseTriggers, forKey: .falseTriggers)
        try c.encode(latencyExcluded, forKey: .latencyExcluded)
        try c.encode(latenciesNs, forKey: .latenciesNs)
        try c.encodeIfPresent(detectionRate, forKey: .detectionRate)
        try c.encodeIfPresent(strictDetectionRate, forKey: .strictDetectionRate)
        try c.encodeIfPresent(latencyP50Ns, forKey: .latencyP50Ns)
        try c.encodeIfPresent(latencyP95Ns, forKey: .latencyP95Ns)
        try c.encodeIfPresent(latencyMaxNs, forKey: .latencyMaxNs)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
        armed = try c.decode(Bool.self, forKey: .armed)
        labelledGroups = try c.decode(Int.self, forKey: .labelledGroups)
        detectedGroups = try c.decode(Int.self, forKey: .detectedGroups)
        looseOnsetCredits = try c.decodeIfPresent(Int.self, forKey: .looseOnsetCredits) ?? 0
        onsetSpreadsNs = try c.decodeIfPresent([Int64].self, forKey: .onsetSpreadsNs) ?? []
        ambiguousGroups = try c.decode(Int.self, forKey: .ambiguousGroups)
        missedGroups = try c.decode(Int.self, forKey: .missedGroups)
        mustNotFireGroups = try c.decode(Int.self, forKey: .mustNotFireGroups)
        mustNotFireViolations = try c.decode(Int.self, forKey: .mustNotFireViolations)
        triggers = try c.decode(Int.self, forKey: .triggers)
        falseTriggers = try c.decode(Int.self, forKey: .falseTriggers)
        latencyExcluded = try c.decode(Int.self, forKey: .latencyExcluded)
        latenciesNs = try c.decodeIfPresent([Int64].self, forKey: .latenciesNs) ?? []
    }
}

/// One session's grade.
struct SessionScore: Codable {
    var sessionId: String
    var category: String
    var surface: String
    var split: String
    var expectedTriggers: Int
    var durationSeconds: Double
    var sampleCount: Int
    var inputCount: Int
    var gatingInputCount: Int
    /// Seconds of this session where the input gate was NOT muting the detector.
    /// The honest denominator for any false-trigger claim about typing.
    var ungatedSeconds: Double = 0
    var gapCount: Int
    var largestGapNs: Int64
    var unsortedSamples: Int
    var unsortedInputs: Int
    var deliveryOrderViolations: Int

    var armedCounts: [Int]
    /// Labelled gesture groups whose tap count is armed. The detection denominator.
    var armedGroups: Int
    var detectedGroups: Int
    var ambiguousGroups: Int
    /// Labelled gestures the detector must never fire on (unarmed counts, or
    /// `intent = none`).
    var mustNotFireGroups: Int
    /// ...that something fired on anyway.
    var mustNotFireViolations: Int
    var triggerCount: Int
    var falsePositives: Int
    /// Groups excluded from latency because `confidence == prompt_window`.
    var latencyExcluded: Int
    var latenciesNs: [Int64]
    var perCount: [CountStats]
    var groups: [GroupOutcome]
    var triggers: [TriggerOutcome]
    /// Labelling problems the harness noticed. Surfaced as run warnings, never
    /// silently swallowed.
    var labelIssues: [String]

    var detectionRate: Double? {
        armedGroups == 0 ? nil : Double(detectedGroups) / Double(armedGroups)
    }
}

enum SessionScorer {
    /// Grade one replay against one session's labels.
    ///
    /// Assignment is greedy in time: groups are walked in ascending order of their
    /// labelled last onset, and each takes the closest unclaimed trigger inside the
    /// +/-150 ms window **that fired the same number of taps**. A group with two or
    /// more such candidates is `ambiguous` (not detected) and gives up all but the
    /// closest, which keeps the surplus in the false-positive column where
    /// FORMAT.md puts it.
    ///
    /// A group the detector is not armed for claims nothing at all. That is the
    /// whole point: a trigger next to a labelled single tap, while single is not
    /// armed, is a false positive and has to be counted as one.
    static func score(session: Session, replay: ReplayResult, policy: ScoringPolicy) throws -> SessionScore {
        let meta = session.meta
        let groups = try session.labelGroups()
        let triggers = replay.triggers

        func triggerOnsetNs(_ t: Trigger) -> Int64 { t.tapOnsets.last ?? t.tNs }

        var claimedBy = [Int?](repeating: nil, count: triggers.count)
        var outcomes: [GroupOutcome] = []
        var latencies: [Int64] = []
        var issues: [String] = []
        var counts: [Int: CountStats] = [:]

        func stats(_ n: Int) -> CountStats {
            counts[n] ?? CountStats(count: n, armed: policy.isArmed(n))
        }

        struct GroupKey { var id: Int; var rows: [TapLabel]; var lastNs: Int64 }
        let keyed: [GroupKey] = groups.compactMap { rows in
            guard let last = rows.last, let id = rows.first?.group else { return nil }
            return GroupKey(id: id, rows: rows, lastNs: last.tNs)
        }.sorted { $0.lastNs < $1.lastNs }

        var detected = 0, ambiguous = 0, armedGroups = 0
        var looseOnsetCredits = 0
        var mustNotFire = 0, mustNotFireViolations = 0, latencyExcluded = 0

        for g in keyed {
            let intent = g.rows.last!.intent
            let confidence = g.rows.last!.confidence
            let n = g.rows.count
            let isGesture = intent != TapIntent.none
            let armed = isGesture && policy.isArmed(n)

            // FORMAT.md's `intent` vocabulary is single/double/none. The onset count
            // is what actually defines the gesture, so a disagreement is a labelling
            // bug worth shouting about rather than quietly resolving.
            if isGesture {
                let implied = (intent == .single) ? 1 : 2
                if n != implied {
                    issues.append("\(meta.sessionId): group \(g.id) has \(n) onset(s) but intent "
                                  + "'\(intent.rawValue)'. Scored as a \(n)-tap gesture (onset count wins).")
                }
            }

            let window = triggers.indices.filter {
                abs(triggerOnsetNs(triggers[$0]) - g.lastNs) <= Scoring.matchWindowNs
            }
            let unclaimed = window.filter { claimedBy[$0] == nil }
            let sameCount = unclaimed.filter { triggers[$0].tapCount == n }
            let wrongCount = unclaimed.count - sameCount.count

            var outcome = GroupOutcome(
                group: g.id, tapCount: n, intent: intent.rawValue, confidence: confidence.rawValue,
                firstOnsetNs: g.rows.first?.tNs, lastOnsetNs: g.lastNs, armed: armed,
                verdict: .missed, nearbyTriggers: window.count,
                candidateTriggers: sameCount.count, wrongCountTriggers: wrongCount,
                matchedTriggerIndex: nil, latencyNs: nil, onsetErrorNs: nil
            )

            var s = stats(n)
            if isGesture { s.labelledGroups += 1 }

            if !armed {
                // Nothing may fire here, so nothing gets claimed and every trigger in
                // the window stays in the false-positive column.
                mustNotFire += 1
                if isGesture { s.mustNotFireGroups += 1 }
                // `unclaimed`, not `window`: a trigger already credited to an
                // armed group must not also be booked as a violation here. No
                // real recording has an unarmed label close enough for this to
                // bite, but the asymmetry was reachable with a planted label.
                if unclaimed.isEmpty {
                    outcome.verdict = .mustNotFire
                } else {
                    outcome.verdict = .firedWhenItMustNot
                    mustNotFireViolations += 1
                    if isGesture { s.mustNotFireViolations += 1 }
                }
                counts[n] = s
                outcomes.append(outcome)
                continue
            }

            armedGroups += 1
            if let best = sameCount.min(by: {
                abs(triggerOnsetNs(triggers[$0]) - g.lastNs) < abs(triggerOnsetNs(triggers[$1]) - g.lastNs)
            }) {
                claimedBy[best] = g.id
                outcome.matchedTriggerIndex = best
                outcome.latencyNs = triggers[best].tNs - g.lastNs
                outcome.onsetErrorNs = triggerOnsetNs(triggers[best]) - g.lastNs
                if sameCount.count == 1 {
                    // Compare the WHOLE onset vector, not just the last one.
                    // The per-session lead (the detector crosses threshold
                    // before the labeller's peak, by 8-34 ms depending on the
                    // session) is common to every onset, so it cancels in the
                    // spread and only real disagreement survives.
                    let onsets = triggers[best].tapOnsets
                    if onsets.count == g.rows.count, onsets.count > 1 {
                        let residuals = zip(onsets, g.rows).map { $0 - $1.tNs }
                        let spread = (residuals.max() ?? 0) - (residuals.min() ?? 0)
                        outcome.onsetSpreadNs = spread
                    }
                    // 80 ms is TunkLabel's own `minGapNs`: the smallest spacing
                    // at which the labeller will call two peaks two taps. Below
                    // it, a disagreement is provably the same physical strike
                    // attributed to a different crest, not a different event.
                    let loose = (outcome.onsetSpreadNs ?? 0) > Scoring.onsetAgreementNs
                    outcome.verdict = loose ? .detectedLooseOnsets : .detected
                    detected += 1
                    s.detectedGroups += 1
                    if loose { looseOnsetCredits += 1; s.looseOnsetCredits += 1 }
                    if let spread = outcome.onsetSpreadNs { s.onsetSpreadsNs.append(spread) }
                    if confidence == .promptWindow {
                        latencyExcluded += 1
                        s.latencyExcluded += 1
                    } else {
                        latencies.append(outcome.latencyNs!)
                        s.latenciesNs.append(outcome.latencyNs!)
                    }
                } else {
                    outcome.verdict = .ambiguous
                    ambiguous += 1
                    s.ambiguousGroups += 1
                }
            } else {
                outcome.verdict = .missed
                s.missedGroups += 1
            }
            counts[n] = s
            outcomes.append(outcome)
        }

        // Nearest labelled group, for the "why is this a false positive" narrative.
        func nearestGroup(_ t: Trigger) -> (GroupKey, Int64)? {
            var best: (GroupKey, Int64)?
            for g in keyed {
                let d = abs(triggerOnsetNs(t) - g.lastNs)
                if best == nil || d < best!.1 { best = (g, d) }
            }
            return best
        }

        var triggerOutcomes: [TriggerOutcome] = []
        var falsePositives = 0
        for (i, t) in triggers.enumerated() {
            let n = t.tapCount
            var s = stats(n)
            s.triggers += 1

            let near = nearestGroup(t)
            let matched = claimedBy[i]
            let isFP = matched == nil
            var reason = ""
            if isFP {
                falsePositives += 1
                s.falseTriggers += 1
                if let (g, d) = near, d <= Scoring.matchWindowNs {
                    let gn = g.rows.count
                    let gIntent = g.rows.last!.intent
                    if gIntent == TapIntent.none {
                        reason = "landed on labelled group \(g.id), whose intent is 'none'"
                    } else if !policy.isArmed(gn) {
                        reason = "fired on labelled \(gn)-tap group \(g.id); \(gn)-tap is NOT armed, "
                            + "so this gesture must never fire"
                    } else if gn != n {
                        reason = "fired \(n) tap(s) on a labelled \(gn)-tap gesture (group \(g.id))"
                    } else {
                        reason = "surplus trigger inside the window of group \(g.id), which another "
                            + "trigger already claimed"
                    }
                } else {
                    reason = "no labelled gesture within ±150 ms"
                }
            }
            counts[n] = s

            triggerOutcomes.append(TriggerOutcome(
                index: i, tNs: t.tNs, tapOnsets: t.tapOnsets, tapCount: n, score: t.score,
                matchedGroup: matched, isFalsePositive: isFP,
                nearestLabelNs: near?.1, falseTriggerReason: reason
            ))
        }

        // Every armed count shows up in the table even when nothing happened, so a
        // missing row can never be mistaken for a clean one.
        for n in policy.armedCounts where counts[n] == nil {
            counts[n] = CountStats(count: n, armed: true)
        }

        // Rates are per unit of time, so whatever supplies the denominator
        // decides whether the make-or-break metric passes. Trust the SAMPLES,
        // not `meta.durationNs`: meta is a claim written by the capture tool,
        // while the span is the data itself. A session declaring an hour and
        // holding a thousand samples used to report "0 false triggers in
        // 60.0 min" and buy a pass with 1.3 seconds of silence.
        //
        // The smaller of the two is the honest denominator — a claim can only
        // ever shorten the window, never lengthen it beyond what was recorded.
        let spanSec = Double(replay.spanNs) / 1e9
        let claimedSec = Double(meta.durationNs) / 1e9
        let durationSec: Double = {
            if spanSec > 0 && claimedSec > 0 { return min(spanSec, claimedSec) }
            return max(spanSec, 0)
        }()

        return SessionScore(
            sessionId: meta.sessionId,
            category: meta.category.rawValue,
            surface: meta.surface.rawValue,
            split: meta.split.rawValue,
            expectedTriggers: meta.expectedTriggers,
            durationSeconds: durationSec,
            sampleCount: replay.sampleCount,
            inputCount: replay.inputCount,
            gatingInputCount: replay.gatingInputCount,
            ungatedSeconds: replay.ungatedSeconds,
            gapCount: replay.gapCount,
            largestGapNs: replay.largestGapNs,
            unsortedSamples: replay.unsortedSamples,
            unsortedInputs: replay.unsortedInputs,
            deliveryOrderViolations: replay.deliveryOrderViolations,
            armedCounts: policy.armedCounts,
            armedGroups: armedGroups,
            detectedGroups: detected,
            ambiguousGroups: ambiguous,
            mustNotFireGroups: mustNotFire,
            mustNotFireViolations: mustNotFireViolations,
            triggerCount: triggers.count,
            falsePositives: falsePositives,
            latencyExcluded: latencyExcluded,
            latenciesNs: latencies,
            perCount: counts.keys.sorted().map { counts[$0]! },
            groups: outcomes,
            triggers: triggerOutcomes,
            labelIssues: issues
        )
    }
}

// MARK: - Aggregation

struct Aggregate: Codable {
    var label: String
    /// Set only on a per-tap-count slice. `nil` means "every armed count together".
    var tapCount: Int?
    /// Set only on a slice: whether that tap count is armed.
    var armed: Bool?
    /// Labelled gesture groups in scope, armed or not. `armedGroups` is the
    /// detection denominator; this is the coverage number.
    var labelledGroups: Int = 0
    var sessions: Int = 0
    var tapSessions: Int = 0
    var typingSessions: Int = 0
    var confoundSessions: Int = 0
    var durationSeconds: Double = 0
    var typingSeconds: Double = 0
    /// Of `typingSeconds`, the part where the input gate was NOT muting the
    /// detector. This is the real exposure behind "zero false triggers while
    /// typing": measured on the training set, 86 % of typing time is gated, so
    /// 11.7 minutes of typing is about 1.6 minutes of opportunity to misfire.
    /// The zero is real — stripping input.jsonl makes the same detector fire
    /// 110 times on the same recording — but a reader is owed the denominator.
    var typingUngatedSeconds: Double = 0
    var confoundSeconds: Double = 0
    var armedGroups: Int = 0
    var detectedGroups: Int = 0
    var ambiguousGroups: Int = 0
    var mustNotFireGroups: Int = 0
    var mustNotFireViolations: Int = 0
    var triggerCount: Int = 0
    var falsePositives: Int = 0
    var typingFalsePositives: Int = 0
    var confoundFalsePositives: Int = 0
    var tapSessionFalsePositives: Int = 0
    var gapCount: Int = 0
    var deliveryOrderViolations: Int = 0
    var latencyExcluded: Int = 0
    var latenciesNs: [Int64] = []
    var perCount: [CountStats] = []

    var detectionRate: Double? {
        armedGroups == 0 ? nil : Double(detectedGroups) / Double(armedGroups)
    }
    var falsePositivesPer20Min: Double? {
        durationSeconds <= 0 ? nil : Double(falsePositives) / (durationSeconds / 1200.0)
    }
    var latencyP50Ns: Int64? { Percentile.of(latenciesNs, 0.50) }
    var latencyP95Ns: Int64? { Percentile.of(latenciesNs, 0.95) }
    var latencyMaxNs: Int64? { latenciesNs.max() }

    func count(_ n: Int) -> CountStats? { perCount.first { $0.count == n } }

    /// False triggers of tap count `n` per 20 minutes of wall time. This is the
    /// single-tap ship/no-ship number when `n == 1`.
    func falseTriggersPer20Min(count n: Int) -> Double? {
        guard durationSeconds > 0, let c = count(n) else { return nil }
        return Double(c.falseTriggers) / (durationSeconds / 1200.0)
    }

    /// One session, sliced down to a single tap count.
    ///
    /// Wall time, session counts and category counts stay whole — a false trigger
    /// rate is per 20 minutes of the same wall time no matter which count fired.
    /// Everything gesture-shaped is the count's own.
    mutating func addSlice(_ s: SessionScore, count n: Int, armed isArmed: Bool) {
        tapCount = n
        armed = isArmed
        let c = s.perCount.first { $0.count == n } ?? CountStats(count: n, armed: isArmed)
        sessions += 1
        durationSeconds += s.durationSeconds
        labelledGroups += c.labelledGroups
        // A count that must never fire has no detection target, so it gets no
        // denominator either. The page then shows "no data" instead of 0 %, which
        // would read as a failure to detect something nobody asked it to detect.
        armedGroups += isArmed ? c.labelledGroups : 0
        detectedGroups += c.detectedGroups
        ambiguousGroups += c.ambiguousGroups
        mustNotFireGroups += c.mustNotFireGroups
        mustNotFireViolations += c.mustNotFireViolations
        triggerCount += c.triggers
        falsePositives += c.falseTriggers
        gapCount += s.gapCount
        deliveryOrderViolations += s.deliveryOrderViolations
        latencyExcluded += c.latencyExcluded
        latenciesNs.append(contentsOf: c.latenciesNs)
        mergeCount(c)
        if s.category == Category.typing.rawValue {
            typingSessions += 1
            typingSeconds += s.durationSeconds
            typingUngatedSeconds += s.ungatedSeconds
            typingFalsePositives += c.falseTriggers
        }
        if s.category.hasPrefix("confound_") {
            confoundSessions += 1
            confoundSeconds += s.durationSeconds
            confoundFalsePositives += c.falseTriggers
        }
        if Category(rawValue: s.category)?.isTapCategory == true {
            tapSessions += 1
            tapSessionFalsePositives += c.falseTriggers
        }
    }

    mutating func add(_ s: SessionScore) {
        sessions += 1
        durationSeconds += s.durationSeconds
        labelledGroups += s.perCount.reduce(0) { $0 + $1.labelledGroups }
        armedGroups += s.armedGroups
        detectedGroups += s.detectedGroups
        ambiguousGroups += s.ambiguousGroups
        mustNotFireGroups += s.mustNotFireGroups
        mustNotFireViolations += s.mustNotFireViolations
        triggerCount += s.triggerCount
        falsePositives += s.falsePositives
        gapCount += s.gapCount
        deliveryOrderViolations += s.deliveryOrderViolations
        latencyExcluded += s.latencyExcluded
        latenciesNs.append(contentsOf: s.latenciesNs)
        for c in s.perCount { mergeCount(c) }
        if s.category == Category.typing.rawValue {
            typingSessions += 1
            typingSeconds += s.durationSeconds
            typingUngatedSeconds += s.ungatedSeconds
            typingFalsePositives += s.falsePositives
        }
        if s.category.hasPrefix("confound_") {
            confoundSessions += 1
            confoundSeconds += s.durationSeconds
            confoundFalsePositives += s.falsePositives
        }
        if Category(rawValue: s.category)?.isTapCategory == true {
            tapSessions += 1
            tapSessionFalsePositives += s.falsePositives
        }
    }

    private mutating func mergeCount(_ c: CountStats) {
        if let i = perCount.firstIndex(where: { $0.count == c.count }) {
            perCount[i].merge(c)
        } else {
            perCount.append(c)
            perCount.sort { $0.count < $1.count }
        }
    }

    enum CodingKeys: String, CodingKey {
        case label, tapCount, armed, labelledGroups
        case sessions, tapSessions, typingSessions, confoundSessions
        case durationSeconds, typingSeconds, typingUngatedSeconds, confoundSeconds
        case armedGroups, detectedGroups, ambiguousGroups
        case mustNotFireGroups, mustNotFireViolations
        case triggerCount, falsePositives, typingFalsePositives, confoundFalsePositives
        case tapSessionFalsePositives, gapCount, deliveryOrderViolations, latencyExcluded
        case latenciesNs, perCount
        case detectionRate, falsePositivesPer20Min, latencyP50Ns, latencyP95Ns, latencyMaxNs
        /// Deprecated alias for `armedGroups`, kept because `web/ingest.py` reads it.
        case doubleGroups
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(tapCount, forKey: .tapCount)
        try c.encodeIfPresent(armed, forKey: .armed)
        try c.encode(labelledGroups, forKey: .labelledGroups)
        try c.encode(armedGroups, forKey: .doubleGroups)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(tapSessions, forKey: .tapSessions)
        try c.encode(typingSessions, forKey: .typingSessions)
        try c.encode(confoundSessions, forKey: .confoundSessions)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(typingSeconds, forKey: .typingSeconds)
        try c.encode(typingUngatedSeconds, forKey: .typingUngatedSeconds)
        try c.encode(confoundSeconds, forKey: .confoundSeconds)
        try c.encode(armedGroups, forKey: .armedGroups)
        try c.encode(detectedGroups, forKey: .detectedGroups)
        try c.encode(ambiguousGroups, forKey: .ambiguousGroups)
        try c.encode(mustNotFireGroups, forKey: .mustNotFireGroups)
        try c.encode(mustNotFireViolations, forKey: .mustNotFireViolations)
        try c.encode(triggerCount, forKey: .triggerCount)
        try c.encode(falsePositives, forKey: .falsePositives)
        try c.encode(typingFalsePositives, forKey: .typingFalsePositives)
        try c.encode(confoundFalsePositives, forKey: .confoundFalsePositives)
        try c.encode(tapSessionFalsePositives, forKey: .tapSessionFalsePositives)
        try c.encode(gapCount, forKey: .gapCount)
        try c.encode(deliveryOrderViolations, forKey: .deliveryOrderViolations)
        try c.encode(latencyExcluded, forKey: .latencyExcluded)
        try c.encode(latenciesNs, forKey: .latenciesNs)
        try c.encode(perCount, forKey: .perCount)
        try c.encodeIfPresent(detectionRate, forKey: .detectionRate)
        try c.encodeIfPresent(falsePositivesPer20Min, forKey: .falsePositivesPer20Min)
        try c.encodeIfPresent(latencyP50Ns, forKey: .latencyP50Ns)
        try c.encodeIfPresent(latencyP95Ns, forKey: .latencyP95Ns)
        try c.encodeIfPresent(latencyMaxNs, forKey: .latencyMaxNs)
    }

    init(label: String) { self.label = label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        tapCount = try c.decodeIfPresent(Int.self, forKey: .tapCount)
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed)
        labelledGroups = try c.decodeIfPresent(Int.self, forKey: .labelledGroups) ?? 0
        sessions = try c.decode(Int.self, forKey: .sessions)
        tapSessions = try c.decode(Int.self, forKey: .tapSessions)
        typingSessions = try c.decode(Int.self, forKey: .typingSessions)
        confoundSessions = try c.decode(Int.self, forKey: .confoundSessions)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        typingSeconds = try c.decodeIfPresent(Double.self, forKey: .typingSeconds) ?? 0
        typingUngatedSeconds = try c.decodeIfPresent(Double.self, forKey: .typingUngatedSeconds) ?? 0
        confoundSeconds = try c.decodeIfPresent(Double.self, forKey: .confoundSeconds) ?? 0
        armedGroups = try c.decode(Int.self, forKey: .armedGroups)
        detectedGroups = try c.decode(Int.self, forKey: .detectedGroups)
        ambiguousGroups = try c.decode(Int.self, forKey: .ambiguousGroups)
        mustNotFireGroups = try c.decodeIfPresent(Int.self, forKey: .mustNotFireGroups) ?? 0
        mustNotFireViolations = try c.decodeIfPresent(Int.self, forKey: .mustNotFireViolations) ?? 0
        triggerCount = try c.decode(Int.self, forKey: .triggerCount)
        falsePositives = try c.decode(Int.self, forKey: .falsePositives)
        typingFalsePositives = try c.decode(Int.self, forKey: .typingFalsePositives)
        confoundFalsePositives = try c.decode(Int.self, forKey: .confoundFalsePositives)
        tapSessionFalsePositives = try c.decode(Int.self, forKey: .tapSessionFalsePositives)
        gapCount = try c.decode(Int.self, forKey: .gapCount)
        deliveryOrderViolations = try c.decode(Int.self, forKey: .deliveryOrderViolations)
        latencyExcluded = try c.decode(Int.self, forKey: .latencyExcluded)
        latenciesNs = try c.decodeIfPresent([Int64].self, forKey: .latenciesNs) ?? []
        perCount = try c.decodeIfPresent([CountStats].self, forKey: .perCount) ?? []
    }
}

enum Percentile {
    /// Nearest-rank percentile. With small sample counts this beats interpolation
    /// because the reported number is always one you actually measured.
    static func of(_ values: [Int64], _ p: Double) -> Int64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let idx = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[idx]
    }
}
