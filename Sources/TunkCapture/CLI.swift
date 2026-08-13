import Foundation
import TunkFormat

let toolVersion = "tunk-capture 0.3.0"

/// `Category` also exists in the ObjC runtime headers that AppKit drags in, which
/// makes the bare name ambiguous inside this target. Pin it to ours once.
typealias Category = TunkFormat.Category

/// Flag parser driven by the per-command table in `Flags.swift`.
///
/// Accepts `--key value`, `--key=value`, and bare switches. Every flag must be
/// declared for the subcommand being run; anything else raises `ArgError` rather
/// than being ignored. Silently swallowing an argument is how an hour of
/// recording gets spent on the wrong thing.
struct Args {
    private(set) var sub: String = ""
    private(set) var flags: [String: String] = [:]
    private(set) var positional: [String] = []
    /// True when the operator asked for usage; validation is then skipped so
    /// `guide --bogus --help` still explains itself.
    private(set) var wantsHelp = false

    init(_ argv: [String], validate: Bool = true) throws {
        var rest = argv
        if let first = rest.first, !first.hasPrefix("-") {
            sub = first
            rest.removeFirst()
        }
        wantsHelp = rest.contains { $0 == "--help" || $0 == "-h" }
        // An unknown subcommand is reported by main.swift; parse it leniently so
        // the message is "unknown command", not a confusing flag error.
        let spec = CommandSpecs.spec(sub)
        let checking = validate && !wantsHelp && spec != nil

        var i = 0
        while i < rest.count {
            let tok = rest[i]
            defer { i += 1 }
            guard tok.hasPrefix("--") || (tok.hasPrefix("-") && tok.count == 2) else {
                if checking, spec?.positional == nil {
                    throw ArgError.unexpectedPositional(command: sub, value: tok)
                }
                positional.append(tok)
                continue
            }
            let body = String(tok.drop(while: { $0 == "-" }))
            let name = body.firstIndex(of: "=").map { String(body[body.startIndex..<$0]) } ?? body
            let inlineValue = body.firstIndex(of: "=").map { String(body[body.index(after: $0)...]) }
            let canonical = (name == "h") ? "help" : name

            guard let declared = spec?.flag(canonical) else {
                if checking { throw ArgError.unknownFlag(command: sub, flag: canonical) }
                flags[canonical] = inlineValue ?? "true"
                if inlineValue == nil, i + 1 < rest.count, !rest[i + 1].hasPrefix("-") {
                    flags[canonical] = rest[i + 1]
                    i += 1
                }
                continue
            }

            if let inlineValue {
                if !declared.takesValue, checking {
                    throw ArgError.unexpectedValue(command: sub, flag: canonical)
                }
                flags[canonical] = inlineValue
            } else if declared.takesValue {
                // A value that itself looks like a flag is a missing value, not a
                // value: `--taps --surface desk` must not record 0 taps.
                guard i + 1 < rest.count, !rest[i + 1].hasPrefix("--") else {
                    if checking { throw ArgError.missingValue(command: sub, flag: declared) }
                    flags[canonical] = "true"
                    continue
                }
                flags[canonical] = rest[i + 1]
                i += 1
            } else {
                flags[canonical] = "true"
            }
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

    /// A numeric flag that was given but does not parse is an error, not a silent
    /// fallback to the default.
    func number(_ k: String) throws -> Double? {
        guard let raw = flags[k] else { return nil }
        guard let v = Double(raw), v.isFinite else {
            throw CLIError.badArgument("--\(k) expects a number, got '\(raw)'")
        }
        return v
    }

    func count(_ k: String) throws -> Int? {
        guard let raw = flags[k] else { return nil }
        guard let v = Int(raw) else {
            throw CLIError.badArgument("--\(k) expects a whole number, got '\(raw)'")
        }
        return v
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

/// `--only` / `--skip` take category names. A typo there used to filter every
/// phase out (or none), so each entry is checked against the vocabulary.
func parseCategoryList(_ args: Args, _ key: String) throws -> Set<String> {
    let raw = args.list(key)
    guard !raw.isEmpty else {
        if args.has(key) {
            throw CLIError.badArgument("--\(key) is empty. \(CommandSpecs.categoryList)")
        }
        return []
    }
    let known = Set(Category.allCases.map(\.rawValue))
    let bad = raw.filter { !known.contains($0) }
    guard bad.isEmpty else {
        throw CLIError.badArgument(
            "--\(key): unknown categor\(bad.count == 1 ? "y" : "ies") "
            + bad.map { "'\($0)'" }.joined(separator: ", ")
            + ".\n  \(CommandSpecs.categoryList)")
    }
    return Set(raw)
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

var usageText: String { CommandSpecs.overview }
