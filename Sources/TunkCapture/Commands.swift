import Foundation
import TunkCore
import TunkFormat
import TunkIMU

// MARK: - record

func runRecord(_ args: Args) throws -> Never {
    let category = try parseCategory(args.str("category"))
    let surface = try parseSurface(args.str("surface"))
    let (root, split) = try resolveSplit(outPath: args.str("out") ?? "data/raw",
                                         explicit: args.str("split"))
    let duration = try args.number("duration")
    if let duration, duration <= 0 {
        throw CLIError.badArgument("--duration must be greater than 0, got \(duration)")
    }

    var opts = SessionRecorder.Options(root: root, category: category, surface: surface, split: split)
    opts.notes = args.str("notes") ?? ""
    opts.expectedTriggers = try args.count("expect") ?? 0
    opts.reportIntervalUs = Int64(try args.count("report-interval-us") ?? 1250)
    opts.requireInput = !args.has("allow-no-input")
    opts.captureTouches = !args.has("no-touch")

    if category.isTapCategory, opts.expectedTriggers == 0 {
        Console.line("note: tap category with --expect 0. `guide` is the prompted, labellable mode.")
    }

    if args.has("dry-run") {
        Console.banner("DRY RUN  \(category.rawValue)  on \(surface.rawValue)")
        Console.line("  into      \(root.path) (split=\(split.rawValue))")
        Console.line("  length    " + (duration.map { String(format: "%.0f s", $0) } ?? "until Ctrl-C"))
        Console.line("  expect    \(opts.expectedTriggers) triggers")
        Console.line("  sensor    ReportInterval \(opts.reportIntervalUs) us")
        Console.line("  --dry-run: nothing was recorded.")
        Console.line("")
        exit(0)
    }

    return Runtime.run {
        let recorder: SessionRecorder
        do {
            recorder = try SessionRecorder(opts: opts)
            Runtime.adopt(recorder)
            try recorder.start()
        } catch let e as InputTap.StartError {
            Console.err("\n\(e.description)\n")
            Console.err(InputPermission.failureAdvice())
            Runtime.exitNow(2)
        } catch {
            Console.err("could not start recording: \(error)")
            Runtime.exitNow(1)
        }

        Console.banner("RECORDING  \(category.rawValue)  on \(surface.rawValue)")
        Console.line("  \(category.title)")
        Console.line("  session: \(recorder.sessionId)")
        Console.line(duration == nil ? "  Ctrl-C to stop." : "  Ctrl-C to stop early.")
        if !recorder.inputTapActive {
            Console.line("  WARNING: input tap degraded — input.jsonl will be empty.")
        }
        Console.line("")

        startStdinMarkReader()

        if let duration {
            _ = Runtime.countdown(duration, label: "recording", recorder: recorder)
        } else {
            while Runtime.sleep(1.0) {
                let c = recorder.liveCounts
                Console.status(String(format: "  recording  %6.1fs   %d samples  %d input events",
                                      Double(recorder.nowNs) / 1e9, c.samples, c.inputs))
            }
            Console.endStatus()
        }

        let s = recorder.finish(reason: duration == nil ? "operator" : "duration")
        Runtime.adopt(nil)
        Console.banner("DONE")
        Runtime.printSummary(s)
        Console.line("  verify with: tunk-capture verify \(s.dir.path)")
    }
}

/// Anything typed on stdin during a manual recording becomes an operator mark.
/// Those keystrokes also land in input.jsonl, which is correct: they really happened.
private func startStdinMarkReader() {
    let t = Thread {
        while let line = readLine(strippingNewline: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let r = Runtime.current else { continue }
            r.mark(kind: "operator_mark", text: text)
            Console.line("  marked: \(text)")
        }
    }
    t.stackSize = 1 << 18
    t.start()
}

// MARK: - doctor

