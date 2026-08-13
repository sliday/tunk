import Foundation
import TunkCore
import TunkFormat

/// Matching and metric definitions, straight out of the Scoring section of
/// FORMAT.md. Nothing here is negotiable by a builder; if a number looks wrong,
/// argue with the definition, not with this file.
enum Scoring {
    /// FORMAT.md: a labelled group counts as detected when exactly one trigger has
    /// its second tap onset within +/-150 ms of the labelled second onset.
    static let matchWindowNs: Int64 = 150_000_000
}

/// Why a labelled group was or was not detected. `explain` prints this verbatim.
enum GroupVerdict: String, Codable {
    case detected
    case missed
    /// More than one trigger landed in the window: not "exactly one", so the group
    /// is not detected and the surplus triggers count as false positives.
    case ambiguous
}

struct GroupOutcome: Codable {
    var group: Int
    var intent: String
    var confidence: String
    var firstOnsetNs: Int64?
    var secondOnsetNs: Int64
    var verdict: GroupVerdict
    var candidateTriggers: Int
    var matchedTriggerIndex: Int?
    /// `trigger.t_ns - labelled second onset`. The honest latency: measured
    /// against ground truth, not against the detector's own idea of the onset.
    var latencyNs: Int64?
    /// `detector second onset - labelled second onset`, for onset-accuracy debugging.
    var onsetErrorNs: Int64?
}

struct TriggerOutcome: Codable {
    var index: Int
    var tNs: Int64
    var tapOnsets: [Int64]
    var score: Double
    var matchedGroup: Int?
    var isFalsePositive: Bool
    /// Distance to the nearest labelled second onset, when there is one.
    var nearestLabelNs: Int64?
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
    var gapCount: Int
    var largestGapNs: Int64
    var unsortedSamples: Int
    var unsortedInputs: Int
    var deliveryOrderViolations: Int

    var doubleGroups: Int
    var detectedGroups: Int
    var ambiguousGroups: Int
    var triggerCount: Int
    var falsePositives: Int
    /// Groups excluded from latency because `confidence == prompt_window`.
    var latencyExcluded: Int
    var latenciesNs: [Int64]
    var groups: [GroupOutcome]
    var triggers: [TriggerOutcome]

    var detectionRate: Double? {
        doubleGroups == 0 ? nil : Double(detectedGroups) / Double(doubleGroups)
    }
}

