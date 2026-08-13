import Foundation
import TunkFormat

// The accepted-flag table. One source of truth for parsing, validation and
// `--help`, so the three cannot drift apart.
//
// Why this exists: the parser used to accept any `--word` it saw and hand it to
// a `str()` lookup nobody made. `guide --category typing --duration 60` therefore
// ran all twelve phases at their default lengths and said nothing, which is an
// hour of an operator's time spent recording the wrong thing. Unknown flags are
// now a hard error that names the flag and prints what the subcommand accepts.

struct FlagSpec {
    let name: String
    /// `--flag value`. A value flag with nothing after it is an error, not `true`.
    let takesValue: Bool
    /// Placeholder shown in help, e.g. `<n>`.
    let arg: String
    let help: String

    init(_ name: String, _ arg: String, _ help: String) {
        self.name = name
        self.takesValue = !arg.isEmpty
        self.arg = arg
        self.help = help
    }
}

struct CommandSpec {
    let name: String
    let synopsis: String
    let blurb: String
    let flags: [FlagSpec]
    /// Description of the positional argument, or nil if the command takes none.
    let positional: String?

    func flag(_ name: String) -> FlagSpec? { flags.first { $0.name == name } }
}

enum CommandSpecs {
    static let help = FlagSpec("help", "", "print this usage and exit (also -h)")

    static let record = CommandSpec(
        name: "record",
        synopsis: "record --category <cat> --surface <desk|soft|lap> [flags]",
        blurb: "One unprompted session of one category. No beeps, no labels.",
        flags: [
            FlagSpec("category", "<cat>", "required. `tunk-capture list` prints the 12 categories"),
            FlagSpec("surface", "<desk|soft|lap>", "required. where the machine is sitting"),
            FlagSpec("out", "<dir>", "session root (default data/raw)"),
            FlagSpec("split", "<train|test>", "must agree with the out directory"),
            FlagSpec("duration", "<s>", "stop after this many seconds (default: until Ctrl-C)"),
            FlagSpec("notes", "<text>", "free text into notes.md and meta.json"),
            FlagSpec("expect", "<n>", "expected_triggers for a tap category"),
            FlagSpec("report-interval-us", "<us>", "sensor ReportInterval; 1250 => 796 Hz"),
            FlagSpec("allow-no-input", "", "record even if the event tap cannot start (marks the session degraded)"),
            FlagSpec("no-touch", "", "skip trackpad touch-count capture"),
            FlagSpec("dry-run", "", "print what would be recorded and exit"),
            help,
        ],
        positional: nil)

    static let guide = CommandSpec(
        name: "guide",
        synopsis: "guide --surface <desk|soft|lap> [--only <cat,...>] [flags]",
        blurb: "The scripted, spoken session the dataset is built from. One session file per phase.",
        flags: [
            FlagSpec("surface", "<desk|soft|lap>", "required. where the machine is sitting"),
            FlagSpec("only", "<cat,...>", "run only these phases, comma separated"),
            FlagSpec("skip", "<cat,...>", "drop these phases"),
            FlagSpec("out", "<dir>", "session root (default data/raw)"),
            FlagSpec("split", "<train|test>", "must agree with the out directory"),
            FlagSpec("taps", "<n>", "prompted double-taps per tap phase (default 20)"),
            FlagSpec("duration", "<s>", "seconds for EVERY timed phase selected; replaces the three flags below"),
            FlagSpec("typing-sec", "<s>", "seconds of the typing phase (default 180)"),
            FlagSpec("trackpad-sec", "<s>", "seconds of the trackpad phase (default 90)"),
            FlagSpec("confound-sec", "<s>", "seconds of each confound and idle phase (default 60)"),
            FlagSpec("rest-sec", "<s>", "seconds to reposition between phases (default 12)"),
            FlagSpec("min-rest", "<s>", "shortest gap between tap prompts (default 2.5)"),
            FlagSpec("max-rest", "<s>", "longest gap between tap prompts (default 4.5)"),
            FlagSpec("notes", "<text>", "free text into every session written by this run"),
            FlagSpec("volume", "<0-1>", "beep volume (default 0.35)"),
            FlagSpec("report-interval-us", "<us>", "sensor ReportInterval; 1250 => 796 Hz"),
            FlagSpec("no-audio", "", "no beeps"),
            FlagSpec("no-speech", "", "no spoken prompts"),
            FlagSpec("no-touch", "", "skip trackpad touch-count capture"),
            FlagSpec("allow-no-input", "", "record even if the event tap cannot start"),
            FlagSpec("dry-run", "", "print the phase plan and exit without recording"),
            help,
        ],
        positional: nil)

    static let verify = CommandSpec(
        name: "verify",
        synopsis: "verify [<session-dir>]",
        blurb: "Re-read a session the way the harness will and say whether the rig is sound.",
        flags: [
            FlagSpec("out", "<dir>", "where to look for the newest session (default data/raw)"),
            help,
        ],
        positional: "<session-dir>   defaults to the newest session under --out")