/// Opens the sensor and the event tap for a few seconds and reports what arrived.
/// Run this before an hour of recording, not after.
func runDoctor(_ args: Args) throws -> Never {
    let seconds = try args.number("seconds") ?? 6.0
    guard seconds > 0 else { throw CLIError.badArgument("--seconds must be greater than 0") }
    let reportIntervalUs = Int64(try args.count("report-interval-us") ?? 1250)
    let cue = Cue(beepEnabled: !args.has("no-audio"), speechEnabled: !args.has("no-speech"))
    return Runtime.run {
        let ok = doctorCheck(seconds: seconds, cue: cue, captureTouches: !args.has("no-touch"),
                             reportIntervalUs: reportIntervalUs)
        Runtime.exitNow(ok ? 0 : 2)
    }
}

@discardableResult
func doctorCheck(seconds: Double, cue: Cue, captureTouches: Bool,
                 reportIntervalUs: Int64 = 1250) -> Bool {
    Console.banner("RIG CHECK")
    let epoch = MachClock.nowNanos()
    var byKind = [String: Int]()
    let lock = NSLock()
    let tap = InputTap(clock: { MachClock.nowNanos() - epoch }, captureTouches: captureTouches) { rec in
        lock.lock(); byKind[rec.kind.rawValue, default: 0] += 1; lock.unlock()
    }
    var tapOK = true
    do {
        try tap.start()
    } catch {
        tapOK = false
        Console.err("\ninput tap: FAILED\n")
        Console.err(InputPermission.failureAdvice())
    }

    // Speak the instruction before opening the sensor. Speech blocks for seconds,
    // and anything sampled during it lands outside the window we are timing.
    if tapOK {
        Console.line("  Type a few keys and tap the trackpad now.")
        cue.say("Rig check. Type a few keys and tap the trackpad.")
    }

    let source = AccelSource(reportIntervalUs: reportIntervalUs)
    var samples = 0
    var firstNs: Int64 = 0
    var lastNs: Int64 = 0
    let sLock = NSLock()
    var accelOK = true
    do {
        try source.start(epochMachNs: epoch) { s in
            sLock.lock()
            if samples == 0 { firstNs = s.tNs }
            lastNs = s.tNs
            samples += 1
            sLock.unlock()
        }
    } catch {
        accelOK = false
        Console.err("accelerometer: FAILED — \(error)")
    }

    _ = Runtime.countdown(seconds, label: "listening", recorder: nil)

    tap.stop()
    source.stop()

    sLock.lock()
    let n = samples
    let spanS = Double(lastNs - firstNs) / 1e9
    sLock.unlock()
    // Rate over the span the samples actually cover, not over the requested
    // window. Dividing by --seconds double-counted anything the sensor delivered
    // while the prompt was still being spoken and reported roughly twice the
    // true rate, which is worse than reporting nothing.
    let hz = (n > 1 && spanS > 0) ? Double(n - 1) / spanS : 0
    let requestedHz = 1e9 / Double(reportIntervalUs * 1_000)
    let loss = requestedHz > 0 ? 1 - hz / requestedHz : 1
    // Sample loss is a warning, not a failure: it is worth seeing before an hour
    // of recording, but it must not refuse to record an otherwise sound rig.
    if n <= 1 { accelOK = false }
    let word = !accelOK ? "FAIL" : (loss > 0.02 ? "WARN" : "OK  ")
    Console.line("")
    Console.line(String(format: "  accelerometer  %@  %d samples over %.2f s, %.1f Hz (asked for %.1f Hz)",
                        word, n, spanS, hz, requestedHz))
    if accelOK, loss > 0.02 {
        Console.line(String(format: "                 %.1f%% of samples missing. Close anything heavy and",
                            loss * 100))
        Console.line("                 re-run; a lossy stream weakens every latency number.")
    } else if n <= 1 {
        Console.line("                 the sensor delivered nothing — ReportInterval was not accepted.")
    }
    lock.lock()
    let total = byKind.values.reduce(0, +)
    let detail = byKind.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    lock.unlock()
    if !tapOK {
        Console.line("  input tap      FAIL  not permitted")
    } else if total == 0 {
        Console.line("  input tap      WARN  started but saw 0 events")
        Console.line("                 If you did press keys, the grant is stale: quit and reopen")
        Console.line("                 \(InputPermission.hostDescription), then run doctor again.")
    } else {
        Console.line("  input tap      OK    \(total) events  [\(detail)]")
    }
    let touchSeen = byKind["trackpad_touch"] ?? 0
    if captureTouches {
        Console.line("  touch count    \(touchSeen > 0 ? "OK    seen" : "n/a   no trackpad contact during the check")")
    }
    Console.line("")
    return accelOK && tapOK && total > 0
}