enum SessionScorer {
    /// Grade one replay against one session's labels.
    ///
    /// Assignment is greedy in time: groups are walked in ascending order of their
    /// labelled second onset, and each takes the closest unclaimed trigger inside
    /// the +/-150 ms window. A group with two or more unclaimed candidates is
    /// `ambiguous` (not detected) and gives up all but the closest, which keeps the
    /// surplus in the false-positive column where FORMAT.md puts it.
    static func score(session: Session, replay: ReplayResult) throws -> SessionScore {
        let meta = session.meta
        let groups = try session.labelGroups()
        let triggers = replay.triggers

        func triggerOnsetNs(_ t: Trigger) -> Int64 { t.tapOnsets.last ?? t.tNs }

        var claimedBy = [Int?](repeating: nil, count: triggers.count)
        var outcomes: [GroupOutcome] = []
        var latencies: [Int64] = []
        var detected = 0, ambiguous = 0, doubleGroups = 0, latencyExcluded = 0

        struct GroupKey { var id: Int; var rows: [TapLabel]; var secondNs: Int64 }
        let keyed: [GroupKey] = groups.compactMap { rows in
            guard let last = rows.last, let id = rows.first?.group else { return nil }
            return GroupKey(id: id, rows: rows, secondNs: last.tNs)
        }.sorted { $0.secondNs < $1.secondNs }

        for g in keyed {
            let intent = g.rows.last!.intent
            let confidence = g.rows.last!.confidence
            var outcome = GroupOutcome(
                group: g.id, intent: intent.rawValue, confidence: confidence.rawValue,
                firstOnsetNs: g.rows.first?.tNs, secondOnsetNs: g.secondNs,
                verdict: .missed, candidateTriggers: 0, matchedTriggerIndex: nil,
                latencyNs: nil, onsetErrorNs: nil
            )

            var candidates: [Int] = []
            for (i, t) in triggers.enumerated() where claimedBy[i] == nil {
                if abs(triggerOnsetNs(t) - g.secondNs) <= Scoring.matchWindowNs { candidates.append(i) }
            }
            outcome.candidateTriggers = candidates.count

            if intent == .double { doubleGroups += 1 }

            if let best = candidates.min(by: {
                abs(triggerOnsetNs(triggers[$0]) - g.secondNs) < abs(triggerOnsetNs(triggers[$1]) - g.secondNs)
            }) {
                claimedBy[best] = g.id
                outcome.matchedTriggerIndex = best
                outcome.latencyNs = triggers[best].tNs - g.secondNs
                outcome.onsetErrorNs = triggerOnsetNs(triggers[best]) - g.secondNs
                if candidates.count == 1 {
                    outcome.verdict = .detected
                    if intent == .double {
                        detected += 1
                        if confidence == .promptWindow {
                            latencyExcluded += 1
                        } else {
                            latencies.append(triggers[best].tNs - g.secondNs)
                        }
                    }
                } else {
                    outcome.verdict = .ambiguous
                    if intent == .double { ambiguous += 1 }
                }
            }
            outcomes.append(outcome)
        }

        var triggerOutcomes: [TriggerOutcome] = []
        var falsePositives = 0
        for (i, t) in triggers.enumerated() {
            let nearest = keyed.map { abs(triggerOnsetNs(t) - $0.secondNs) }.min()
            let matched = claimedBy[i]
            // A trigger that claimed an `ambiguous` group is still a real match for
            // bookkeeping; the surplus triggers are the unclaimed ones.
            let isFP = matched == nil
            if isFP { falsePositives += 1 }
            triggerOutcomes.append(TriggerOutcome(
                index: i, tNs: t.tNs, tapOnsets: t.tapOnsets, score: t.score,
                matchedGroup: matched, isFalsePositive: isFP, nearestLabelNs: nearest
            ))
        }

        let durationSec: Double = {
            if meta.durationNs > 0 { return Double(meta.durationNs) / 1e9 }
            return Double(replay.spanNs) / 1e9
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
            gapCount: replay.gapCount,
            largestGapNs: replay.largestGapNs,
            unsortedSamples: replay.unsortedSamples,
            unsortedInputs: replay.unsortedInputs,
            deliveryOrderViolations: replay.deliveryOrderViolations,
            doubleGroups: doubleGroups,
            detectedGroups: detected,
            ambiguousGroups: ambiguous,
            triggerCount: triggers.count,
            falsePositives: falsePositives,
            latencyExcluded: latencyExcluded,
            latenciesNs: latencies,
            groups: outcomes,
            triggers: triggerOutcomes
        )
    }
}

// MARK: - Aggregation

struct Aggregate: Codable {
    var label: String
    var sessions: Int = 0
    var tapSessions: Int = 0
    var typingSessions: Int = 0
    var confoundSessions: Int = 0
    var durationSeconds: Double = 0
    var doubleGroups: Int = 0
    var detectedGroups: Int = 0
    var ambiguousGroups: Int = 0
    var triggerCount: Int = 0
    var falsePositives: Int = 0
    var typingFalsePositives: Int = 0
    var confoundFalsePositives: Int = 0
    var tapSessionFalsePositives: Int = 0
    var gapCount: Int = 0
    var deliveryOrderViolations: Int = 0
    var latencyExcluded: Int = 0
    var latenciesNs: [Int64] = []

