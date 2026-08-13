import Foundation
import TunkCore
import TunkFormat

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case holdout(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let m): return "usage: \(m)"
        case .holdout(let m): return m
        case .failed(let m): return m
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 64
        case .holdout: return 77
        case .failed: return 1
        }
    }
}

/// Dumb, explicit flag parser. No dependencies, no magic, and an unknown flag is a
/// hard error so a mistyped option can never quietly change what got measured.
struct Args {
    private(set) var positionals: [String] = []
    private var flags: [String: String] = [:]
    private var bools: Set<String> = []
    private var consumed: Set<String> = []

    init(_ argv: [String], boolFlags: Set<String>) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if boolFlags.contains(name) {
                    bools.insert(name)
                } else if let eq = name.firstIndex(of: "=") {
                    flags[String(name[name.startIndex..<eq])] = String(name[name.index(after: eq)...])
                } else {
                    guard i + 1 < argv.count else {
                        throw CLIError.usage("flag --\(name) needs a value")
                    }
                    flags[name] = argv[i + 1]
                    i += 1
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    mutating func string(_ name: String) -> String? {
        consumed.insert(name)
        return flags[name]
    }

    mutating func bool(_ name: String) -> Bool {
        consumed.insert(name)
        return bools.contains(name)
    }

    mutating func int(_ name: String) throws -> Int? {
        guard let s = string(name) else { return nil }
        guard let v = Int(s) else { throw CLIError.usage("--\(name) expects an integer, got '\(s)'") }
        return v
    }

    mutating func double(_ name: String) throws -> Double? {
        guard let s = string(name) else { return nil }
        guard let v = Double(s) else { throw CLIError.usage("--\(name) expects a number, got '\(s)'") }
        return v
    }

    /// Call last. Anything the command never asked about is a typo.
    func checkUnknown() throws {
        let unknown = Set(flags.keys).union(bools).subtracting(consumed)
        if let first = unknown.sorted().first {
            throw CLIError.usage("unknown flag --\(first)")
        }
    }
}

/// The holdout guard. Builders tune on `data/raw`; the test set belongs to critics
/// only. Two independent tripwires: the path, and the `split` field inside every
/// session that was found. Either one demands `--i-am-a-critic`.
enum HoldoutGuard {
    static func pathLooksLikeHoldout(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains {
            $0.lowercased().contains("holdout") || $0.lowercased() == "test"
        }
    }

    static func check(root: URL, sessions: [Session], isCritic: Bool) throws -> [String] {
        let pathHit = pathLooksLikeHoldout(root)
        let splitHit = sessions.contains { $0.meta.split == .test }
        guard pathHit || splitHit else { return [] }

        let why = pathHit
            ? "the path \(root.path) is held-out test data"
            : "\(sessions.filter { $0.meta.split == .test }.count) session(s) there declare split=test"
        guard isCritic else {
            throw CLIError.holdout("""

            ┌──────────────────────────────────────────────────────────────────────┐
            │  REFUSING TO RUN: HELD-OUT TEST DATA                                  │
            └──────────────────────────────────────────────────────────────────────┘
            Reason: \(why).

            Builders tune on data/raw only. Scoring against the holdout during
            development leaks the test set and invalidates the whole run.

            If you are the critic, re-run with --i-am-a-critic.
            """)
        }
        return ["""

        ┌──────────────────────────────────────────────────────────────────────┐
        │  HOLDOUT RUN — CRITIC MODE                                           │
        │  Grading against held-out test data. These numbers are the verdict.  │
        │  Do not feed them back into tuning.                                  │
        └──────────────────────────────────────────────────────────────────────┘
        Reason: \(why).
        """]
    }
}

enum Paths {
    /// Resolve a user-supplied path against the current directory.
    static func resolve(_ p: String) -> URL {
        URL(fileURLWithPath: (p as NSString).expandingTildeInPath,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }
}

let usageText = """
tunk-score \(TunkScoreVersion.string) — the referee for the Tunk detector.

  tunk-score run [--data <dir>] [--config <json>] [--json <out>] [--md <out>]
                 [--armed 1,2,3] [--i-am-a-critic] [--verbose]
                 [--check-determinism] [--detector real|stub]
                 [--progress-json <file>] [--progress-label <text>]
                 [--progress-headline <text>] [--progress-gap <text>]
                 [--progress-round <n>] [--progress-status <text>]
                 [--progress-pooled] [--progress-replace]
      Replay every session under <dir> (default data/raw) through the detector and
      grade it against the pass line in FORMAT.md. Exit code 0 = PASS,
      1 = FAIL, 3 = INCOMPLETE (something had no data behind it).
      --detector picks the implementation: `real` is TunkCore.TapDetector,
      `stub` is the harness's own placeholder. Default real.
      --armed lists the tap counts the detector fires on (default: the config's
      tapCountToFire). Every metric is broken down per tap count, and a trigger
      with an un-armed tap count is a false trigger.
      --progress-json appends a round to the progress page feed in the shape
      web/README.md documents. Re-run `python3 web/render.py` afterwards.

  tunk-score sweep --param <name> --from <a> --to <b> --steps <n>
                   [--data <dir>] [--config <json>] [--md <out>] [--json <out>]
                   [--armed 1,2,3] [--detector real|stub] [--i-am-a-critic]
      Re-run the whole set once per parameter value and print a table.
      Names: \(ConfigParam.allCases.map(\.name).joined(separator: ", "))
      (any ...Ns name also accepts its ...Ms alias, e.g. --param gateWindowMs)

  tunk-score explain <session-dir> [--config <json>] [--md <out>] [--armed 1,2,3]
                     [--detector real|stub] [--i-am-a-critic]
      Per-trigger trace for one session: onsets, strengths, gate state, and why
      each labelled group did or did not fire.

  tunk-score progress --from <report.json> [--out web/progress.json]
                      [--round <n>] [--label <text>] [--headline <text>]
                      [--gap <text>] [--status <text>] [--pooled] [--replace]
      Append a round to the progress page feed from a report `run --json` already
      wrote. Same output shape as `run --progress-json`, without replaying.
      Then run `python3 web/render.py` — the page will not update on its own.

  tunk-score selftest [--dir <scratch>] [--keep] [--detector real|stub]
      Write synthetic sessions in the real FORMAT.md layout with a known number of
      planted double-taps, grade them, and assert the harness reports exactly what
      was planted. Also proves the replay interleave, determinism, and that the
      detector never reads a wall clock. Defaults to --detector stub, because it
      is testing the harness; point it at `real` to run the planted scenarios
      through the shipping detector.

Any run touching data/holdout, or any session declaring split=test, is refused
unless --i-am-a-critic is passed. Builders tune on data/raw only.

Global: --version, --help
"""
