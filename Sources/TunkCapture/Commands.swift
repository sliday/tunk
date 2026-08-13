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
    let duration = args.dbl("duration")

    var opts = SessionRecorder.Options(root: root, category: category, surface: surface, split: split)
    opts.notes = args.str("notes") ?? ""
    opts.expectedTriggers = args.int("expect") ?? 0
    opts.reportIntervalUs = Int64(args.int("report-interval-us") ?? 1250)
    opts.requireInput = !args.has("allow-no-input")
    opts.captureTouches = !args.has("no-touch")

    if category.isTapCategory, opts.expectedTriggers == 0 {
        Console.line("note: tap category with --expect 0. `guide` is the prompted, labellable mode.")
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
func runDoctor(_ args: Args) -> Never {
    let seconds = args.dbl("seconds") ?? 6.0
    let cue = Cue(beepEnabled: !args.has("no-audio"), speechEnabled: !args.has("no-speech"))
    return Runtime.run {
        let ok = doctorCheck(seconds: seconds, cue: cue, captureTouches: !args.has("no-touch"))
        Runtime.exitNow(ok ? 0 : 2)
    }
}

@discardableResult
func doctorCheck(seconds: Double, cue: Cue, captureTouches: Bool) -> Bool {
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

    let source = AccelSource(reportIntervalUs: 1250)
    var samples = 0
    let sLock = NSLock()
    var accelOK = true
    do {
        try source.start(epochMachNs: epoch) { _ in
            sLock.lock(); samples += 1; sLock.unlock()
        }
    } catch {
        accelOK = false
        Console.err("accelerometer: FAILED — \(error)")
    }

    if tapOK {
        Console.line("  Type a few keys and tap the trackpad now.")
        cue.say("Rig check. Type a few keys and tap the trackpad.")
    }
    _ = Runtime.countdown(seconds, label: "listening", recorder: nil)

    tap.stop()
    source.stop()

    sLock.lock(); let n = samples; sLock.unlock()
    let hz = n > 1 ? Double(n) / seconds : 0
    Console.line("")
    Console.line(String(format: "  accelerometer  %@  %d samples, %.0f Hz", accelOK ? "OK  " : "FAIL", n, hz))
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
    let taps = args.int("taps") ?? 20
    let restSec = args.dbl("rest-sec") ?? 12
    let minRest = args.dbl("min-rest") ?? 2.5
    let maxRest = args.dbl("max-rest") ?? 4.5
    let reportIntervalUs = Int64(args.int("report-interval-us") ?? 1250)
    let captureTouches = !args.has("no-touch")
    let allowNoInput = args.has("allow-no-input")

    var phases = guidePhases(taps: taps,
                             typingSec: args.dbl("typing-sec") ?? 180,
                             trackpadSec: args.dbl("trackpad-sec") ?? 90,
                             confoundSec: args.dbl("confound-sec") ?? 60,
                             surface: surface)
    let only = Set(args.list("only"))
    let skip = Set(args.list("skip"))
    if !only.isEmpty { phases = phases.filter { only.contains($0.category.rawValue) } }
    if !skip.isEmpty { phases = phases.filter { !skip.contains($0.category.rawValue) } }
    guard !phases.isEmpty else { throw CLIError.badArgument("--only / --skip left no phases to record") }

    let cue = Cue(beepEnabled: !args.has("no-audio"), speechEnabled: !args.has("no-speech"),
                  volume: Float(args.dbl("volume") ?? 0.35))

    return Runtime.run {
        Console.banner("TUNK GUIDED CAPTURE  —  surface: \(surface.rawValue)")
        Console.line("  \(phases.count) phases into \(root.path) (split=\(split.rawValue))")
        Console.line("  Ctrl-C at any point keeps everything recorded so far.")
        Console.line("")
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
        // Mark and tone as close together as the process can manage; the player is
        // already prepared, so the gap is a handful of milliseconds.
        recorder.mark(kind: "beep", group: g)
        cue.beep()
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
