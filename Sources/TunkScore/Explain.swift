import Foundation
import TunkCore
import TunkFormat

/// A reference statistic the *harness* computes, deliberately independent of the
/// detector. When a group is missed it answers the first question a critic asks:
/// was there any energy there at all, or did the sensor see nothing?
struct SignalProbe {
    let samples: [AccelSample]
    let bx: Double, by: Double, bz: Double

    init(samples: [AccelSample]) {
        self.samples = samples
        func median(_ vals: [Float]) -> Double {
            guard !vals.isEmpty else { return 0 }
            let s = vals.sorted()
            return Double(s[s.count / 2])
        }
        // Sub-sample for the median; the resting attitude does not move much and a
        // full sort of a multi-minute session buys nothing.
        let stride = max(1, samples.count / 20_000)
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        var i = 0
        while i < samples.count { xs.append(samples[i].x); ys.append(samples[i].y); zs.append(samples[i].z); i += stride }
        bx = median(xs); by = median(ys); bz = median(zs)
    }

    private func lowerBound(_ t: Int64) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].tNs < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Largest deviation from the resting attitude inside `t ± half`.
    func peak(around t: Int64, half: Int64) -> (value: Double, tNs: Int64)? {
        var i = lowerBound(t - half)
        var best: (Double, Int64)?
        while i < samples.count, samples[i].tNs <= t + half {
            let s = samples[i]
            let dx = Double(s.x) - bx, dy = Double(s.y) - by, dz = Double(s.z) - bz
            let d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if best == nil || d > best!.0 { best = (d, s.tNs) }
            i += 1
        }
        return best.map { (value: $0.0, tNs: $0.1) }
    }
}

