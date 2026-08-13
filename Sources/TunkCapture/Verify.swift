import Foundation
import TunkCore
import TunkFormat

/// Re-reads a session the way the harness will and reports whether the rig is
/// sound. Run this after the first take, before recording for an hour.
func runVerify(_ args: Args) -> Never {
    let target: URL
    if let p = args.positional.first {
        target = URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
    } else if let newest = newestSession(under: args.str("out") ?? "data/raw") {
        target = newest
        Console.line("(no path given, using the newest session under \(args.str("out") ?? "data/raw"))")
    } else {
        Console.err("nothing to verify: no session directory given and none found under data/raw")
        exit(2)
    }
    exit(verify(directory: target) ? 0 : 1)
}

private func newestSession(under path: String) -> URL? {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
        return nil
    }
    return entries
        .filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .last
}

private enum Level: String {
    case ok = "OK  "
    case warn = "WARN"
    case fail = "FAIL"
}

private final class Report {
    var failed = false
    var warned = false

    func say(_ level: Level, _ label: String, _ detail: String) {
        if level == .fail { failed = true }
        if level == .warn { warned = true }
        Console.line("  \(level.rawValue)  \(label.padding(toLength: 22, withPad: " ", startingAt: 0))\(detail)")
    }
}

func verify(directory: URL) -> Bool {
    Console.banner("VERIFY  \(directory.lastPathComponent)")
    let r = Report()

    let session: Session
    do {
        session = try Session(directory: directory)
    } catch {
        Console.line("  FAIL  meta.json               \(error)")
        Console.line("")
        return false
    }
    let m = session.meta
    r.say(.ok, "meta.json", "\(m.category.rawValue) on \(m.surface.rawValue), split=\(m.split.rawValue), \(m.toolVersion)")

    // Split must agree with the directory it sits in, or a test session can leak
    // into tuning.
    let parent = directory.deletingLastPathComponent().lastPathComponent
    if parent == "raw", m.split != .train {
        r.say(.fail, "split", "declares \(m.split.rawValue) but sits under data/raw")
    } else if parent == "holdout", m.split != .test {
        r.say(.fail, "split", "declares \(m.split.rawValue) but sits under data/holdout")
    } else {
        r.say(.ok, "split", "\(m.split.rawValue) agrees with directory '\(parent)'")
    }

    // accel.bin
    let accelPath = session.accelURL.path
    let size = (try? FileManager.default.attributesOfItem(atPath: accelPath)[.size] as? Int) ?? nil
    guard let byteSize = size else {
        r.say(.fail, "accel.bin", "missing")
        Console.line("")
        return false
    }
    if byteSize % AccelSample.byteWidth != 0 {
        r.say(.fail, "accel.bin size", "\(byteSize) bytes is not a multiple of \(AccelSample.byteWidth)")
    }
    let samples: [AccelSample]
    do {
        samples = try session.samples()
    } catch {
        r.say(.fail, "accel.bin", "\(error)")
        Console.line("")
        return false
    }
    r.say(samples.isEmpty ? .fail : .ok, "accel.bin",
          "\(samples.count) records, \(byteSize) bytes (\(byteSize / AccelSample.byteWidth) x \(AccelSample.byteWidth))")
    if samples.count != m.sampleCount {
        r.say(.fail, "sample_count", "meta says \(m.sampleCount), file holds \(samples.count)")
    } else {
        r.say(.ok, "sample_count", "meta matches file")
    }

    guard samples.count > 1 else {
        r.say(.fail, "stream", "not enough samples to measure anything")
        Console.line("")
        return false
    }

    var backwards = 0
    var gaps = 0
    var maxGapNs: Int64 = 0
    var lags = [Int64]()
    lags.reserveCapacity(samples.count)
    let gapLimit = m.nominalIntervalNs * 3 / 2
    for i in samples.indices {
        lags.append(samples[i].arrivalNs - samples[i].tNs)
        guard i > 0 else { continue }
        let d = samples[i].tNs - samples[i - 1].tNs
        if d < 0 { backwards += 1 }
        if d > gapLimit {
            gaps += 1
            maxGapNs = max(maxGapNs, d)
        }
    }
    r.say(backwards == 0 ? .ok : .fail, "monotonic t_ns",
          backwards == 0 ? "no reversals" : "\(backwards) reversals")

    let spanNs = samples.last!.tNs - samples.first!.tNs
    let spanS = Double(spanNs) / 1e9
    let hz = Double(samples.count - 1) / spanS
    // What the sensor was asked for, versus what arrived. The gap between the two
    // is sample loss, and it is the number that matters for the rig.
    let requestedHz = 1e9 / Double(m.reportIntervalUs * 1_000)
    let loss = 1 - hz / requestedHz
    r.say(loss < 0.02 ? .ok : (loss < 0.10 ? .warn : .fail), "rate",
          String(format: "%.1f Hz measured over %.2f s (requested %.1f Hz => %.2f%% sample loss)",
                 hz, spanS, requestedHz, loss * 100))
    let declaredHz = 1e9 / Double(m.nominalIntervalNs)
    r.say(abs(declaredHz - m.nominalRateHz) < 1 ? .ok : .warn, "meta cadence",
          String(format: "nominal_rate_hz %.1f vs 1/nominal_interval_ns %.1f", m.nominalRateHz, declaredHz))
    r.say(gaps == 0 ? .ok : .warn, "gaps",
          gaps == 0 ? "none (> \(gapLimit / 1000) us step)"
                    : String(format: "%d gaps, worst %.2f ms", gaps, Double(maxGapNs) / 1e6))

    lags.sort()
    func pct(_ p: Double) -> Double { Double(lags[min(lags.count - 1, Int(Double(lags.count) * p))]) / 1e6 }
    let lagBad = pct(0.95) > 5.0
    r.say(lagBad ? .warn : .ok, "callback lag",
          String(format: "p50 %.2f ms  p95 %.2f ms  max %.2f ms",
                 pct(0.5), pct(0.95), Double(lags.last!) / 1e6))

    // duration self-consistency
    let durS = Double(m.durationNs) / 1e9
    let durDelta = abs(durS - spanS)
    r.say(durDelta < 1.5 ? .ok : .warn, "duration",
          String(format: "meta %.2f s vs accel span %.2f s (delta %.2f s)", durS, spanS, durDelta))

    // input.jsonl — the file the harness needs to replay the suppression gate.
    let marks = (try? session.marks()) ?? []
    let tapMark = marks.first { $0.kind == "input_tap" }
    let tapDegraded = tapMark?.text == "degraded"
    let inputs = (try? session.inputs()) ?? []
    var byKind = [String: Int]()
    var inputBackwards = 0
    var outOfRange = 0
    for (i, e) in inputs.enumerated() {
        byKind[e.kind.rawValue, default: 0] += 1
        if i > 0, e.tNs < inputs[i - 1].tNs { inputBackwards += 1 }
        if e.tNs < 0 || e.tNs > m.durationNs + 1_000_000_000 { outOfRange += 1 }
    }
    let kindDetail = byKind.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")

    if tapDegraded {
        r.say(.fail, "input.jsonl", "session recorded with the event tap DEGRADED — unusable for false-positive scoring")
    } else if inputs.isEmpty && m.category != .idle {
        r.say(.fail, "input.jsonl", "EMPTY. The gate cannot be replayed, so this session is corrupt. Run `tunk-capture doctor`.")
    } else if inputs.isEmpty {
        r.say(.warn, "input.jsonl", "empty, which is expected for an idle session (tap was active)")
    } else {
        r.say(.ok, "input.jsonl", "\(inputs.count) events  [\(kindDetail)]")
    }
    if inputBackwards > 0 { r.say(.fail, "input order", "\(inputBackwards) timestamp reversals") }
    if outOfRange > 0 { r.say(.warn, "input range", "\(outOfRange) events outside the session window") }

    // mouse_moved rate limit, per FORMAT.md. trackpad_touch is capped the same way.
    if spanS > 0 {
        for (kind, cap) in [("mouse_moved", 105.0), ("trackpad_touch", 105.0)] {
            guard let n = byKind[kind], n > 0 else { continue }
            let rate = Double(n) / spanS
            r.say(rate <= cap ? .ok : .warn, "\(kind) rate",
                  String(format: "%.1f/s (cap is 100/s)", rate))
        }
    }

    // marks.jsonl
    var markKinds = [String: Int]()
    for k in marks { markKinds[k.kind, default: 0] += 1 }
    let markDetail = markKinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    r.say(marks.isEmpty ? .warn : .ok, "marks.jsonl",
          marks.isEmpty ? "empty" : "\(marks.count) marks  [\(markDetail)]")

    let beeps = marks.filter { $0.kind == "beep" }.count
    if m.category.isTapCategory {
        r.say(beeps == m.expectedTriggers ? .ok : .fail, "beeps",
              "\(beeps) beeps vs expected_triggers \(m.expectedTriggers)")
        let groups = Set(marks.compactMap { $0.kind == "beep" ? $0.group : nil })
        r.say(groups.count == beeps ? .ok : .fail, "beep groups",
              "\(groups.count) distinct group ids")
    } else if m.expectedTriggers != 0 {
        r.say(.fail, "expected_triggers", "non-tap category must expect 0, meta says \(m.expectedTriggers)")
    } else {
        r.say(.ok, "expected_triggers", "0, any trigger here is a false positive")
    }

    // labels.jsonl exists (the labeller fills it in later)
    let labelsExist = FileManager.default.fileExists(atPath: session.labelsURL.path)
    let labels = (try? session.labels()) ?? []
    if !labelsExist {
        r.say(.fail, "labels.jsonl", "missing")
    } else if m.category.isTapCategory && labels.isEmpty {
        r.say(.warn, "labels.jsonl", "empty — run the labeller before scoring this session")
    } else {
        r.say(.ok, "labels.jsonl", "\(labels.count) labels")
    }

    Console.line("")
    if r.failed {
        Console.line("  RESULT: FAIL — do not record an hour on this rig until it is fixed.")
    } else if r.warned {
        Console.line("  RESULT: PASS WITH WARNINGS")
    } else {
        Console.line("  RESULT: PASS")
    }
    Console.line("")
    return !r.failed
}
