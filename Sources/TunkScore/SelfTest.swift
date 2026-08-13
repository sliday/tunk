import Foundation
import TunkCore
import TunkFormat

/// `tunk-score selftest` — proves the harness, not the detector.
///
/// It plants a known number of double-taps into synthetic sessions written to disk
/// in the real FORMAT.md layout, then asserts the harness reports exactly what was
/// planted. The two assertions that matter most:
///
///  - the gated-typing session must produce zero triggers *and* the same session
///    replayed with a deliberately broken order (all samples, then all inputs)
///    must produce some, which proves the interleave test has teeth;
///  - the same session replayed twice, and replayed again with real sleeps
///    injected mid-stream, must produce identical triggers, which catches a
///    detector that reads a wall clock.
enum SelfTest {

    struct Assertions {
        private(set) var rows: [(name: String, ok: Bool, detail: String)] = []
        var failures: Int { rows.filter { !$0.ok }.count }

        mutating func check(_ name: String, _ ok: Bool, _ detail: String) {
            rows.append((name, ok, detail))
        }
        mutating func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            rows.append((name, got == want, "got \(got), planted \(want)"))
        }
        mutating func between(_ name: String, _ got: Double, _ lo: Double, _ hi: Double, _ unit: String) {
            rows.append((name, got >= lo && got <= hi,
                         String(format: "got %.2f %@, expected %.2f..%.2f %@", got, unit, lo, hi, unit)))
        }
    }

    static func run(_ args: inout Args) throws -> Int32 {
        let dirArg = args.string("dir") ?? ".tunk-selftest"
        let keep = args.bool("keep")
        // The selftest grades the HARNESS, so it defaults to the stub: a failing
        // assertion should mean the harness is wrong, not that the detector of the
        // day dislikes a synthetic waveform. Pass --detector real to point the same
        // planted scenarios at the shipping detector.
        try DetectorFactory.select(args.string("detector"), default: .stub)
        try args.checkUnknown()

        let scratch = Paths.resolve(dirArg)
        let fm = FileManager.default
        if fm.fileExists(atPath: scratch.path) { try fm.removeItem(at: scratch) }
        let sessionsRoot = scratch.appendingPathComponent("sessions")
        let guardRoot = scratch.appendingPathComponent("guardcheck")
        // Single- and triple-tap scenarios live in their own root so the totals the
        // older assertions pin down stay exactly what they were.
        let countsRoot = scratch.appendingPathComponent("counts")
        try fm.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: guardRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: countsRoot, withIntermediateDirectories: true)

        print("tunk-score selftest")
        print("scratch: \(scratch.path)")
        print("detector under test: \(DetectorFactory.backendName)")
        print("")

        // ---- plant -------------------------------------------------------------
        let plantedClean = 10
        let plantedGated = 6
        let plantedThumps = 8
        let plantedStrikes = 200

        let stamp = "20260101-000000"
        let cleanDir = try Synth.write(Synth.cleanTaps(count: plantedClean), root: sessionsRoot,
                                       stamp: stamp, shortId: "clean1")
        let typingDir = try Synth.write(Synth.typing(strikes: plantedStrikes), root: sessionsRoot,
                                        stamp: stamp, shortId: "typg1")
        let gatedDir = try Synth.write(Synth.gatedTaps(count: plantedGated), root: sessionsRoot,
                                       stamp: stamp, shortId: "gated1")
        let thumpDir = try Synth.write(Synth.isolatedThumps(count: plantedThumps), root: sessionsRoot,
                                       stamp: stamp, shortId: "thump1")
        var holdoutPlan = Synth.cleanTaps(count: 1)
        holdoutPlan.split = .test
        _ = try Synth.write(holdoutPlan, root: guardRoot, stamp: stamp, shortId: "hold1")

        var a = Assertions()
        let config = DetectorConfig.default
        // Everything below is scored against the config's own armed set (2-tap),
        // except where a scenario explicitly re-arms to prove the per-count split.
        let policy = ScoringPolicy.from(config: config, override: nil)

        // ---- format round-trip -------------------------------------------------
        let sessions = try Session.discover(root: sessionsRoot)
        a.equal("sessions discovered", sessions.count, 4)
        for s in sessions {
            let samples = try s.samples()
            a.equal("\(s.meta.category.rawValue): sample count matches meta", samples.count, s.meta.sampleCount)
        }

        func score(_ dir: URL, order: ReplayOrder = .interleaved,
                   sleepEvery: Int = 0, sleepNs: UInt64 = 0,
                   cfg: DetectorConfig? = nil,
                   with: ScoringPolicy? = nil) throws -> (SessionScore, ReplayResult) {
            let s = try Session(directory: dir)
            let r = try Replay.run(session: s, config: cfg ?? config, order: order,
                                   sleepEveryNSamples: sleepEvery, sleepNanos: sleepNs)
            return (try SessionScorer.score(session: s, replay: r, policy: with ?? policy), r)
        }

        // ---- 1. clean double-taps ---------------------------------------------
        let (clean, cleanReplay) = try score(cleanDir)
        a.equal("clean taps: armed (2-tap) groups", clean.armedGroups, plantedClean)
        a.equal("clean taps: detected groups", clean.detectedGroups, plantedClean)
        a.equal("clean taps: total triggers", clean.triggerCount, plantedClean)
        a.equal("clean taps: false positives", clean.falsePositives, 0)
        a.equal("clean taps: replay gaps", cleanReplay.gapCount, 0)
        a.equal("clean taps: delivery-order violations", cleanReplay.deliveryOrderViolations, 0)
        let p50 = Double(Percentile.of(clean.latenciesNs, 0.5) ?? -1) / 1e6
        let p95 = Double(Percentile.of(clean.latenciesNs, 0.95) ?? -1) / 1e6
        let confirmMs = Double(config.confirmWindowNs) / 1e6
        a.between("clean taps: latency p50 ≈ confirm window", p50, confirmMs, confirmMs + 12, "ms")
        a.check("clean taps: latency p95 ≤ 250 ms", p95 <= 250, String(format: "p95 %.2f ms", p95))

        // ---- 2. typing, gated --------------------------------------------------
        let (typing, _) = try score(typingDir)
        a.equal("typing: triggers with the gate live", typing.triggerCount, 0)

        // ---- 3. the interleave has teeth --------------------------------------
        // This one is about the replay engine, not about whichever detector is
        // selected, so it always runs against the stub. A real detector may reject
        // the synthetic typing signal on its own merits, which would hide the bug
        // this check exists to catch.
        let typingSession = try Session(directory: typingDir)
        let typingSamples = try typingSession.samples()
        let typingInputs = try typingSession.inputs().map(\.event)
        func stubReplay(_ order: ReplayOrder) -> ReplayResult {
            Replay.run(samples: typingSamples, inputs: typingInputs,
                       detector: StubTapDetector(config: config), order: order,
                       nominalIntervalNs: Synth.intervalNs)
        }
        let interleaved = stubReplay(.interleaved)
        let broken = stubReplay(.samplesFirstBroken)
        a.check("interleave has teeth: correct order 0, broken order > 0",
                interleaved.triggers.isEmpty && !broken.triggers.isEmpty,
                "interleaved \(interleaved.triggers.count) triggers vs "
                + "\(broken.triggers.count) when the inputs are replayed after the samples "
                + "(stub detector, so the check measures the replay engine)")
        if DetectorFactory.backend != .stub {
            let (typingBroken, _) = try score(typingDir, order: .samplesFirstBroken)
            a.check("selected detector, typing with the gate disabled by broken order",
                    true,
                    "\(typingBroken.triggerCount) triggers — informational; "
                    + "\(DetectorFactory.backendName) may reject this synthetic typing on its own")
        }

        // ---- 4. taps inside a gate window -------------------------------------
        let (gated, _) = try score(gatedDir)
        a.equal("gated taps: armed (2-tap) groups", gated.armedGroups, plantedGated)
        a.equal("gated taps: detected groups (gate should eat them)", gated.detectedGroups, 0)
        a.equal("gated taps: triggers", gated.triggerCount, 0)

        // ---- 5. isolated single thumps ----------------------------------------
        let (thumps, _) = try score(thumpDir)
        a.equal("isolated thumps: triggers", thumps.triggerCount, 0)

        // ---- 6. determinism and clock independence ----------------------------
        let (_, again) = try score(cleanDir)
        a.check("replay is deterministic", again.triggers == cleanReplay.triggers,
                "two identical replays produced \(again.triggers.count) vs \(cleanReplay.triggers.count) triggers")
        let (_, slowed) = try score(cleanDir, sleepEvery: 4000, sleepNs: 2_000_000)
        a.check("detector ignores wall-clock time",
                slowed.triggers == cleanReplay.triggers,
                String(format: "replay slowed to %.2f s (from %.2f s) produced %@ triggers",
                       slowed.replaySeconds, cleanReplay.replaySeconds,
                       slowed.triggers == cleanReplay.triggers ? "identical" : "DIFFERENT"))

        // ---- 7. the matching rule itself --------------------------------------
        try matchingRuleChecks(cleanDir: cleanDir, into: &a)

        // ---- 7b. tap counts: single, double, triple ---------------------------
        try tapCountChecks(root: countsRoot, stamp: stamp, config: config, into: &a)

        // ---- 8. the holdout guard ---------------------------------------------
        let guardSessions = try Session.discover(root: guardRoot)
        var refused = false
        do { _ = try HoldoutGuard.check(root: guardRoot, sessions: guardSessions, isCritic: false) }
        catch { refused = true }
        a.check("holdout guard refuses a split=test session", refused,
                refused ? "threw as required" : "let it through")
        let banner = (try? HoldoutGuard.check(root: guardRoot, sessions: guardSessions, isCritic: true)) ?? []
        a.check("holdout guard banners in critic mode", banner.count == 1 && banner[0].contains("CRITIC MODE"),
                banner.isEmpty ? "no banner" : "banner printed")
        a.check("holdout guard trips on the path alone",
                HoldoutGuard.pathLooksLikeHoldout(URL(fileURLWithPath: "/x/data/holdout/foo")),
                "path check")
        a.check("holdout guard leaves data/raw alone",
                !HoldoutGuard.pathLooksLikeHoldout(URL(fileURLWithPath: "/x/data/raw")),
                "path check")

        // ---- 9. the whole report ----------------------------------------------
        var scores: [SessionScore] = []
        for s in sessions {
            let r = try Replay.run(session: s, config: config)
            scores.append(try SessionScorer.score(session: s, replay: r, policy: policy))
        }
        let report = Reporter.build(dataRoot: sessionsRoot, split: "train", config: config,
                                    policy: policy, scores: scores, warnings: [])
        a.equal("report: pooled armed groups", report.pooled.armedGroups, plantedClean + plantedGated)
        a.equal("report: pooled detected", report.pooled.detectedGroups, plantedClean)
        a.equal("report: pooled false positives", report.pooled.falsePositives, 0)
        a.check("report: verdict is FAIL (soft surface detects nothing)",
                report.verdict == .fail, "verdict \(report.verdict.rawValue)")
        a.check("report: warns when the graded detector is a stub",
                !DetectorFactory.isStub || report.warnings.contains { $0.contains("STUB") },
                DetectorFactory.isStub ? (report.warnings.first ?? "no warning, and there should be one")
                                       : "backend is \(DetectorFactory.backendName); no stub warning expected")

        // ---- 10. explain runs on a real session -------------------------------
        let explainText = try Explainer.trace(session: try Session(directory: gatedDir),
                                              config: config, policy: policy)
        a.check("explain names the gate as the reason a group was missed",
                explainText.contains("The gate ate this gesture"),
                explainText.contains("The gate ate this gesture") ? "reason found" : "reason missing")

        // ---- 10b. the merge order itself ---------------------------------------
        // Directly observe what the detector is handed, rather than inferring it
        // from triggers. An input sharing a timestamp with a sample must arrive
        // first, so a gate that arms at T covers the sample at T.
        let probe = OrderProbe()
        _ = Replay.run(
            samples: [0, 1_000, 2_000].map { AccelSample(tNs: $0, arrivalNs: $0, x: 0, y: 0, z: -1) },
            inputs: [InputEvent(tNs: 1_000, kind: .keyDown), InputEvent(tNs: 1_500, kind: .keyUp)],
            detector: probe)
        a.check("replay merges strictly by t_ns, input first on a tie",
                probe.log == ["s@0", "i@1000", "s@1000", "i@1500", "s@2000"],
                probe.log.joined(separator: " "))
        let outOfOrder = OrderProbe()
        let r = Replay.run(
            samples: [2_000, 0, 1_000].map { AccelSample(tNs: $0, arrivalNs: $0, x: 0, y: 0, z: -1) },
            inputs: [], detector: outOfOrder)
        a.check("replay repairs and reports a file that is not ascending",
                r.unsortedSamples == 1 && outOfOrder.log == ["s@0", "s@1000", "s@2000"]
                    && r.deliveryOrderViolations == 0,
                "reordered \(r.unsortedSamples), delivered \(outOfOrder.log.joined(separator: " "))")

        // ---- 11. config loading -----------------------------------------------
        // A `...Ms` alias that forgets to scale turns a 220 ms gate into a 220 ns
        // gate, and the report then blames the detector for a harness bug.
        let msFile = scratch.appendingPathComponent("cfg_ms.json")
        let nsFile = scratch.appendingPathComponent("cfg_ns.json")
        try #"{"gateWindowMs": 220}"#.write(to: msFile, atomically: true, encoding: .utf8)
        try #"{"gateWindowNs": 220000000}"#.write(to: nsFile, atomically: true, encoding: .utf8)
        let msCfg = try ConfigIO.load(url: msFile)
        let nsCfg = try ConfigIO.load(url: nsFile)
        a.check("config: gateWindowMs and gateWindowNs agree", msCfg == nsCfg,
                "\(msCfg.gateWindowNs) ns vs \(nsCfg.gateWindowNs) ns")
        a.check("config: an omitted key keeps the default",
                msCfg.confirmWindowNs == DetectorConfig.default.confirmWindowNs,
                "confirmWindowNs \(msCfg.confirmWindowNs)")
        let badFile = scratch.appendingPathComponent("cfg_bad.json")
        try #"{"gateWindow": 220}"#.write(to: badFile, atomically: true, encoding: .utf8)
        var rejected = false
        do { _ = try ConfigIO.load(url: badFile) } catch { rejected = true }
        a.check("config: a misspelled key is rejected", rejected,
                rejected ? "threw as required" : "silently ignored, which would fake a result")

        // ---- 12. the progress-page feed ---------------------------------------
        try progressFeedChecks(report: report, scratch: scratch, into: &a)

        // ---- report ------------------------------------------------------------
        print(Reporter.pad("result", 8) + Reporter.pad("assertion", 56) + "detail")
        for r in a.rows {
            print(Reporter.pad(r.ok ? "  ok  " : " FAIL ", 8) + Reporter.pad(r.name, 56) + r.detail)
        }
        print("")
        print("planted: \(plantedClean) clean double-taps, \(plantedGated) gated double-taps, "
              + "\(plantedStrikes) key strikes, \(plantedThumps) isolated thumps, "
              + "\(plantedSingles) deliberate single taps (with a stray knock each), "
              + "\(plantedTriples) triple-taps")
        print("measured: \(clean.detectedGroups)/\(clean.armedGroups) clean detected, "
              + "\(typing.triggerCount) typing triggers, \(gated.triggerCount) gated triggers, "
              + "\(thumps.triggerCount) thump triggers, "
              + String(format: "latency p50 %.1f ms / p95 %.1f ms", p50, p95))
        print("")
        if !keep {
            try? fm.removeItem(at: scratch)
            print("scratch removed (pass --keep to inspect the generated sessions)")
        } else {
            print("kept: \(scratch.path)")
        }
        print(a.failures == 0 ? "SELFTEST PASS (\(a.rows.count) assertions)"
                              : "SELFTEST FAIL (\(a.failures)/\(a.rows.count) assertions)")
        return a.failures == 0 ? 0 : 1
    }

    /// The progress-page feed, checked against the schema in `web/README.md`.
    /// Nothing under `web/` is touched: this writes to the selftest scratch.
    private static func progressFeedChecks(report: RunReport, scratch: URL,
                                           into a: inout Assertions) throws {
        let feed = scratch.appendingPathComponent("progress/progress.json")

        _ = try ProgressFeed.append(report: report, options: ProgressOptions(path: feed))
        _ = try ProgressFeed.append(report: report, options: ProgressOptions(
            path: feed, label: "round two", headline: "hand-written headline",
            biggestGap: "hand-written gap"))

        func doc() throws -> [String: Any] {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: feed)) as? [String: Any]) ?? [:]
        }
        let d = try doc()
        let rounds = (d["rounds"] as? [[String: Any]]) ?? []
        a.equal("progress: two appends produce two rounds", rounds.count, 2)
        a.equal("progress: round numbers ascend from 0",
                rounds.compactMap { $0["round"] as? Int }, [0, 1])
        a.check("progress: top level is schema 2 with title, pass_line, generated_at",
                d["schema"] as? Int == 2 && d["title"] != nil
                    && (d["pass_line"] as? [String: Any])?.count ?? 0 >= 5
                    && (d["generated_at"] as? String)?.hasSuffix("Z") == true,
                "schema \(String(describing: d["schema"])), keys \(d.keys.sorted().joined(separator: ", "))")

        let required = ["round", "label", "timestamp", "headline", "biggest_gap", "surfaces"]
        let last = rounds.last ?? [:]
        a.check("progress: a round carries every required field from web/README.md",
                required.allSatisfy { last[$0] != nil },
                "missing " + required.filter { last[$0] == nil }.joined(separator: ", "))
        a.check("progress: explicit headline and gap override the auto text",
                last["headline"] as? String == "hand-written headline"
                    && last["biggest_gap"] as? String == "hand-written gap",
                "\(last["headline"] as? String ?? "nil") / \(last["biggest_gap"] as? String ?? "nil")")

        let surfaces = (last["surfaces"] as? [String: Any]) ?? [:]
        a.check("progress: all three surfaces present, pooled left out by default",
                Set(surfaces.keys) == ["desk", "soft", "lap"],
                surfaces.keys.sorted().joined(separator: ", "))

        let desk = (surfaces["desk"] as? [String: Any]) ?? [:]
        let taps = (desk["taps"] as? [String: Any]) ?? [:]
        a.check("progress: schema 2 taps block, keyed by tap count plus 'any'",
                taps["any"] != nil && taps["2"] != nil
                    && Set(taps.keys).isSubset(of: ["1", "2", "3", "any"]),
                taps.keys.sorted().joined(separator: ", "))

        let metrics = ((taps["2"] as? [String: Any])?["metrics"] as? [String: Any]) ?? [:]
        let renderable = ["detection_rate", "false_triggers_typing", "false_triggers_confound",
                          "false_triggers_per_20min", "latency_p50_ms", "latency_p95_ms",
                          "latency_max_ms", "stuck_modifiers"]
        a.check("progress: every metric key web/schema.py knows is present, and nothing else",
                renderable.allSatisfy { metrics[$0] != nil } && Set(metrics.keys) == Set(renderable),
                "got " + metrics.keys.sorted().joined(separator: ", "))
        a.check("progress: a metric entry carries only value/n/pass/note",
                metrics.values.allSatisfy { v in
                    guard let d = v as? [String: Any] else { return false }
                    return Set(d.keys).isSubset(of: ["value", "n", "pass", "note"])
                },
                "entry fields checked against web/schema.py")
        a.check("progress: stuck_modifiers is null, not a zero that would read as a pass",
                ((metrics["stuck_modifiers"] as? [String: Any])?["value"] as? NSNull) != nil,
                "\(String(describing: (metrics["stuck_modifiers"] as? [String: Any])?["value"]))")
        let anyMetrics = ((taps["any"] as? [String: Any])?["metrics"] as? [String: Any]) ?? [:]
        let ftNote = ((anyMetrics["false_triggers_per_20min"] as? [String: Any])?["note"] as? String) ?? ""
        a.check("progress: the 'any' column names the per-tap-count split",
                ftNote.contains("by tap count"), ftNote.isEmpty ? "no note" : ftNote)
        let cov = (desk["coverage"] as? [String: Any]) ?? [:]
        a.check("progress: coverage carries sessions, minutes and tap_groups",
                ["sessions", "minutes", "typing_minutes", "confound_minutes", "tap_groups"]
                    .allSatisfy { cov[$0] != nil },
                cov.keys.sorted().joined(separator: ", "))

        // An accidental second write of the same round number must not silently
        // replace a scored round on a page the operator is watching.
        var refused = false
        do {
            _ = try ProgressFeed.append(report: report, options: ProgressOptions(path: feed, round: 0))
        } catch { refused = true }
        a.check("progress: refuses to overwrite an existing round without --progress-replace",
                refused, refused ? "threw as required" : "overwrote it")
        _ = try ProgressFeed.append(report: report, options: ProgressOptions(
            path: feed, round: 0, label: "replaced", replace: true))
        let after = (try doc()["rounds"] as? [[String: Any]]) ?? []
        a.check("progress: --progress-replace replaces in place, count unchanged",
                after.count == 2 && (after.first?["label"] as? String) == "replaced",
                "\(after.count) rounds, first label \(after.first?["label"] as? String ?? "nil")")

        // Unknown top-level keys must survive; the lead agent edits this file too.
        var raw = try doc()
        raw["operator_note"] = "hand-added, must survive"
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted]).write(to: feed)
        _ = try ProgressFeed.append(report: report, options: ProgressOptions(path: feed))
        a.check("progress: hand-added top-level keys survive an append",
                (try doc()["operator_note"] as? String) == "hand-added, must survive",
                "\(String(describing: try doc()["operator_note"]))")

        // A schema-1 file predates tap counts. Its flat metrics belong to double
        // tap and nothing else; migrating must add columns, never invent data.
        let legacy = scratch.appendingPathComponent("progress/legacy.json")
        let legacyDoc: [String: Any] = [
            "schema": 1,
            "title": "legacy",
            "generated_at": "2026-08-13T18:20:00Z",
            "pass_line": ["detection_rate": ["op": ">=", "value": 98, "unit": "%"]],
            "rounds": [[
                "round": 0, "label": "seed", "timestamp": "2026-08-13T18:20:00Z",
                "headline": "h", "biggest_gap": "g",
                "surfaces": ["desk": [
                    "coverage": ["sessions": 0],
                    "metrics": ["detection_rate": ["value": NSNull(), "n": 0]],
                ]],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: legacyDoc, options: [.prettyPrinted]).write(to: legacy)
        _ = try ProgressFeed.append(report: report, options: ProgressOptions(path: legacy))
        let migrated = (try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? [String: Any]) ?? [:]
        let seed = ((migrated["rounds"] as? [[String: Any]]) ?? []).first ?? [:]
        let seedDesk = ((seed["surfaces"] as? [String: Any])?["desk"] as? [String: Any]) ?? [:]
        a.check("progress: a schema-1 file migrates, old metrics land under tap count 2",
                migrated["schema"] as? Int == 2 && seedDesk["metrics"] == nil
                    && ((seedDesk["taps"] as? [String: Any])?["2"] as? [String: Any])?["metrics"] != nil,
                "schema \(String(describing: migrated["schema"])), "
                + "seed keys \(seedDesk.keys.sorted().joined(separator: ", "))")
    }

    /// Planted counts for the per-tap-count scenarios. Named so the printed summary
    /// can quote them next to what the harness measured.
    static let plantedSingles = 5
    static let plantedTriples = 4

    /// The per-tap-count contract, and the regression the critic found.
    ///
    /// The bug: a trigger landing within ±150 ms of a labelled **single** tap used
    /// to claim that group, which made `isFP` false, while the detection
    /// denominator only counted `intent == double` groups. The trigger vanished
    /// from both numbers. A single tap must never fire, so that trigger is a false
    /// trigger and has to be counted as one.
    private static func tapCountChecks(root: URL, stamp: String,
                                       config: DetectorConfig, into a: inout Assertions) throws {
        let singleDir = try Synth.write(Synth.singleTapsWithBounce(count: plantedSingles),
                                        root: root, stamp: stamp, shortId: "sing1")
        var tripleConfig = config
        tripleConfig.tapCountToFire = 3
        let tripleDir = try Synth.write(
            Synth.multiTaps(count: plantedTriples, tapsPerGesture: 3, surface: .desk,
                            category: .tapPalmrest, seed: 61),
            root: root, stamp: stamp, shortId: "trip1")

        let armedDouble = ScoringPolicy(armedCounts: [2])
        let armedSingle = ScoringPolicy(armedCounts: [1])
        let armedAll = ScoringPolicy(armedCounts: [1, 2, 3])
        let armedTriple = ScoringPolicy(armedCounts: [3])

        // --- the regression, through the real replay path ---------------------
        let singleSession = try Session(directory: singleDir)
        let singleReplay = try Replay.run(session: singleSession, config: config)
        let singleScore = try SessionScorer.score(session: singleSession, replay: singleReplay,
                                                  policy: armedDouble)
        a.equal("single taps: triggers the detector emitted", singleScore.triggerCount, plantedSingles)
        a.equal("single taps: FALSE TRIGGERS (a single tap must never fire)",
                singleScore.falsePositives, plantedSingles)
        a.equal("single taps: armed (2-tap) groups — a single is not one",
                singleScore.armedGroups, 0)
        a.equal("single taps: must-not-fire groups", singleScore.mustNotFireGroups, plantedSingles)
        a.equal("single taps: must-not-fire groups that fired anyway",
                singleScore.mustNotFireViolations, plantedSingles)
        a.equal("single taps: false triggers attributed to the 2-tap count",
                singleScore.perCount.first { $0.count == 2 }?.falseTriggers ?? -1, plantedSingles)
        a.equal("single taps: labelled 1-tap groups counted",
                singleScore.perCount.first { $0.count == 1 }?.labelledGroups ?? -1, plantedSingles)
        a.check("single taps: every false trigger says why",
                singleScore.triggers.allSatisfy { !$0.isFalsePositive || $0.falseTriggerReason.contains("NOT armed") },
                singleScore.triggers.first?.falseTriggerReason ?? "no triggers")

        // --- the same labels, scored with the counts armed differently --------
        // Fabricated triggers, so this measures the rule and not the stub.
        let singleLabels = try singleSession.labelGroups().compactMap { $0.last?.tNs }
        func fabricate(_ session: Session, _ triggers: [Trigger], _ p: ScoringPolicy) throws -> SessionScore {
            var r = ReplayResult()
            r.triggers = triggers
            return try SessionScorer.score(session: session, replay: r, policy: p)
        }
        let oneTapTriggers = singleLabels.map {
            Trigger(tNs: $0 + config.confirmWindowNs, tapOnsets: [$0], score: 1)
        }
        let singleArmed = try fabricate(singleSession, oneTapTriggers, armedSingle)
        a.equal("1-tap armed: single taps detected", singleArmed.detectedGroups, plantedSingles)
        a.equal("1-tap armed: false triggers", singleArmed.falsePositives, 0)
        let armedRate: Double? = singleArmed.perCount.first { $0.count == 1 }?.detectionRate ?? nil
        a.check("1-tap armed: detection rate is reported for count 1",
                armedRate == 1.0, Fmt.pct(armedRate))

        let singleUnarmed = try fabricate(singleSession, oneTapTriggers, armedDouble)
        a.equal("1-tap NOT armed: same triggers are all false", singleUnarmed.falsePositives, plantedSingles)
        a.equal("1-tap NOT armed: attributed to the 1-tap count",
                singleUnarmed.perCount.first { $0.count == 1 }?.falseTriggers ?? -1, plantedSingles)

        // Right place, wrong gesture: a 2-tap trigger sitting on a labelled single
        // tap while both counts are armed. The action that fires is the wrong one.
        let wrongCount = singleLabels.map {
            Trigger(tNs: $0 + config.confirmWindowNs, tapOnsets: [$0 - 160_000_000, $0], score: 1)
        }
        let mismatched = try fabricate(singleSession, wrongCount, armedAll)
        a.equal("wrong count on an armed gesture: detections", mismatched.detectedGroups, 0)
        a.equal("wrong count on an armed gesture: false triggers", mismatched.falsePositives, plantedSingles)
        a.equal("wrong count: attributed to the count that fired (2)",
                mismatched.perCount.first { $0.count == 2 }?.falseTriggers ?? -1, plantedSingles)
        a.equal("wrong count: the 1-tap group is missed, not detected",
                mismatched.perCount.first { $0.count == 1 }?.missedGroups ?? -1, plantedSingles)

        // --- triple ------------------------------------------------------------
        let tripleSession = try Session(directory: tripleDir)
        let tripleReplay = try Replay.run(session: tripleSession, config: tripleConfig)
        let tripleScore = try SessionScorer.score(session: tripleSession, replay: tripleReplay,
                                                  policy: armedTriple)
        a.equal("3-tap armed: triples detected", tripleScore.detectedGroups, plantedTriples)
        a.equal("3-tap armed: false triggers", tripleScore.falsePositives, 0)
        a.equal("3-tap armed: detections attributed to the 3-tap count",
                tripleScore.perCount.first { $0.count == 3 }?.detectedGroups ?? -1, plantedTriples)
        let tripleUnarmed = try SessionScorer.score(session: tripleSession, replay: tripleReplay,
                                                    policy: armedDouble)
        a.equal("3-tap NOT armed: triples must not fire, and every trigger is false",
                tripleUnarmed.falsePositives, tripleScore.triggerCount)
        a.check("labelling mismatch is reported, not swallowed",
                tripleScore.labelIssues.count == plantedTriples,
                tripleScore.labelIssues.first
                    ?? "no issue raised for a 3-onset group carrying intent 'double'")

        // --- the pass line splits by count -------------------------------------
        var aggDouble = Aggregate(label: "desk")
        aggDouble.add(singleScore)
        let checksDouble = PassLine.perCountChecks(for: aggDouble, scope: "desk")
        a.check("pass line: 2-tap false triggers on labelled singles fail their own row",
                checksDouble.contains { $0.name == "false triggers per 20 min, 2-tap" && $0.status == .fail },
                checksDouble.map { "\($0.name) -> \($0.actual) [\($0.status.rawValue)]" }
                            .joined(separator: " | "))

        var aggSingle = Aggregate(label: "desk")
        aggSingle.add(singleUnarmed)
        let checksSingle = PassLine.perCountChecks(for: aggSingle, scope: "desk")
        a.check("pass line: an un-armed 1-tap that fired gets its own failing row",
                checksSingle.contains { $0.name == "triggers on un-armed 1-tap" && $0.status == .fail },
                checksSingle.map { "\($0.name) -> \($0.actual) [\($0.status.rawValue)]" }
                            .joined(separator: " | "))
    }

    /// Exercise the ±150 ms / "exactly one" rule directly, with fabricated triggers
    /// rather than a detector, so the rule is tested and not merely used.
    private static func matchingRuleChecks(cleanDir: URL, into a: inout Assertions) throws {
        let session = try Session(directory: cleanDir)
        let groups = try session.labelGroups()
        guard let g0 = groups.first, let second0 = g0.last?.tNs,
              let g1 = groups.dropFirst().first, let second1 = g1.last?.tNs else {
            a.check("matching rule: fixture", false, "clean session has no label groups")
            return
        }

        func scoreWith(_ triggers: [Trigger], policy: ScoringPolicy = ScoringPolicy(armedCounts: [2])) throws -> SessionScore {
            var r = ReplayResult()
            r.triggers = triggers
            return try SessionScorer.score(session: session, replay: r, policy: policy)
        }
        func trig(_ onset: Int64, fireOffset: Int64 = 180_000_000) -> Trigger {
            Trigger(tNs: onset + fireOffset, tapOnsets: [onset - 160_000_000, onset], score: 1)
        }

        let inside = try scoreWith([trig(second0 + 149_000_000)])
        a.check("matching: +149 ms counts as detected",
                inside.detectedGroups == 1 && inside.falsePositives == 0,
                "detected \(inside.detectedGroups), FP \(inside.falsePositives)")

        let outside = try scoreWith([trig(second0 + 151_000_000)])
        a.check("matching: +151 ms is a miss and a false positive",
                outside.detectedGroups == 0 && outside.falsePositives == 1,
                "detected \(outside.detectedGroups), FP \(outside.falsePositives)")

        let ambiguous = try scoreWith([trig(second0 - 10_000_000), trig(second0 + 20_000_000)])
        a.check("matching: two triggers in one window is ambiguous, not detected",
                ambiguous.detectedGroups == 0 && ambiguous.ambiguousGroups == 1 && ambiguous.falsePositives == 1,
                "detected \(ambiguous.detectedGroups), ambiguous \(ambiguous.ambiguousGroups), FP \(ambiguous.falsePositives)")

        let stray = try scoreWith([trig(second0), trig(second1), trig(second0 + 2_000_000_000)])
        a.check("matching: a trigger far from any label is a false positive",
                stray.detectedGroups == 2 && stray.falsePositives == 1,
                "detected \(stray.detectedGroups), FP \(stray.falsePositives)")

        let empty = try scoreWith([])
        a.check("matching: no triggers means no detections and no false positives",
                empty.detectedGroups == 0 && empty.falsePositives == 0,
                "detected \(empty.detectedGroups), FP \(empty.falsePositives)")
    }
}

/// Records exactly what the replay handed it, in order. Used to check the merge
/// directly instead of guessing at it from the triggers that came out.
private final class OrderProbe: TapDetecting {
    var config = DetectorConfig.default
    /// Never fires, so nothing is armed. Stated rather than inherited, because
    /// the harness refuses to grade a detector whose armed set it cannot read.
    var effectiveArmedTapCounts: Set<Int> { [] }
    private(set) var log: [String] = []

    func ingest(sample: AccelSample) -> Trigger? { log.append("s@\(sample.tNs)"); return nil }
    func ingest(input: InputEvent) { log.append("i@\(input.tNs)") }
    func drainOnsets() -> [OnsetEvent] { [] }
    func reset() { log.removeAll() }
}
