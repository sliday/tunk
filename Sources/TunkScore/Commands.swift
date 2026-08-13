import Foundation
import TunkCore
import TunkFormat

enum Commands {

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
        try DetectorFactory.select(args.string("detector"), default: .real)
        try args.checkUnknown()

        var config = DetectorConfig.default
        if let p = configPath { config = try ConfigIO.load(url: Paths.resolve(p)) }
        try ConfigIO.validate(config)

        // Tripwire 1 fires before a single byte of the directory is read.
        if HoldoutGuard.pathLooksLikeHoldout(root) && !isCritic {
            _ = try HoldoutGuard.check(root: root, sessions: [], isCritic: false)
        }

        let sessions = try Session.discover(root: root)
        // The banner lands in the report's warnings, which the console, the JSON
        // and the markdown all carry, so it cannot be lost by redirecting stdout.
        var warnings = try HoldoutGuard.check(root: root, sessions: sessions, isCritic: isCritic)

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
            let score = try SessionScorer.score(session: s, replay: replay)
            if verbose {
                print("\(Reporter.pad(s.meta.sessionId, 46)) groups \(score.doubleGroups) "
                      + "detected \(score.detectedGroups) triggers \(score.triggerCount) FP \(score.falsePositives)")
            }
            scores.append(score)
        }

        let splitLabel = sessions.first?.meta.split.rawValue ?? "unknown"
        let report = Reporter.build(dataRoot: root, split: splitLabel, config: config,
                                    scores: scores, warnings: warnings)
        print(Reporter.console(report))
        if let p = jsonOut {
            try Reporter.writeJSON(report, to: Paths.resolve(p))
            print("wrote \(Paths.resolve(p).path)")
        }
        if let p = mdOut {
            try Reporter.markdown(report).write(to: Paths.resolve(p), atomically: true, encoding: .utf8)
            print("wrote \(Paths.resolve(p).path)")
        }

        switch report.verdict {
        case .pass: return 0
        case .fail: return 1
        case .incomplete: return 3
        }
    }

    // MARK: - sweep

    struct SweepRow: Codable {
        var value: Double
        var displayValue: String
        var sessions: Int
        var doubleGroups: Int
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
                                     sessions: 0, doubleGroups: 0, detected: 0, detectionRate: nil,
                                     triggers: 0, falsePositives: 0, typingFalsePositives: 0,
                                     confoundFalsePositives: 0, falsePositivesPer20Min: nil,
                                     latencyP50Ns: nil, latencyP95Ns: nil, verdict: "invalid"))
                continue
            }

            var scores: [SessionScore] = []
            for (s, samples, inputs) in loaded {
                let detector = DetectorFactory.make(config: cfg)
                detector.reset()
                let replay = Replay.run(samples: samples, inputs: inputs, detector: detector,
                                        nominalIntervalNs: max(1, s.meta.nominalIntervalNs))
                scores.append(try SessionScorer.score(session: s, replay: replay))
            }
            let (pooled, surfaces, _) = Reporter.aggregate(scores)
            let (verdict, _) = PassLine.verdict(perSurface: surfaces, pooled: pooled)
            rows.append(SweepRow(
                value: value, displayValue: fmtValue(value, paramName),
                sessions: pooled.sessions, doubleGroups: pooled.doubleGroups,
                detected: pooled.detectedGroups, detectionRate: pooled.detectionRate,
                triggers: pooled.triggerCount, falsePositives: pooled.falsePositives,
                typingFalsePositives: pooled.typingFalsePositives,
                confoundFalsePositives: pooled.confoundFalsePositives,
                falsePositivesPer20Min: pooled.falsePositivesPer20Min,
                latencyP50Ns: pooled.latencyP50Ns, latencyP95Ns: pooled.latencyP95Ns,
                verdict: verdict.rawValue))
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
            out += "| \(r.displayValue) | \(r.detected)/\(r.doubleGroups) | \(Fmt.pct(r.detectionRate)) | "
            out += "\(r.triggers) | \(r.falsePositives) | \(r.typingFalsePositives) | \(r.confoundFalsePositives) | "
            out += "\(Fmt.num(r.falsePositivesPer20Min)) | \(Fmt.msOpt(r.latencyP50Ns)) | "
            out += "\(Fmt.msOpt(r.latencyP95Ns)) | \(r.verdict) |\n"
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
        try DetectorFactory.select(args.string("detector"), default: .real)
        try args.checkUnknown()

        if HoldoutGuard.pathLooksLikeHoldout(url) && !isCritic {
            _ = try HoldoutGuard.check(root: url, sessions: [], isCritic: false)
        }
        var config = DetectorConfig.default
        if let p = configPath { config = try ConfigIO.load(url: Paths.resolve(p)) }

        let session = try Session(directory: url)
        for w in try HoldoutGuard.check(root: url, sessions: [session], isCritic: isCritic) {
            FileHandle.standardError.write(Data((w + "\n").utf8))
        }

        let text = try Explainer.trace(session: session, config: config)
        print(text)
        if let p = mdOut {
            try text.write(to: Paths.resolve(p), atomically: true, encoding: .utf8)
            print("wrote \(Paths.resolve(p).path)")
        }
        return 0
    }
}
