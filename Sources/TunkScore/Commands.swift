import Foundation
import TunkCore
import TunkFormat

enum Commands {

    /// `--armed 1,2,3`. Absent, the armed set is whatever the config fires on.
    static func armedOverride(_ args: inout Args) throws -> [Int]? {
        guard let raw = args.string("armed") else { return nil }
        return try ScoringPolicy.parse(raw)
    }

    /// Push `--armed` into the config so it reaches the DETECTOR, not just the
    /// grader.
    ///
    /// This existed as a grading-side override only, which meant `--armed 1`
    /// scored a tap count the detector was never armed for. On a probe of ten
    /// isolated thumps, `--config '{"tapCountToFire":1}'` reported 10 false
    /// triggers and `--armed 1` reported 0, from the same data and the same
    /// binary, with the banner printing "armed 1 tap(s)" both times. The harness
    /// answered the question it was asked rather than the one the machine
    /// settled, which is the one thing a referee must never do.
    static func applyArmed(_ armed: [Int]?, to config: inout DetectorConfig) {
        guard let armed else { return }
        config.armedTapCounts = Set(armed)
    }

    /// Collect the `--progress-*` flags. Returns nil when `--progress-json` is absent.
    static func progressOptions(_ args: inout Args) throws -> ProgressOptions? {
        let path = args.string("progress-json")
        let round = try args.int("progress-round")
        let label = args.string("progress-label")
        let headline = args.string("progress-headline")
        let gap = args.string("progress-gap")
        let status = args.string("progress-status")
        let pooled = args.bool("progress-pooled")
        let replace = args.bool("progress-replace")
        guard let path else {
            for (name, present) in [("progress-round", round != nil), ("progress-label", label != nil),
                                    ("progress-headline", headline != nil), ("progress-gap", gap != nil),
                                    ("progress-status", status != nil), ("progress-pooled", pooled),
                                    ("progress-replace", replace)] where present {
                throw CLIError.usage("--\(name) needs --progress-json <file>")
            }
            return nil
        }
        return ProgressOptions(path: Paths.resolve(path), round: round, label: label,
                               headline: headline, biggestGap: gap, status: status,
                               includePooled: pooled, replace: replace)
    }

    // MARK: - run