// MARK: - guide

struct Phase {
    var category: Category
    /// Prompted double-taps. Zero means a timed phase.
    var taps: Int = 0
    var seconds: Double = 60
    /// Spoken before the recorder opens, while the operator repositions.
    var setup: String
    /// Spoken once recording has started.
    var during: String
}

func guidePhases(taps: Int, typingSec: Double, trackpadSec: Double, confoundSec: Double,
                 surface: Surface) -> [Phase] {
    let place = "with the machine \(surface.title)"
    return [
        Phase(category: .tapPalmrest, taps: taps,
              setup: "Deliberate double taps on the palm rest, \(place).",
              during: "After each beep, double tap the palm rest once. Two firm taps, close together, one finger, then hands off."),
        Phase(category: .tapDeck, taps: taps,
              setup: "Deliberate double taps on the keyboard deck.",
              during: "After each beep, double tap the deck beside the keyboard. Two firm taps, then hands off."),
        Phase(category: .tapBottom, taps: taps,
              setup: "Deliberate double taps on the bottom case.",
              during: "After each beep, double tap the bottom case. Two firm taps, then hands off."),
        Phase(category: .typing, seconds: typingSec,
              setup: "Continuous typing. No taps at all in this phase.",
              during: "Type real prose at your normal pace until I say stop. Do not tap the machine."),
        Phase(category: .trackpad, seconds: trackpadSec,
              setup: "Trackpad clicks and hard trackpad taps.",
              during: "Click and tap the trackpad, hard and soft, moving around. No taps on the chassis."),
        Phase(category: .confoundMug, seconds: confoundSec,
              setup: "Confound: setting a mug down.",
              during: "Put a mug down on the desk near the machine, again and again, sometimes hard."),
        Phase(category: .confoundLid, seconds: confoundSec,
              setup: "Confound: hard key presses and lid nudges.",
              during: "Hit return and the space bar hard, close browser tabs hard, and nudge the lid."),
        Phase(category: .confoundPhone, seconds: confoundSec,
              setup: "Confound: a phone buzzing on the same desk.",
              during: "Let the phone vibrate on the desk beside the machine."),
        Phase(category: .confoundMusic, seconds: confoundSec,
              setup: "Confound: bass heavy music through the desk.",
              during: "Play bass heavy music loud enough to feel through the desk."),
        Phase(category: .confoundFootfall, seconds: confoundSec,
              setup: "Confound: footfall on a timber floor.",
              during: "Walk past the desk, and let someone else walk past too."),
        Phase(category: .confoundHandling, seconds: confoundSec,
              setup: "Confound: repositioning, lifting, and cables.",
              during: "Lift the machine, put it down, slide it about, and plug and unplug a cable."),
        Phase(category: .idle, seconds: confoundSec,
              setup: "Idle. Hands off completely.",
              during: "Do not touch the machine or the desk until I say stop."),
    ]
}