enum Explainer {
    static func trace(session: Session, config: DetectorConfig, policy: ScoringPolicy) throws -> String {
        let samples = try session.samples()
        let inputs = try session.inputs().map(\.event)
        let detector = DetectorFactory.make(config: config)
        detector.reset()
        let replay = Replay.run(samples: samples, inputs: inputs, detector: detector,
                                nominalIntervalNs: max(1, session.meta.nominalIntervalNs))
        let score = try SessionScorer.score(session: session, replay: replay, policy: policy)
        let probe = SignalProbe(samples: samples)

        let t0 = samples.first?.tNs ?? 0
        func at(_ t: Int64) -> String { String(format: "%9.3f s", Double(t - t0) / 1e9) }

        let gating = inputs.filter { $0.kind.gatesDetection }.sorted { $0.tNs < $1.tNs }
        func lastGating(before t: Int64) -> InputEvent? {
            var lo = 0, hi = gating.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if gating[mid].tNs <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo == 0 ? nil : gating[lo - 1]
        }
        func gateState(_ t: Int64) -> String {
            guard let g = lastGating(before: t) else { return "clear (no prior input)" }
            let dt = t - g.tNs
            return dt <= config.gateWindowNs
                ? String(format: "GATED (%@ %.0f ms earlier, window %.0f ms)", g.kind.rawValue,
                         Double(dt) / 1e6, Double(config.gateWindowNs) / 1e6)
                : String(format: "clear (last %@ %.0f ms earlier)", g.kind.rawValue, Double(dt) / 1e6)
        }

        let onsets = replay.onsets.sorted { $0.tNs < $1.tNs }
        let thr = config.effectiveThreshold

        var out = ""
        out += "# explain \(session.meta.sessionId)\n\n"
        out += "- directory: `\(session.directory.path)`\n"
        out += "- category `\(session.meta.category.rawValue)`, surface `\(session.meta.surface.rawValue)`, "
        out += "split `\(session.meta.split.rawValue)`, expected triggers \(session.meta.expectedTriggers)\n"
        out += String(format: "- %d samples over %.1f s, %d gaps (largest %.2f ms), %d input events (%d gating)\n",
                      replay.sampleCount, Double(replay.spanNs) / 1e9, replay.gapCount,
                      Double(replay.largestGapNs) / 1e6, replay.inputCount, replay.gatingInputCount)
        out += "- detector: `\(DetectorFactory.backendName)`\n"
        out += "- armed tap counts: `\(policy.text)`\n"
        out += String(format: "- resting attitude x %.4f  y %.4f  z %.4f g (harness estimate)\n", probe.bx, probe.by, probe.bz)
        out += "\n## Config\n\n```\n" + ConfigIO.describe(config) + "```\n"

        out += "\n## Onsets the detector declared (\(onsets.count))\n\n"
        if onsets.isEmpty {
            out += "_none_ — nothing crossed the threshold of \(String(format: "%.4f", thr)) g.\n"
        } else {
            out += "| # | t | strength | x threshold | gate |\n|---|---|---|---|---|\n"
            for (i, o) in onsets.enumerated() {
                out += "| \(i) | \(at(o.tNs)) | \(String(format: "%.4f", o.strength)) | "
                out += "\(String(format: "%.2f", o.strength / max(thr, 1e-9)))× | "
                out += "\(o.suppressedByGate ? "suppressed" : "clear") — \(gateState(o.tNs)) |\n"
            }
        }

        out += "\n## Triggers (\(score.triggers.count))\n\n"
        if score.triggers.isEmpty {
            out += "_none_\n"
        } else {
            out += "| # | fired at | onsets | inter-tap | score | verdict |\n|---|---|---|---|---|---|\n"
            for t in score.triggers {
                let onsetsStr = t.tapOnsets.map { at($0).trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
                let inter = t.tapOnsets.count >= 2
                    ? String(format: "%.0f ms", Double(t.tapOnsets[t.tapOnsets.count - 1] - t.tapOnsets[t.tapOnsets.count - 2]) / 1e6)
                    : "—"
                var verdict: String
                if let g = t.matchedGroup {
                    let latency = score.groups.first { $0.group == g }?.latencyNs
                    verdict = "matched group \(g), latency \(Fmt.msOpt(latency))"
                } else {
                    verdict = "**FALSE TRIGGER (\(t.tapCount)-tap)** — \(t.falseTriggerReason)"
                    if let n = t.nearestLabelNs {
                        verdict += String(format: " (nearest label %.0f ms away)", Double(n) / 1e6)
                    }
                    verdict += "; gate at fire time: \(gateState(t.tapOnsets.last ?? t.tNs))"
                }
                out += "| \(t.index) | \(at(t.tNs)) | \(onsetsStr) | \(inter) | "
                out += "\(String(format: "%.2f", t.score)) | \(verdict) |\n"
            }
        }

        out += "\n## Labelled groups (\(score.groups.count))\n\n"
        if score.groups.isEmpty {
            out += "_none_ — every trigger in this session is a false positive by definition.\n"
        } else {
            for g in score.groups {
                out += "### group \(g.group) — \(g.verdict.rawValue.uppercased()) "
                out += "(\(g.tapCount)-tap, intent `\(g.intent)`, confidence `\(g.confidence)`, "
                out += "\(g.armed ? "armed" : "**NOT ARMED**"))\n\n"
                if let f = g.firstOnsetNs {
                    out += "- labelled first onset  \(at(f))\n"
                }
                out += "- labelled last onset   \(at(g.lastOnsetNs))\n"
                out += "- triggers inside ±\(Int(Double(Scoring.matchWindowNs) / 1e6)) ms: \(g.nearbyTriggers) "
                out += "(\(g.candidateTriggers) with a matching tap count, \(g.wrongCountTriggers) with the wrong count)\n"
                if let l = g.latencyNs { out += "- latency \(Fmt.ms(l)), onset error \(Fmt.msOpt(g.onsetErrorNs))\n" }
                out += "- why: \(reason(group: g, onsets: onsets, config: config, probe: probe, gateState: gateState))\n\n"
            }
        }

        out += "\n## Summary\n\n"
        out += "- \(score.detectedGroups)/\(score.armedGroups) armed gesture groups detected"
        if score.ambiguousGroups > 0 { out += ", \(score.ambiguousGroups) ambiguous (more than one trigger in the window)" }
        out += "\n- \(score.mustNotFireGroups) must-not-fire gesture(s), \(score.mustNotFireViolations) fired anyway\n"
        out += "- \(score.triggerCount) triggers, \(score.falsePositives) false triggers\n"
        for c in score.perCount where c.armed || c.labelledGroups > 0 || c.triggers > 0 {
            out += "- \(c.count)-tap: \(c.armed ? "armed" : "NOT ARMED"), "
            out += "\(c.detectedGroups)/\(c.labelledGroups) detected, "
            out += "\(c.triggers) trigger(s), \(c.falseTriggers) false\n"
        }
        out += "- latency p50 \(Fmt.msOpt(Percentile.of(score.latenciesNs, 0.5))), "
        out += "p95 \(Fmt.msOpt(Percentile.of(score.latenciesNs, 0.95))), "
        out += "max \(Fmt.msOpt(score.latenciesNs.max()))\n"
        if replay.deliveryOrderViolations > 0 {
            out += "- **\(replay.deliveryOrderViolations) delivery-order violations** — the replay handed the detector out-of-order timestamps\n"
        }
        return out
    }

    /// The narrative a critic actually wants: not "missed", but which stage lost it.
    private static func reason(group g: GroupOutcome, onsets: [OnsetEvent],
                               config: DetectorConfig, probe: SignalProbe,
                               gateState: (Int64) -> String) -> String {
        let window = Scoring.matchWindowNs
        let near = onsets.filter { abs($0.tNs - g.lastOnsetNs) <= window * 2 }
        let thr = config.effectiveThreshold

        switch g.verdict {
        case .mustNotFire:
            return "the detector is not armed for a \(g.tapCount)-tap gesture, so this group must "
                + "never fire. Nothing did. Correct."
        case .firedWhenItMustNot:
            return "the detector is not armed for a \(g.tapCount)-tap gesture, yet \(g.nearbyTriggers) "
                + "trigger(s) landed inside the match window. Every one of them is a false trigger."
        case .detected:
            return "one trigger landed inside the match window; counted as detected."
        case .detectedLooseOnsets:
            let ms = Double(g.onsetSpreadNs ?? 0) / 1e6
            return String(format: "one trigger landed inside the match window and is counted as "
                + "detected, BUT its onsets disagree with the labelled ones by %.0f ms. Matching "
                + "only ever tests the last onset, so this credit may be firing on a different "
                + "physical event than the label names — most often the first strike plus a ring "
                + "lobe, with the real second strike arriving afterwards.", ms)
        case .ambiguous:
            return "\(g.candidateTriggers) triggers of the right tap count landed inside the match window. FORMAT.md requires "
                + "exactly one, so this group is not detected and the surplus triggers count as false positives."
        case .missed:
            if g.wrongCountTriggers > 0 {
                return "\(g.wrongCountTriggers) trigger(s) landed inside the match window but fired a "
                    + "different number of taps than the labelled \(g.tapCount). Wrong gesture, wrong "
                    + "action: the group is missed and those triggers are false triggers."
            }
            if near.isEmpty {
                if let p = probe.peak(around: g.lastOnsetNs, half: window) {
                    return String(format: "the detector declared no onset within ±%.0f ms. Harness peak deviation there was %.4f g against a threshold of %.4f g (%.2f×), so the transient was %@.",
                                  Double(window * 2) / 1e6, p.value, thr, p.value / max(thr, 1e-9),
                                  p.value < thr ? "below threshold" : "above threshold but rejected by the detector's own logic")
                }
                return "the detector declared no onset near this label and the harness found no samples there."
            }
            let suppressed = near.filter(\.suppressedByGate)
            if suppressed.count == near.count {
                return "\(near.count) onset(s) were declared but every one was suppressed: "
                    + gateState(near[0].tNs) + ". The gate ate this gesture."
            }
            let clear = near.filter { !$0.suppressedByGate }.map(\.tNs).sorted()
            if clear.count < g.tapCount {
                return "only \(clear.count) ungated onset(s) near this label; a \(g.tapCount)-tap needs \(g.tapCount). "
                    + (suppressed.isEmpty ? "" : "\(suppressed.count) further onset(s) were gate-suppressed.")
            }
            let gaps = zip(clear.dropFirst(), clear).map { $0 - $1 }
            let inRange = gaps.contains { $0 >= config.minInterTapNs && $0 <= config.maxInterTapNs }
            if !inRange {
                let g0 = gaps.map { String(format: "%.0f", Double($0) / 1e6) }.joined(separator: ", ")
                return "ungated onsets at \(clear.count) points, spacings [\(g0)] ms, none inside the accepted "
                    + String(format: "[%.0f, %.0f] ms inter-tap window.", Double(config.minInterTapNs) / 1e6, Double(config.maxInterTapNs) / 1e6)
            }
            return "onsets were declared, ungated, and correctly spaced, yet no trigger came out. "
                + "Look at the confirm window, the refractory period, or a third onset aborting the group."
        }
    }
}