    static func run(_ args: inout Args) throws -> Int32 {
        let rootPath = args.string("data") ?? "data/raw"
        let root = Paths.resolve(rootPath)
        let configPath = args.string("config")
        let jsonOut = args.string("json")
        let mdOut = args.string("md")
        let isCritic = args.bool("i-am-a-critic")
        let verbose = args.bool("verbose")
        let checkDeterminism = args.bool("check-determinism")
        let armed = try armedOverride(&args)
        let progress = try progressOptions(&args)
        try DetectorFactory.select(args.string("detector"), default: .real)
        try args.checkUnknown()

        var config = DetectorConfig.default
        if let p = configPath { config = try ConfigIO.load(url: Paths.resolve(p)) }
        applyArmed(armed, to: &config)
        try ConfigIO.validate(config)
        let policy = ScoringPolicy.from(config: config, override: armed)

        // Tripwire 1 fires before a single byte of the directory is read.
        if HoldoutGuard.pathLooksLikeHoldout(root) && !isCritic {
            _ = try HoldoutGuard.check(root: root, sessions: [], isCritic: false)
        }

        let sessions = try Session.discover(root: root)
        // The banner lands in the report's warnings, which the console, the JSON
        // and the markdown all carry, so it cannot be lost by redirecting stdout.
        var warnings = try HoldoutGuard.check(root: root, sessions: sessions, isCritic: isCritic)

        // Tripwire: the grader and the detector must agree on what was armed.
        // When they diverged, `--armed 1` scored a count the detector never fired
        // on and reported a clean 0.00 while the same data under
        // `--config '{"tapCountToFire":1}'` reported 200.00. Nothing on screen
        // distinguished the two runs. Refuse to grade rather than print a number
        // whose provenance is a flag instead of a machine.
        // Ask the detector itself. Casting to a concrete type and falling back to
        // the config would compare the config against the config, which is how
        // the stub passed this check while armed for one count and graded
        // against three.
        let detectorArmed = DetectorFactory.make(config: config).effectiveArmedTapCounts
        if detectorArmed != Set(policy.armedCounts) {
            throw CLIError.usage(
                "armed-set mismatch: the detector is armed for \(detectorArmed.sorted()) but "
                + "grading was asked for \(policy.armedCounts.sorted()). Refusing to grade — "
                + "a pass line computed against a count the detector never fired on is worthless.")
        }

        var scores: [SessionScore] = []
        for s in sessions {
            let replay = try Replay.run(session: s, config: config)
            if replay.deliveryOrderViolations > 0 {
                warnings.append("\(s.meta.sessionId): \(replay.deliveryOrderViolations) delivery-order violations during replay")
            }
            if replay.unsortedSamples > 0 || replay.unsortedInputs > 0 {
                warnings.append("\(s.meta.sessionId): file not ascending in t_ns "
                                + "(\(replay.unsortedSamples) samples, \(replay.unsortedInputs) inputs reordered)")
            }
            if checkDeterminism {
                let again = try Replay.run(session: s, config: config)
                if again.triggers != replay.triggers {
                    warnings.append("\(s.meta.sessionId): NON-DETERMINISTIC — two identical replays produced different triggers")
                }
            }
            // A session that says it holds gestures but carries no labels is
            // either an unlabelled recording or a failed one, and either way
            // every detection number computed from it is silently wrong. Left
            // alone it reads as a neutral "0 labelled groups", which is an
            // absence dressed up as a non-event — the exact failure this
            // harness exists to catch.
            let labelledGroups = (try? s.labelGroups().count) ?? 0
            if s.meta.expectedTriggers > 0 && labelledGroups == 0 {
                warnings.append("\(s.meta.sessionId): meta claims \(s.meta.expectedTriggers) "
                    + "expected trigger(s) but labels.jsonl is empty — run `tunk-label run` on it, "
                    + "or check the taps actually landed with `tunk-label check`. "
                    + "It contributes NOTHING to detection rate as it stands.")
            } else if s.meta.expectedTriggers > 0 && labelledGroups != s.meta.expectedTriggers {
                warnings.append("\(s.meta.sessionId): meta claims \(s.meta.expectedTriggers) "
                    + "expected trigger(s) but \(labelledGroups) group(s) are labelled — "
                    + "some prompted gestures did not land, so the detection denominator "
                    + "is smaller than the operator intended.")
            }
            if s.meta.category.isTapCategory && s.meta.expectedTriggers == 0 && labelledGroups == 0 {
                warnings.append("\(s.meta.sessionId): a tap session with no expected triggers "
                    + "and no labels. It is scored only for false positives.")
            }

            let score = try SessionScorer.score(session: s, replay: replay, policy: policy)
            if verbose {
                print("\(Reporter.pad(s.meta.sessionId, 46)) armed groups \(score.armedGroups) "
                      + "detected \(score.detectedGroups) must-not-fire \(score.mustNotFireGroups) "
                      + "triggers \(score.triggerCount) FP \(score.falsePositives)")
            }
            scores.append(score)
        }

        let splitLabel = sessions.first?.meta.split.rawValue ?? "unknown"
        let report = Reporter.build(dataRoot: root, split: splitLabel, config: config,
                                    policy: policy, scores: scores, warnings: warnings)
        print(Reporter.console(report))
        if let p = jsonOut {
            try Reporter.writeJSON(report, to: Paths.resolve(p))
            print("wrote \(Paths.resolve(p).path)")
        }
        if let p = mdOut {
            try Reporter.markdown(report).write(to: Paths.resolve(p), atomically: true, encoding: .utf8)
            print("wrote \(Paths.resolve(p).path)")
        }
        if let progress {
            for line in try ProgressFeed.append(report: report, options: progress) { print(line) }
        }

        switch report.verdict {
        case .pass: return 0
        case .fail: return 1
        case .incomplete: return 3
        }
    }

    // MARK: - noise