    static let doctor = CommandSpec(
        name: "doctor",
        synopsis: "doctor [--seconds <s>]",
        blurb: "Permission and sensor check. Run it before an hour of recording, not after.",
        flags: [
            FlagSpec("seconds", "<s>", "listening window (default 6)"),
            FlagSpec("report-interval-us", "<us>", "sensor ReportInterval; 1250 => 796 Hz"),
            FlagSpec("no-audio", "", "no beeps"),
            FlagSpec("no-speech", "", "no spoken prompts"),
            FlagSpec("no-touch", "", "skip trackpad touch-count capture"),
            help,
        ],
        positional: nil)

    static let list = CommandSpec(
        name: "list",
        synopsis: "list",
        blurb: "Print the category and surface vocabulary.",
        flags: [help],
        positional: nil)

    static let all: [CommandSpec] = [record, guide, verify, doctor, list]

    static func spec(_ name: String) -> CommandSpec? { all.first { $0.name == name } }

    static var categoryList: String {
        "one of " + Category.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// Hand-written redirects for mistakes that already cost real time.
    static func hint(command: String, flag: String) -> String? {
        switch (command, flag) {
        case ("guide", "category"):
            return "`guide` picks its own category per phase. Use --only <cat,...> to choose which phases run."
        case ("record", "only"), ("record", "skip"), ("record", "taps"):
            return "`record` runs exactly one category with no prompts. Use --category, or use `guide` for prompted phases."
        case ("doctor", "duration"), ("verify", "duration"):
            return "the \(command) window is set with --seconds."
        default:
            return nil
        }
    }
}

// MARK: - Errors

enum ArgError: Error, CustomStringConvertible {
    case unknownFlag(command: String, flag: String)
    case missingValue(command: String, flag: FlagSpec)
    case unexpectedValue(command: String, flag: String)
    case unexpectedPositional(command: String, value: String)

    var description: String {
        switch self {
        case .unknownFlag(let command, let flag):
            var s = "unknown flag --\(flag) for `\(command)`."
            if let h = CommandSpecs.hint(command: command, flag: flag) {
                s += "\n\n  \(h)"
            } else if let near = ArgError.nearest(flag, in: command) {
                s += "\n\n  Did you mean --\(near)?"
            }
            if let other = ArgError.commandsAccepting(flag).first(where: { $0 != command }) {
                s += "\n  (--\(flag) is a `\(other)` flag.)"
            }
            return s + "\n\n" + CommandSpecs.helpText(for: command)
        case .missingValue(let command, let flag):
            return "flag --\(flag.name) needs a value, e.g. --\(flag.name) \(flag.arg)."
                + "\n\n" + CommandSpecs.helpText(for: command)
        case .unexpectedValue(let command, let flag):
            return "flag --\(flag) takes no value."
                + "\n\n" + CommandSpecs.helpText(for: command)
        case .unexpectedPositional(let command, let value):
            return "`\(command)` takes no positional argument, but got '\(value)'."
                + "\n  Every value must be attached to a flag, e.g. --surface desk."
                + "\n\n" + CommandSpecs.helpText(for: command)
        }
    }

    static func commandsAccepting(_ flag: String) -> [String] {
        CommandSpecs.all.filter { $0.flag(flag) != nil }.map(\.name)
    }

    /// Closest accepted flag by edit distance, if it is close enough to be a typo.
    static func nearest(_ flag: String, in command: String) -> String? {
        guard let spec = CommandSpecs.spec(command) else { return nil }
        let scored = spec.flags.map { ($0.name, editDistance(flag, $0.name)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        return best.1 <= max(2, flag.count / 3) ? best.0 : nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = prev
        for i in 1...max(1, x.count) where !x.isEmpty {
            cur[0] = i
            for j in 1...max(1, y.count) where !y.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}

// MARK: - Help text

extension CommandSpecs {
    static func helpText(for command: String) -> String {
        guard let spec = spec(command) else { return overview }
        var lines = ["\(spec.name) accepts:"]
        if let p = spec.positional { lines.append("  \(p)") }
        func left(_ f: FlagSpec) -> String { "--\(f.name)" + (f.arg.isEmpty ? "" : " \(f.arg)") }
        let width = (spec.flags.map { left($0).count }.max() ?? 20) + 2
        for f in spec.flags {
            lines.append("  " + left(f).padding(toLength: width, withPad: " ", startingAt: 0) + f.help)
        }
        lines.append("")
        lines.append("  usage: tunk-capture \(spec.synopsis)")
        return lines.joined(separator: "\n")
    }

    static var overview: String {
        var lines = ["\(toolVersion) — record one labelled session per FORMAT.md.", "", "USAGE"]
        for spec in all {
            lines.append("  tunk-capture \(spec.synopsis)")
            lines.append("      \(spec.blurb)")
        }
        lines.append("")
        lines.append("  tunk-capture <command> --help     the flags that command accepts")
        lines.append("")
        lines.append("""
        NOTES
          Unknown flags are rejected. Nothing is silently ignored, because a
          swallowed flag means an hour of recording the wrong thing.
          Ctrl-C at any point flushes the stream and writes a valid meta.json.
          The event tap needs Input Monitoring (and Accessibility on some releases)
          granted to the TERMINAL app you launch this from, not to the binary.
        """)
        return lines.joined(separator: "\n")
    }
}
