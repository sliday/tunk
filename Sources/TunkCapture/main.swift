import Foundation
import TunkFormat

// tunk-capture — records one labelled session per FORMAT.md.
//
// record  one category, raw, no prompts
// guide   the scripted hands-free session the dataset is actually built from
// verify  re-read a session and say whether the rig is sound
// doctor  permission and sensor check, five seconds, before you commit an hour

let argv = Array(CommandLine.arguments.dropFirst())

let args: Args
do {
    args = try Args(argv)
} catch {
    Console.err("error: \(error)")
    exit(2)
}

if args.wantsHelp || args.sub.isEmpty {
    // `tunk-capture guide --help` prints that command's flags, not the overview.
    print(CommandSpecs.spec(args.sub) != nil ? CommandSpecs.helpText(for: args.sub) : usageText)
    exit(args.sub.isEmpty && !args.wantsHelp ? 1 : 0)
}

do {
    switch args.sub {
    case "record":
        try runRecord(args)
    case "guide":
        try runGuide(args)
    case "verify":
        runVerify(args)
    case "doctor":
        runDoctor(args)
    case "list":
        print("categories:")
        for c in Category.allCases {
            print("  \(c.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0))\(c.title)")
        }
        print("surfaces:")
        for s in Surface.allCases {
            print("  \(s.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0))\(s.title)")
        }
    default:
        Console.err("unknown command '\(args.sub)'\n")
        print(usageText)
        exit(1)
    }
} catch {
    Console.err("error: \(error)")
    exit(1)
}