func runGuide(_ args: Args) throws -> Never {
    let surface = try parseSurface(args.str("surface"))
    let (root, split) = try resolveSplit(outPath: args.str("out") ?? "data/raw",
                                         explicit: args.str("split"))
    let taps = try args.count("taps") ?? 20
    let restSec = try args.number("rest-sec") ?? 12
    let minRest = try args.number("min-rest") ?? 2.5
    let maxRest = try args.number("max-rest") ?? 4.5
    guard minRest > 0, maxRest >= minRest else {
        throw CLIError.badArgument("--min-rest must be > 0 and --max-rest must be >= --min-rest")
    }
    guard taps >= 0 else { throw CLIError.badArgument("--taps must be 0 or more") }
    let reportIntervalUs = Int64(try args.count("report-interval-us") ?? 1250)
    let captureTouches = !args.has("no-touch")
    let allowNoInput = args.has("allow-no-input")

    // --duration is a uniform override for every timed phase in this run. It is
    // refused alongside the per-phase flags rather than silently losing to one of
    // them, because "which one won" is not something the operator can see.
    let uniform = try args.number("duration")
    let perPhase = ["typing-sec", "trackpad-sec", "confound-sec"].filter { args.has($0) }
    if uniform != nil, !perPhase.isEmpty {
        throw CLIError.badArgument(
            "--duration sets every timed phase at once, so it conflicts with "
            + perPhase.map { "--\($0)" }.joined(separator: " and ")
            + ".\n  Pass --duration on its own, or pass only the per-phase flags.")
    }
    if let uniform, uniform <= 0 {
        throw CLIError.badArgument("--duration must be greater than 0, got \(uniform)")
    }

    let typingSec = try uniform ?? args.number("typing-sec") ?? 180
    let trackpadSec = try uniform ?? args.number("trackpad-sec") ?? 90
    let confoundSec = try uniform ?? args.number("confound-sec") ?? 60
    var phases = guidePhases(taps: taps, typingSec: typingSec, trackpadSec: trackpadSec,
                             confoundSec: confoundSec, surface: surface)
    let only = try parseCategoryList(args, "only")
    let skip = try parseCategoryList(args, "skip")
    if let clash = only.intersection(skip).sorted().first {
        throw CLIError.badArgument("'\(clash)' is in both --only and --skip")
    }
    if !only.isEmpty { phases = phases.filter { only.contains($0.category.rawValue) } }
    if !skip.isEmpty { phases = phases.filter { !skip.contains($0.category.rawValue) } }
    guard !phases.isEmpty else { throw CLIError.badArgument("--only / --skip left no phases to record") }

    // A length or count flag that no selected phase reads is the same silent
    // failure as an unknown flag: the operator asked for something and got the
    // default. Say so before recording, not after.
    let hasTapPhase = phases.contains { $0.taps > 0 }
    let hasTimedPhase = phases.contains { $0.taps == 0 }
    let selected = phases.map { $0.category.rawValue }.joined(separator: ", ")
    if args.has("taps"), !hasTapPhase {
        throw CLIError.badArgument(
            "--taps only applies to tap_palmrest / tap_deck / tap_bottom, and none are selected"
            + " (\(selected)).\n  Drop --taps, or add a tap phase to --only.")
    }
    if uniform != nil, !hasTimedPhase {
        throw CLIError.badArgument(
            "--duration sets the length of a timed phase, and every selected phase is a prompted"
            + " tap phase (\(selected)).\n  Use --taps <n> to set how many double-taps are prompted.")
    }
    for (flag, cats) in [("typing-sec", ["typing"]), ("trackpad-sec", ["trackpad"])] {
        if args.has(flag), !phases.contains(where: { cats.contains($0.category.rawValue) }) {
            throw CLIError.badArgument(
                "--\(flag) only applies to the \(cats.joined()) phase, which is not selected"
                + " (\(selected)).")
        }
    }
    if args.has("confound-sec"),
       !phases.contains(where: { $0.category.isConfound || $0.category == .idle }) {
        throw CLIError.badArgument(
            "--confound-sec only applies to the confound and idle phases, none of which are"
            + " selected (\(selected)).")
    }

    if args.has("dry-run") {
        printGuidePlan(phases: phases, root: root, split: split, surface: surface,
                       restSec: restSec, minRest: minRest, maxRest: maxRest)
        Console.line("  --dry-run: nothing was recorded.")
        Console.line("")
        exit(0)
    }

    let cue = Cue(beepEnabled: !args.has("no-audio"), speechEnabled: !args.has("no-speech"),
                  volume: Float(try args.number("volume") ?? 0.35))

    return Runtime.run {
        printGuidePlan(phases: phases, root: root, split: split, surface: surface,
                       restSec: restSec, minRest: minRest, maxRest: maxRest)
        Console.line("  WEAR HEADPHONES, or the beep and my voice shake the chassis")
        Console.line("  and end up in the accelerometer stream.")
        Console.line("")
        cue.say("Tunk guided capture. Wear headphones if you can, otherwise my voice goes into the sensor. \(phases.count) phases.")

        // Two chances: a stale permission grant and an operator who did not press
        // anything look identical from here, so ask again before giving up.
        var rigOK = doctorCheck(seconds: 6, cue: cue, captureTouches: captureTouches)
        if !rigOK && !allowNoInput && !Runtime.isAborting {
            cue.say("I saw no input. Press a few keys during this second check.")
            rigOK = doctorCheck(seconds: 6, cue: cue, captureTouches: captureTouches)
        }
        if !rigOK, !allowNoInput {
            cue.say("Rig check failed. Fix permissions before recording.")
            Console.err("Rig check failed. Nothing was recorded. Re-run after fixing the grant,")
            Console.err("or pass --allow-no-input to record without the suppression gate data.")
            Runtime.exitNow(2)
        }

        var written = [SessionRecorder.Summary]()
        for (i, phase) in phases.enumerated() {
            let header = "PHASE \(i + 1)/\(phases.count)  \(phase.category.rawValue)"
            Console.banner(header)
            Console.line("  \(phase.setup)")
            cue.say("Phase \(i + 1) of \(phases.count). \(phase.setup)")
            if i > 0 || restSec > 0 {
                cue.say("You have \(Int(restSec)) seconds to get set.")
                if !Runtime.countdown(restSec, label: "get set", recorder: nil) { break }
            }

            var opts = SessionRecorder.Options(root: root, category: phase.category,
                                               surface: surface, split: split)
            opts.expectedTriggers = phase.taps
            opts.reportIntervalUs = reportIntervalUs
            opts.requireInput = !allowNoInput
            opts.captureTouches = captureTouches
            opts.notes = args.str("notes") ?? ""

            let recorder: SessionRecorder
            do {
                recorder = try SessionRecorder(opts: opts)
                Runtime.adopt(recorder)
                try recorder.start()
            } catch {
                Console.err("could not start phase \(phase.category.rawValue): \(error)")
                Runtime.exitNow(1)
            }
            recorder.mark(kind: "phase", text: phase.setup)

            let finishedCleanly: Bool
            if phase.taps > 0 {
                finishedCleanly = runTapPhase(recorder: recorder, cue: cue, phase: phase,
                                              minRest: minRest, maxRest: maxRest)
            } else {
                finishedCleanly = runTimedPhase(recorder: recorder, cue: cue, phase: phase)
            }

            let s = recorder.finish(reason: finishedCleanly ? "script" : "interrupted")
            Runtime.adopt(nil)
            written.append(s)
            Runtime.printSummary(s)
            if !finishedCleanly { break }
        }

        Console.banner("GUIDED CAPTURE COMPLETE")
        for s in written {
            let name = s.dir.lastPathComponent.padding(toLength: 52, withPad: " ", startingAt: 0)
            Console.line(name + String(format: "  %7.1fs  %8d samples  %6d input",
                                       Double(s.durationNs) / 1e9, s.sampleCount, s.inputCount))
        }
        Console.line("")
        Console.line("  Verify each one:  tunk-capture verify <dir>")
        cue.say("Capture complete.")
    }
}