    static func noise(_ args: inout Args) throws -> Int32 {
        let rootPath = args.string("data") ?? "data/raw"
        let root = Paths.resolve(rootPath)
        let configPath = args.string("config")
        let mdOut = args.string("md")
        let isCritic = args.bool("i-am-a-critic")
        let guardMs = try args.double("guard-ms") ?? 400
        try args.checkUnknown()

        var config = DetectorConfig.default
        if let p = configPath { config = try ConfigIO.load(url: Paths.resolve(p)) }
        try ConfigIO.validate(config)

        if HoldoutGuard.pathLooksLikeHoldout(root) && !isCritic {
            _ = try HoldoutGuard.check(root: root, sessions: [], isCritic: false)
        }
        let sessions = try Session.discover(root: root)
        let banners = try HoldoutGuard.check(root: root, sessions: sessions, isCritic: isCritic)
        for w in banners { FileHandle.standardError.write(Data((w + "\n").utf8)) }
        guard !sessions.isEmpty else {
            throw CLIError.failed("no sessions under \(root.path); nothing to measure")
        }

        let tuning = DetectorFactory.tuning
        var stats: [NoiseProbe.SessionStats] = []
        for s in sessions {
            stats.append(try NoiseProbe.measure(session: s, config: config, tuning: tuning,
                                                guardNs: Int64(guardMs * 1e6)))
        }
        let text = NoiseProbe.report(stats, config: config, tuning: tuning,
                                     guardMs: guardMs, root: root)
        print(text)
        if let p = mdOut {
            try text.write(to: Paths.resolve(p), atomically: true, encoding: .utf8)
            print("wrote \(Paths.resolve(p).path)")
        }
        return 0
    }

    // MARK: - sweep

    struct SweepRow: Codable {
        var value: Double
        var displayValue: String
        var sessions: Int
        var armedGroups: Int
        var detected: Int
        var detectionRate: Double?
        var triggers: Int
        var falsePositives: Int
        var typingFalsePositives: Int
        var confoundFalsePositives: Int
        var falsePositivesPer20Min: Double?
        var latencyP50Ns: Int64?
        var latencyP95Ns: Int64?
        var verdict: String
        /// What the detector actually ran, when `madeCoherent()` clamped the
        /// swept value. Nil when the value survived untouched.
        ///
        /// Without this a sweep past the clamp is a flat curve with nothing on
        /// screen to explain it, which reads as "this parameter does nothing"
        /// rather than "every step past here ran the same number".
        var inForce: String?
    }

