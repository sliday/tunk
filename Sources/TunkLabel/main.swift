import TunkLabelCore
import Foundation
import TunkCore
import TunkFormat

// tunk-label — turns prompt beeps into ground-truth onsets, and tells the
// operator whether their taps actually landed.
//
// `check` exists because of a specific failure: a critic recorded six prompted
// tap groups without touching the machine, and `tunk-capture verify` reported
// PASS. Guided capture is hands-free and eyes-free by design, so the operator
// has no way to notice. Measuring the beep windows is the only honest answer.

let toolVersion = "tunk-label 0.1.0"

// MARK: - Arguments

var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { usage(); exit(2) }
argv.removeFirst()

func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--\(name)"), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func has(_ name: String) -> Bool { argv.contains("--\(name)") }

func usage() {
    print("""
    \(toolVersion) — ground truth for recorded sessions.

    USAGE
      tunk-label check <session-dir|root>   did the taps actually land?
      tunk-label run   <session-dir|root>   write labels.jsonl per FORMAT.md
      tunk-label show  <session-dir>        per-group detail, for eyeballing

    FLAGS
      --window-ms 2600   how long after a beep to look for the gesture
                         (covers ~1 s of human reaction time plus the tap pair)
      --snr 6            peak must clear this multiple of the noise floor
      --min-gap-ms 80    minimum spacing between the taps of one gesture
      --max-gap-ms 600   maximum spacing between the taps of one gesture.
                         Deliberately wider than the detector's join window:
                         a gesture it cannot group is a MISS, not a non-event.
      --write            for `run` on a root: actually write, not a dry run
      --quiet            summary lines only

    `check` exits non-zero when a tap session has groups where nothing landed,
    so it can gate a recording run before an hour is spent.
    """)
}

// MARK: - Group analysis

struct GroupResult {
    var group: Int
    var beepNs: Int64
    var peaks: [Peak]
    /// The two peaks that look like a deliberate double-tap, if any.
    var pair: (Peak, Peak)?
    var landed: Bool { pair != nil }
    /// Strongest thing in the window, landed or not. Tells "too soft" apart
    /// from "nothing at all".
    var strongest: Peak? { peaks.first }
}

struct SessionAnalysis {
    var session: Session
    var groups: [GroupResult]
    var noiseFloor: Double
    var sampleCount: Int

    var landedCount: Int { groups.filter(\.landed).count }
    var isTapSession: Bool { session.meta.category.isTapCategory }
}

func analyse(_ session: Session,
             windowNs: Int64,
             minGapNs: Int64,
             maxGapNs: Int64,
             snr: Double) throws -> SessionAnalysis {
    let samples = try session.samples()
    let marks = try session.marks()

    var picker = OnsetPicker()
    picker.snrThreshold = snr
    picker.minSeparationNs = min(minGapNs, 40_000_000)

    let env = picker.envelope(samples)
    let floor = picker.noiseFloor(env)

    var results: [GroupResult] = []
    for mark in marks where mark.kind == "beep" {
        guard let g = mark.group else { continue }
        let found = picker.peaks(in: samples, env: env, floor: floor,
                                 from: mark.tNs, to: mark.tNs + windowNs)

        // A deliberate double-tap is the two strongest peaks in the window that
        // sit a plausible interval apart. Search by amplitude so a stray scuff
        // between the taps does not win.
        var pair: (Peak, Peak)?
        outer: for (i, a) in found.enumerated() {
            for b in found[(i + 1)...] {
                let (first, second) = a.tNs <= b.tNs ? (a, b) : (b, a)
                let gap = second.tNs - first.tNs
                if gap >= minGapNs && gap <= maxGapNs {
                    pair = (first, second)
                    break outer
                }
            }
        }
        results.append(GroupResult(group: g, beepNs: mark.tNs, peaks: found, pair: pair))
    }

    return SessionAnalysis(session: session, groups: results.sorted { $0.group < $1.group },
                           noiseFloor: floor, sampleCount: samples.count)
}

// MARK: - Session discovery

func sessions(at path: String) throws -> [Session] {
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("meta.json").path) {
        return [try Session(directory: url)]
    }
    return try Session.discover(root: url)
}

// MARK: - Commands

// 2600 ms, not 1200. Measured against the operator's first real session: taps
// land 994-1083 ms after the beep, because a human hears it, decides, and moves.
// At 1200 ms the FIRST tap of a pair fit and the second fell outside, so a clean
// double read as "one transient only" and a whole group read as silence. The
// window has to cover reaction time plus the gesture, not just the gesture.
let windowNs = Int64((Double(flag("window-ms") ?? "2600") ?? 2600) * 1e6)
let minGapNs = Int64((Double(flag("min-gap-ms") ?? "80") ?? 80) * 1e6)
// 600 ms, wider than the detector's 220 ms join window ON PURPOSE.
//
// Ground truth records what the OPERATOR did, not what the detector can
// handle. At 400 ms a prompted double-tap of two clean 0.1025 g strikes
// 426 ms apart was labelled as a single onset, scored as a 1-tap gesture,
// and left the detection denominator entirely — turning 22/23 into 22/22
// and a 95.65 % detection rate into 100 %. The gesture happened; the
// detector cannot group it; both of those facts belong in the report.
let maxGapNs = Int64((Double(flag("max-gap-ms") ?? "600") ?? 600) * 1e6)
let snr = Double(flag("snr") ?? "6") ?? 6
let quiet = has("quiet")

guard let target = argv.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write("error: no session directory given\n".data(using: .utf8)!)
    usage()
    exit(2)
}