/// What this run will record, printed before anything opens the sensor. The
/// operator can see that "one phase" really is one phase before committing the
/// next hour to it, and `--dry-run` shows the same thing without recording.
func printGuidePlan(phases: [Phase], root: URL, split: Split, surface: Surface,
                    restSec: Double, minRest: Double, maxRest: Double) {
    Console.banner("TUNK GUIDED CAPTURE  —  surface: \(surface.rawValue)")
    Console.line("  \(phases.count) phase\(phases.count == 1 ? "" : "s") into \(root.path) (split=\(split.rawValue))")
    Console.line("  Ctrl-C at any point keeps everything recorded so far.")
    Console.line("")
    var estimate = 0.0
    for (i, p) in phases.enumerated() {
        let body = p.taps > 0 ? Double(p.taps) * (minRest + maxRest) / 2 : p.seconds
        let what = p.taps > 0
            ? String(format: "%d prompted double-taps  (~%.0f s)", p.taps, body)
            : String(format: "%.0f s", body)
        estimate += restSec + body
        Console.line("    \(i + 1). \(p.category.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0))\(what)")
    }
    Console.line(estimate < 90
                 ? String(format: "  about %.0f s of recording, plus spoken prompts.", estimate)
                 : String(format: "  about %.0f min of recording, plus spoken prompts.", estimate / 60))
    Console.line("")
}