    static func sweep(_ args: inout Args) throws -> Int32 {
        guard let paramName = args.string("param") else {
            throw CLIError.usage("sweep needs --param <name>. Known: " + ConfigParam.allNames.joined(separator: ", "))
        }
        guard let param = ConfigParam(name: paramName) else {
            throw CLIError.usage("unknown --param '\(paramName)'. Known: " + ConfigParam.allNames.joined(separator: ", "))
        }
        guard let from = try args.double("from"), let to = try args.double("to") else {
            throw CLIError.usage("sweep needs --from <a> --to <b>")
        }
        let steps = try args.int("steps") ?? 5
        guard steps >= 1 else { throw CLIError.usage("--steps must be at least 1") }

        let rootPath = args.string("data") ?? "data/raw"
        let root = Paths.resolve(rootPath)
        let configPath = args.string("config")
        let mdOut = args.string("md")
        let jsonOut = args.string("json")
        let isCritic = args.bool("i-am-a-critic")
        let armed = try armedOverride(&args)
        try DetectorFactory.select(args.string("detector"), default: .real)
        try args.checkUnknown()

        var base = DetectorConfig.default
        if let p = configPath { base = try ConfigIO.load(url: Paths.resolve(p)) }

        if HoldoutGuard.pathLooksLikeHoldout(root) && !isCritic {
            _ = try HoldoutGuard.check(root: root, sessions: [], isCritic: false)
        }
        let sessions = try Session.discover(root: root)
        let banners = try HoldoutGuard.check(root: root, sessions: sessions, isCritic: isCritic)
        for w in banners { FileHandle.standardError.write(Data((w + "\n").utf8)) }
        guard !sessions.isEmpty else {
            throw CLIError.failed("no sessions under \(root.path); nothing to sweep")
        }

        // Load each session once, not once per step.
        var loaded: [(Session, [AccelSample], [InputEvent])] = []
        for s in sessions {
            loaded.append((s, try s.samples(), try s.inputs().map(\.event)))
        }

        let scale = ConfigParam.scale(forName: paramName)
        var rows: [SweepRow] = []
        for i in 0..<steps {
            let frac = steps == 1 ? 0 : Double(i) / Double(steps - 1)
            let value = from + (to - from) * frac
            var cfg = base
            param.set(&cfg, value * scale)
            do { try ConfigIO.validate(cfg) } catch {
                rows.append(SweepRow(value: value, displayValue: fmtValue(value, paramName),
                                     sessions: 0, armedGroups: 0, detected: 0, detectionRate: nil,
                                     triggers: 0, falsePositives: 0, typingFalsePositives: 0,
                                     confoundFalsePositives: 0, falsePositivesPer20Min: nil,
                                     latencyP50Ns: nil, latencyP95Ns: nil, verdict: "invalid",
                                     inForce: nil))
                continue
            }

            // The detector clamps an incoherent config on every write, so a step
            // past `confirmWindowNs` runs a different number than the one in the
            // first column. Say which, per row, rather than printing a flat tail.
            let coherent = cfg.madeCoherent()
            let inForce = param.get(cfg) != param.get(coherent) ? param.display(coherent) : nil

            // The armed set follows the swept config unless --armed pinned it, so a
            // sweep over tapCountToFire scores each step against what it fires on.
            applyArmed(armed, to: &cfg)
            let policy = ScoringPolicy.from(config: cfg, override: armed)
            var scores: [SessionScore] = []
            for (s, samples, inputs) in loaded {
                let detector = DetectorFactory.make(config: cfg)
                detector.reset()
                let replay = Replay.run(samples: samples, inputs: inputs, detector: detector,
                                        nominalIntervalNs: max(1, s.meta.nominalIntervalNs))
                scores.append(try SessionScorer.score(session: s, replay: replay, policy: policy))
            }
            let (pooled, surfaces, _) = Reporter.aggregate(scores)
            let (verdict, _) = PassLine.verdict(perSurface: surfaces, pooled: pooled)
            rows.append(SweepRow(
                value: value, displayValue: fmtValue(value, paramName),
                sessions: pooled.sessions, armedGroups: pooled.armedGroups,
                detected: pooled.detectedGroups, detectionRate: pooled.detectionRate,
                triggers: pooled.triggerCount, falsePositives: pooled.falsePositives,
                typingFalsePositives: pooled.typingFalsePositives,
                confoundFalsePositives: pooled.confoundFalsePositives,
                falsePositivesPer20Min: pooled.falsePositivesPer20Min,
                latencyP50Ns: pooled.latencyP50Ns, latencyP95Ns: pooled.latencyP95Ns,
                verdict: verdict.rawValue, inForce: inForce))
        }

        let table = sweepTable(param: paramName, rows: rows, sessions: sessions.count, root: root)
        print(table)
        if let p = mdOut {
            try table.write(to: Paths.resolve(p), atomically: true, encoding: .utf8)
            print("wrote \(Paths.resolve(p).path)")
        }
        if let p = jsonOut {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(rows).write(to: Paths.resolve(p))
            print("wrote \(Paths.resolve(p).path)")
        }
        return 0
    }

    private static func fmtValue(_ v: Double, _ name: String) -> String {
        name.hasSuffix("Ms") ? String(format: "%.1f ms", v) : String(format: "%g", v)
    }

