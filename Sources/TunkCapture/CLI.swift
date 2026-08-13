import Foundation
import TunkFormat

let toolVersion = "tunk-capture 0.3.0"

/// `Category` also exists in the ObjC runtime headers that AppKit drags in, which
/// makes the bare name ambiguous inside this target. Pin it to ours once.
typealias Category = TunkFormat.Category

/// Minimal flag parser. `--key value`, `--key=value`, and bare boolean flags from
/// a known set. Anything else is positional.
struct Args {
    private(set) var sub: String = ""
    private(set) var flags: [String: String] = [:]
    private(set) var positional: [String] = []

    static let booleanFlags: Set<String> = [
        "help", "h", "allow-no-input", "no-audio", "no-speech", "no-touch",
        "quiet", "json", "no-marks", "list",
    ]

    init(_ argv: [String]) {
        var rest = argv
        if let first = rest.first, !first.hasPrefix("-") {
            sub = first
            rest.removeFirst()
        }
        var i = 0
        while i < rest.count {
            let tok = rest[i]
            if tok.hasPrefix("--") || (tok.hasPrefix("-") && tok.count == 2) {
                let body = String(tok.drop(while: { $0 == "-" }))
                if let eq = body.firstIndex(of: "=") {
                    flags[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if Args.booleanFlags.contains(body) {
                    flags[body] = "true"
                } else if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    flags[body] = rest[i + 1]
                    i += 1
                } else {
                    flags[body] = "true"
                }
            } else {
                positional.append(tok)
            }
            i += 1
        }
    }

    func str(_ k: String) -> String? { flags[k] }
    func has(_ k: String) -> Bool { flags[k] != nil }
    func int(_ k: String) -> Int? { flags[k].flatMap { Int($0) } }
    func dbl(_ k: String) -> Double? { flags[k].flatMap { Double($0) } }
    func list(_ k: String) -> [String] {
        (flags[k] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case badArgument(String)
    var description: String {
        switch self {
        case .badArgument(let m): return m
        }
    }
}

func parseCategory(_ s: String?) throws -> Category {
    guard let s else { throw CLIError.badArgument("--category is required") }
    guard let c = Category(rawValue: s) else {
        throw CLIError.badArgument(
            "unknown category '\(s)'. One of: " + Category.allCases.map(\.rawValue).joined(separator: ", "))
    }
    return c
}

func parseSurface(_ s: String?) throws -> Surface {
    guard let s else { throw CLIError.badArgument("--surface is required (desk | soft | lap)") }
    guard let v = Surface(rawValue: s) else {
        throw CLIError.badArgument("unknown surface '\(s)'. One of: desk, soft, lap")
    }
    return v
}

/// `data/raw` implies train, `data/holdout` implies test. An explicit `--split`
/// must agree, because FORMAT.md makes the mismatch an error at read time.
func resolveSplit(outPath: String, explicit: String?) throws -> (URL, Split) {
    let url = URL(fileURLWithPath: outPath, isDirectory: true).standardizedFileURL
    let leaf = url.lastPathComponent
    let implied: Split? = leaf == "raw" ? .train : (leaf == "holdout" ? .test : nil)
    var split = implied ?? .train
    if let explicit {
        guard let s = Split(rawValue: explicit) else {
            throw CLIError.badArgument("--split must be train or test")
        }
        if let implied, implied != s {
            throw CLIError.badArgument(
                "--split \(s.rawValue) contradicts the output directory '\(leaf)' "
                + "(data/raw is train, data/holdout is test)")
        }
        split = s
    }
    return (url, split)
}

let usageText = """
\(toolVersion) — record one labelled session per FORMAT.md.

USAGE
  tunk-capture record --category <cat> --surface <desk|soft|lap>
                      [--split train|test] [--out data/raw]
                      [--duration <s>] [--notes "..."] [--expect <n>]
  tunk-capture guide  --surface <desk|soft|lap> [--out data/raw]
                      [--taps 20] [--typing-sec 180] [--confound-sec 60]
                      [--rest-sec 12] [--only tap_deck,typing] [--skip idle]
  tunk-capture verify [<session-dir>]          (defaults to newest under data/raw)
  tunk-capture doctor [--seconds 6]            (permission + rig check)
  tunk-capture list                            (categories and surfaces)

COMMON FLAGS
  --no-audio      no beeps          --no-speech   no spoken prompts
  --no-touch      skip trackpad touch-count capture
  --allow-no-input  record even if the event tap cannot start (session is marked degraded)
  --report-interval-us 1250         sensor ReportInterval; 1250 => 796 Hz

NOTES
  Ctrl-C at any point flushes the stream and writes a valid meta.json.
  The event tap needs Input Monitoring (and Accessibility on some releases)
  granted to the TERMINAL app you launch this from, not to the binary.
"""