func bar(_ v: Double, max m: Double, width: Int = 18) -> String {
    guard m > 0 else { return String(repeating: " ", count: width) }
    let n = min(width, Int((v / m) * Double(width).rounded()))
    return String(repeating: "\u{2588}", count: max(0, n))
        + String(repeating: "\u{00B7}", count: max(0, width - max(0, n)))
}

switch command {

case "check":
    let list = try sessions(at: target)
    guard !list.isEmpty else { print("no sessions under \(target)"); exit(2) }
    var anyBad = false

    for s in list {
        let a = try analyse(s, windowNs: windowNs, minGapNs: minGapNs, maxGapNs: maxGapNs, snr: snr)
        guard a.isTapSession else {
            if !quiet {
                print("\u{2014} \(s.meta.sessionId)  [\(s.meta.category.rawValue)] no taps expected, skipped")
            }
            continue
        }
        let total = a.groups.count
        let ok = a.landedCount
        let verdict = total == 0 ? "NO BEEPS" : (ok == total ? "OK" : (ok == 0 ? "NOTHING LANDED" : "PARTIAL"))
        if total == 0 || ok < total { anyBad = true }

        print("")
        print("  \(s.meta.sessionId)")
        print("  \(s.meta.category.rawValue) on \(s.meta.surface.rawValue)   "
              + "noise floor \(String(format: "%.4f", a.noiseFloor)) g")
        print("  \(ok)/\(total) groups landed   \u{2014}  \(verdict)")

        if !quiet, total > 0 {
            let peak = a.groups.compactMap { $0.strongest?.amplitude }.max() ?? 1
            for g in a.groups {
                let s0 = g.strongest
                let amp = s0?.amplitude ?? 0
                let mark = g.landed ? "\u{2713}" : "\u{2717}"
                let detail: String
                if let p = g.pair {
                    detail = "gap \(Int((p.1.tNs - p.0.tNs) / 1_000_000)) ms, snr \(Int(p.0.snr))/\(Int(p.1.snr))"
                } else if let s0, s0.snr >= snr {
                    detail = "one transient only, snr \(Int(s0.snr)) \u{2014} second tap missing or too close"
                } else {
                    detail = "nothing above the noise floor"
                }
                print(String(format: "    %@ g%-3d %@ %6.4f g  %@", mark, g.group, bar(amp, max: peak), amp, detail))
            }
        }
    }

    print("")
    if anyBad {
        print("  Some prompted taps did not register. Before recording a full block:")
        print("    - tap harder, or closer to the sensor (it sits under the left palm rest)")
        print("    - check the surface is not absorbing the tap")
        print("    - re-run: tunk-capture guide --surface <s> --only tap_deck --taps 3")
        exit(1)
    }
    print("  All prompted taps registered.")

case "run":
    let list = try sessions(at: target)
    let write = has("write") || list.count == 1
    var wrote = 0

    for s in list where s.meta.category.isTapCategory {
        let a = try analyse(s, windowNs: windowNs, minGapNs: minGapNs, maxGapNs: maxGapNs, snr: snr)
        var labels: [TapLabel] = []
        var refined = 0, coarse = 0

        for g in a.groups {
            if let p = g.pair {
                labels.append(TapLabel(tNs: p.0.tNs, group: g.group, indexInGroup: 0,
                                       intent: .double, confidence: .autoRefined))
                labels.append(TapLabel(tNs: p.1.tNs, group: g.group, indexInGroup: 1,
                                       intent: .double, confidence: .autoRefined))
                refined += 1
            } else {
                // FORMAT.md: a group we cannot resolve still counts toward the
                // detection denominator, but is excluded from latency stats.
                // Anchoring on the beep is honest about that.
                labels.append(TapLabel(tNs: g.beepNs, group: g.group, indexInGroup: 0,
                                       intent: .double, confidence: .promptWindow))
                coarse += 1
            }
        }

        if write {
            try JSONL.write(labels, to: s.labelsURL)
            wrote += 1
        }
        print("  \(s.meta.sessionId): \(refined) refined, \(coarse) prompt-window"
              + (write ? "" : "  (dry run, pass --write)"))
        if coarse > 0 {
            print("    \(coarse) group(s) need review \u{2014} tunk-label show \(s.directory.lastPathComponent)")
        }
    }
    print("")
    print(write ? "  wrote labels.jsonl for \(wrote) session(s)"
                : "  dry run only; pass --write to commit")

case "show":
    let list = try sessions(at: target)
    for s in list {
        let a = try analyse(s, windowNs: windowNs, minGapNs: minGapNs, maxGapNs: maxGapNs, snr: snr)
        print("\(s.meta.sessionId)  floor=\(String(format: "%.5f", a.noiseFloor)) g  samples=\(a.sampleCount)")
        for g in a.groups {
            print("  group \(g.group)  beep@\(g.beepNs / 1_000_000) ms")
            for (i, p) in g.peaks.prefix(6).enumerated() {
                let rel = (p.tNs - g.beepNs) / 1_000_000
                print(String(format: "    peak %d  +%4d ms  amp %.5f g  snr %.1f", i, rel, p.amplitude, p.snr))
            }
            if let p = g.pair {
                print("    -> pair at +\((p.0.tNs - g.beepNs) / 1_000_000) ms and "
                      + "+\((p.1.tNs - g.beepNs) / 1_000_000) ms, gap \((p.1.tNs - p.0.tNs) / 1_000_000) ms")
            } else {
                print("    -> no plausible pair")
            }
        }
    }

default:
    usage()
    exit(2)
}