    var detectionRate: Double? {
        doubleGroups == 0 ? nil : Double(detectedGroups) / Double(doubleGroups)
    }
    var falsePositivesPer20Min: Double? {
        durationSeconds <= 0 ? nil : Double(falsePositives) / (durationSeconds / 1200.0)
    }
    var latencyP50Ns: Int64? { Percentile.of(latenciesNs, 0.50) }
    var latencyP95Ns: Int64? { Percentile.of(latenciesNs, 0.95) }
    var latencyMaxNs: Int64? { latenciesNs.max() }

    mutating func add(_ s: SessionScore) {
        sessions += 1
        durationSeconds += s.durationSeconds
        doubleGroups += s.doubleGroups
        detectedGroups += s.detectedGroups
        ambiguousGroups += s.ambiguousGroups
        triggerCount += s.triggerCount
        falsePositives += s.falsePositives
        gapCount += s.gapCount
        deliveryOrderViolations += s.deliveryOrderViolations
        latencyExcluded += s.latencyExcluded
        latenciesNs.append(contentsOf: s.latenciesNs)
        if s.category == Category.typing.rawValue {
            typingSessions += 1
            typingFalsePositives += s.falsePositives
        }
        if s.category.hasPrefix("confound_") {
            confoundSessions += 1
            confoundFalsePositives += s.falsePositives
        }
        if Category(rawValue: s.category)?.isTapCategory == true {
            tapSessions += 1
            tapSessionFalsePositives += s.falsePositives
        }
    }

    enum CodingKeys: String, CodingKey {
        case label, sessions, tapSessions, typingSessions, confoundSessions
        case durationSeconds, doubleGroups, detectedGroups, ambiguousGroups
        case triggerCount, falsePositives, typingFalsePositives, confoundFalsePositives
        case tapSessionFalsePositives, gapCount, deliveryOrderViolations, latencyExcluded
        case detectionRate, falsePositivesPer20Min, latencyP50Ns, latencyP95Ns, latencyMaxNs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(tapSessions, forKey: .tapSessions)
        try c.encode(typingSessions, forKey: .typingSessions)
        try c.encode(confoundSessions, forKey: .confoundSessions)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(doubleGroups, forKey: .doubleGroups)
        try c.encode(detectedGroups, forKey: .detectedGroups)
        try c.encode(ambiguousGroups, forKey: .ambiguousGroups)
        try c.encode(triggerCount, forKey: .triggerCount)
        try c.encode(falsePositives, forKey: .falsePositives)
        try c.encode(typingFalsePositives, forKey: .typingFalsePositives)
        try c.encode(confoundFalsePositives, forKey: .confoundFalsePositives)
        try c.encode(tapSessionFalsePositives, forKey: .tapSessionFalsePositives)
        try c.encode(gapCount, forKey: .gapCount)
        try c.encode(deliveryOrderViolations, forKey: .deliveryOrderViolations)
        try c.encode(latencyExcluded, forKey: .latencyExcluded)
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
        sessions = try c.decode(Int.self, forKey: .sessions)
        tapSessions = try c.decode(Int.self, forKey: .tapSessions)
        typingSessions = try c.decode(Int.self, forKey: .typingSessions)
        confoundSessions = try c.decode(Int.self, forKey: .confoundSessions)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        doubleGroups = try c.decode(Int.self, forKey: .doubleGroups)
        detectedGroups = try c.decode(Int.self, forKey: .detectedGroups)
        ambiguousGroups = try c.decode(Int.self, forKey: .ambiguousGroups)
        triggerCount = try c.decode(Int.self, forKey: .triggerCount)
        falsePositives = try c.decode(Int.self, forKey: .falsePositives)
        typingFalsePositives = try c.decode(Int.self, forKey: .typingFalsePositives)
        confoundFalsePositives = try c.decode(Int.self, forKey: .confoundFalsePositives)
        tapSessionFalsePositives = try c.decode(Int.self, forKey: .tapSessionFalsePositives)
        gapCount = try c.decode(Int.self, forKey: .gapCount)
        deliveryOrderViolations = try c.decode(Int.self, forKey: .deliveryOrderViolations)
        latencyExcluded = try c.decode(Int.self, forKey: .latencyExcluded)
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