    private static func sweepTable(param: String, rows: [SweepRow], sessions: Int, root: URL) -> String {
        var out = "# tunk-score sweep: `\(param)`\n\n"
        out += "- data root: `\(root.path)` (\(sessions) sessions)\n"
        out += "- detector: `\(DetectorFactory.backendName)`\n\n"
        out += "| \(param) | detected | rate | triggers | FP | FP typing | FP confound | FP/20min | lat p50 | lat p95 | verdict |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in rows {
            let asked = r.inForce.map { "\(r.displayValue) → \($0)" } ?? r.displayValue
            out += "| \(asked) | \(r.detected)/\(r.armedGroups) | \(Fmt.pct(r.detectionRate)) | "
            out += "\(r.triggers) | \(r.falsePositives) | \(r.typingFalsePositives) | \(r.confoundFalsePositives) | "
            out += "\(Fmt.num(r.falsePositivesPer20Min)) | \(Fmt.msOpt(r.latencyP50Ns)) | "
            out += "\(Fmt.msOpt(r.latencyP95Ns)) | \(r.verdict) |\n"
        }
        let clamped = rows.filter { $0.inForce != nil }
        if !clamped.isEmpty {
            out += "\n**\(clamped.count) of \(rows.count) steps ran a different value than the one "
                + "asked for.** `a → b` means the detector clamped `a` to `b` to keep "
                + "`minInterTapNs <= maxInterTapNs <= confirmWindowNs`. Those rows repeat the same "
                + "measurement, so read the flat tail as the clamp, not as the parameter having "
                + "no effect.\n"
        }
        return out
    }

    // MARK: - explain

    static func explain(_ args: inout Args) throws -> Int32 {
        guard let dir = args.positionals.dropFirst().first else {
            throw CLIError.usage("explain needs a session directory")
        }
        let url = Paths.resolve(dir)
        let configPath = args.string("config")
        let mdOut = args.string("md")
        let isCritic = args.bool("i-am-a-critic")
        let armed = try armedOverride(&args)
        try DetectorFactory.select(args.string("detector"), default: .real)
        try args.checkUnknown()

        if HoldoutGuard.pathLooksLikeHoldout(url) && !isCritic {
            _ = try HoldoutGuard.check(root: url, sessions: [], isCritic: false)
        }
        var config = DetectorConfig.default
        if let p = configPath { config = try ConfigIO.load(url: Paths.resolve(p)) }
        applyArmed(armed, to: &config)
        let policy = ScoringPolicy.from(config: config, override: armed)

        let session = try Session(directory: url)
        for w in try HoldoutGuard.check(root: url, sessions: [session], isCritic: isCritic) {
            FileHandle.standardError.write(Data((w + "\n").utf8))
        }

        let text = try Explainer.trace(session: session, config: config, policy: policy)
        print(text)
        if let p = mdOut {
            try text.write(to: Paths.resolve(p), atomically: true, encoding: .utf8)
            print("wrote \(Paths.resolve(p).path)")
        }
        return 0
    }

    // MARK: - progress

    /// Turn a report `tunk-score run --json` already wrote into a round on the
    /// progress page. Same code path as `run --progress-json`; this exists so a
    /// round can be (re)published without replaying the whole dataset.
    static func progress(_ args: inout Args) throws -> Int32 {
        guard let from = args.string("from") else {
            throw CLIError.usage("progress needs --from <report.json> (written by `run --json`)")
        }
        let out = args.string("out") ?? "web/progress.json"
        let round = try args.int("round")
        let label = args.string("label")
        let headline = args.string("headline")
        let gap = args.string("gap")
        let status = args.string("status")
        let pooled = args.bool("pooled")
        let replace = args.bool("replace")
        try args.checkUnknown()

        let url = Paths.resolve(from)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw CLIError.failed("cannot read \(url.path): \(error.localizedDescription)")
        }
        let report: RunReport
        do { report = try JSONDecoder().decode(RunReport.self, from: data) } catch {
            throw CLIError.failed("\(url.path) is not a tunk-score run report: \(error)")
        }

        let options = ProgressOptions(path: Paths.resolve(out), round: round, label: label,
                                      headline: headline, biggestGap: gap, status: status,
                                      includePooled: pooled, replace: replace)
        for line in try ProgressFeed.append(report: report, options: options) { print(line) }
        return 0
    }
}