private func runTapPhase(recorder: SessionRecorder, cue: Cue, phase: Phase,
                         minRest: Double, maxRest: Double) -> Bool {
    recorder.mark(kind: "prompt", text: phase.during)
    Console.line("  \(phase.during)")
    cue.say(phase.during)
    cue.say("Starting in three. Two. One.")
    if !Runtime.sleep(1.5) { return false }

    for g in 0..<phase.taps {
        if Runtime.isAborting { return false }
        recorder.mark(kind: "prompt", text: "double-tap: \(phase.category.title)", group: g)
        // Tone first, mark second. The mark has to sit at the moment the
        // operator could hear the cue, not the moment we asked for it: with a
        // stalled audio path `play()` took ~16 s, and stamping first put every
        // beep mark 16 s before the sound, which puts every gesture outside the
        // labeller's window and turns the session into labels for silence.
        let beepDelay = cue.beep()
        recorder.mark(kind: "beep", group: g)
        if Cue.beepIsUnreliable {
            Console.line(String(format: "  !! the beep took %.1f s to start - audio is not "
                                + "keeping up, and these prompts are not trustworthy. "
                                + "Stop, fix audio, and re-record.", beepDelay))
        }
        Console.line("  >>> TAP  \(g + 1)/\(phase.taps)")
        // Randomised rest so no labeller or detector can lock onto a fixed period.
        let rest = Double.random(in: minRest...maxRest)
        if !Runtime.sleep(rest) { return false }
    }
    cue.say("Stop. Hands off.")
    recorder.mark(kind: "phase", text: "stop")
    return !Runtime.isAborting
}

private func runTimedPhase(recorder: SessionRecorder, cue: Cue, phase: Phase) -> Bool {
    recorder.mark(kind: "prompt", text: phase.during)
    Console.line("  \(phase.during)")
    cue.say(phase.during)
    cue.say("Go.")
    recorder.mark(kind: "phase", text: "go")

    let half = phase.seconds / 2
    if !Runtime.countdown(max(0, half), label: phase.category.rawValue, recorder: recorder) { return false }
    let tail = phase.seconds - half
    if tail > 15 {
        cue.say("Halfway. Keep going.")
        if !Runtime.countdown(tail - 10, label: phase.category.rawValue, recorder: recorder) { return false }
        cue.say("Ten seconds left.")
        if !Runtime.countdown(10, label: phase.category.rawValue, recorder: recorder) { return false }
    } else {
        if !Runtime.countdown(tail, label: phase.category.rawValue, recorder: recorder) { return false }
    }
    recorder.mark(kind: "phase", text: "stop")
    cue.say("Stop.")
    return !Runtime.isAborting
}
