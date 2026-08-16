import Foundation
import TunkCore

// tunk-score: the referee. It replays recorded sessions through the detector and
// grades them against the pass line in FORMAT.md. See CLI.swift for the usage text.

let boolFlags: Set<String> = [
    "i-am-a-critic", "verbose", "keep", "help", "version", "check-determinism",
    "progress-pooled", "progress-replace", "pooled", "replace",
]

func main() -> Int32 {
    // One stderr line per retrospective-pairing rescue, so the crest-to-anchor
    // ratio behind `pairRescueAnchorFraction` can be read off a real run instead
    // of argued about. Off unless asked for, and it never touches the report.
    if ProcessInfo.processInfo.environment["TUNK_RESCUE_TRACE"] != nil {
        PairRescueTrace.sink = { record in
            FileHandle.standardError.write(Data((record.line + "\n").utf8))
        }
    }
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first, !command.hasPrefix("--") else {
        if argv.contains("--version") { print("tunk-score \(TunkScoreVersion.string)"); return 0 }
        print(usageText)
        return argv.isEmpty || argv.contains("--help") ? 0 : 64
    }
    argv = Array(argv)

    do {
        var args = try Args(argv, boolFlags: boolFlags)
        if args.bool("help") { print(usageText); return 0 }
        if args.bool("version") { print("tunk-score \(TunkScoreVersion.string)"); return 0 }
        switch command {
        case "run": return try Commands.run(&args)
        case "sweep": return try Commands.sweep(&args)
        case "explain": return try Commands.explain(&args)
        case "progress": return try Commands.progress(&args)
        case "selftest": return try SelfTest.run(&args)
        default:
            throw CLIError.usage("unknown command '\(command)'\n\n\(usageText)")
        }
    } catch let e as CLIError {
        FileHandle.standardError.write(Data(("\n" + e.description + "\n").utf8))
        return e.exitCode
    } catch {
        FileHandle.standardError.write(Data(("\ntunk-score: \(error)\n").utf8))
        return 1
    }
}

exit(main())
