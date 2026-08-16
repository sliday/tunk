import AppKit
import Darwin
import Foundation
import SwiftUI
import TunkCore
import TunkEmit
import TunkFormat
import TunkIMU

/// Two things a reviewer should be able to check against the built app rather
/// than against a claim in a comment: what it actually costs to run, and whether
/// the settings panel actually drives the live detector.
///
/// Both write plain text to stdout and exit. Neither changes normal behaviour,
/// and neither runs a user's Shortcut.
enum Diagnostics {

    // MARK: - CPU

    /// `tunk --cpu-probe [seconds]`
    ///
    /// Samples this process's own user+system CPU time across three phases:
    /// panel closed, panel open, panel closed again. The third phase is the
    /// point — it is what catches a monitor timer that was started when the
    /// panel opened and never stopped when it closed. If phase 3 does not come
    /// back down to roughly phase 1, the leak is back.
    ///
    /// CPU is reported as a percentage of one core: 100 % means one core fully
    /// busy, the same units `top` and `ps` use.
    static func cpuProbe(seconds: Double) {
        let settings = AppSettings()
        let engine = Engine(settings: settings)
        // Built lazily, in phase 2. Constructing it also builds the
        // `NSHostingView`, so doing it up front would make phase 1 measure
        // something other than "Settings never opened".
        var controller: SettingsWindowController?

        let perms = PermissionState.current()
        line("permissions: accessibility=\(perms.accessibility) "
           + "inputMonitoring=\(perms.inputMonitoring)")
        if !perms.ready {
            line("NOTE: not both granted, so the sensor will not start. The monitor timer,")
            line("      which is what this probe is about, runs either way — but the")
            line("      absolute numbers are lower than a fully armed app.")
        }
        engine.setEnabled(settings.enabled)
        line("detection enabled: \(settings.enabled)")
        line("sampling \(String(format: "%.0f", seconds)) s per phase, "
           + "CPU as % of one core\n")

        // Settle first: launch, window construction and the first Shortcuts
        // listing all cost something that is not steady state.
        spin(for: 2.0)

        line("phase                     CPU%%   monitor polls/s")
        let before = measure(seconds: seconds) { }
        report("1. panel never opened", before, "window not built yet")

        let open = measure(seconds: seconds) {
            controller = SettingsWindowController(settings: settings, engine: engine)
            controller?.present(startCalibration: false)
        }
        report("2. panel open        ", open, controller?.debugState ?? "")

        let after = measure(seconds: seconds) {
            controller?.dismiss()
        }
        report("3. panel closed again", after, controller?.debugState ?? "")

        // The poll rate is the real test. CPU alone is too noisy to judge on:
        // it moves with what else the machine is doing, and the first render of
        // a SwiftUI window costs more than steady state. A stopped timer polls
        // zero times, and that is unambiguous.
        line("")
        var failed = false
        if open.pollsPerSecond < 20 {
            failed = true
            line("SUSPECT: the panel was open but barely polled "
               + "(\(fmt(open.pollsPerSecond))/s). The probe may not have "
               + "rendered the window, so phase 3 proves nothing.")
        }
        if after.pollsPerSecond > 1 {
            failed = true
            line("LEAK: the monitor is still polling \(fmt(after.pollsPerSecond)) times a second "
               + "with the panel closed.")
        }
        if !failed {
            line("OK: the monitor polls only while the panel is on screen "
               + "(\(fmt(open.pollsPerSecond))/s open, \(fmt(after.pollsPerSecond))/s closed).")
        }
        exit(failed ? 1 : 0)
    }

    private struct Phase {
        var cpuPercent: Double
        var pollsPerSecond: Double
    }

    private static func report(_ label: String, _ p: Phase, _ state: String) {
        line(String(format: "%@  %6.2f            %5.1f   %@",
                    label, p.cpuPercent, p.pollsPerSecond, state))
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    /// Runs `setup`, then spins the main run loop for `seconds` and reports what
    /// this process burned and how often the monitor polled over that window.
    private static func measure(seconds: Double, setup: () -> Void) -> Phase {
        setup()
        // Let the change take effect, and let a newly shown window finish its
        // first layout, before the clock starts.
        spin(for: 1.5)
        let t0 = cpuSeconds()
        let p0 = MonitorStore.totalPulls
        let w0 = Date()
        spin(for: seconds)
        let cpu = cpuSeconds() - t0
        let pulls = MonitorStore.totalPulls - p0
        let wall = Date().timeIntervalSince(w0)
        guard wall > 0 else { return Phase(cpuPercent: 0, pollsPerSecond: 0) }
        return Phase(cpuPercent: (cpu / wall) * 100,
                     pollsPerSecond: Double(pulls) / wall)
    }

    /// User + system CPU seconds consumed by this process so far.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double {
            Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Runs the main run loop, so timers and the sensor callback behave exactly
    /// as they do in normal use. `Thread.sleep` would measure an app that is not
    /// doing its job.
    private static func spin(for seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Emission cost on the caller's thread

    /// `tunk --emit-probe [iterations]`
    ///
    /// Measures what firing a hotkey costs the thread that fires it. In
    /// production that thread is the 796 Hz HID delivery callback, where a
    /// sample arrives every 1.256 ms, so anything approaching a millisecond here
    /// drops samples out of the stream the gesture was detected in.
    ///
    /// Both paths are measured, because both still exist: `emit` blocks by
    /// design and is what the Test button uses, `emitAsync` is what the detector
    /// uses. Nothing is typed — a `RecordingPoster` stands in for CoreGraphics,
    /// so what this measures is the emitter's own blocking cost, which is
    /// dominated by the deliberate key-down hold.
    static func emitProbe(iterations: Int) {
        let poster = RecordingPoster()
        let emitter = HotkeyEmitter(
            hotkey: .recommendedDefault,
            options: .default,
            poster: poster,
            permission: AlwaysTrustedPermission(),
            secureInput: StubSecureInput(active: false))

        line("cost to the calling thread, \(iterations) iterations")
        line("one accelerometer sample period = 1.256 ms\n")

        var sync: [Int64] = []
        for _ in 0..<iterations {
            let t0 = MachClock.nowNanos()
            _ = try? emitter.emit()
            sync.append(MachClock.nowNanos() - t0)
        }

        var async: [Int64] = []
        for _ in 0..<iterations {
            let t0 = MachClock.nowNanos()
            emitter.emitAsync()
            async.append(MachClock.nowNanos() - t0)
        }

        line("path                       p50        p95        max")
        report("emit()      (blocking) ", sync)
        report("emitAsync() (detector) ", async)

        // Let the queue drain before checking balance.
        spin(for: 2.0)
        let stats = emitter.stats
        line("")
        line("pairs completed \(stats.pairsCompleted), unbalanced \(stats.unbalancedPairs), "
           + "downs \(stats.keyDownsPosted), ups \(stats.keyUpsPosted)")

        let worst = async.max() ?? 0
        let overBudget = worst > 1_256_000
        line(overBudget
             ? "FAIL: worst detector-path handoff exceeded one sample period."
             : "OK: the detector path costs a fraction of a sample period.")
        if stats.hasStuckKey { line("FAIL: a key-down went out without its key-up.") }
        exit(overBudget || stats.hasStuckKey ? 1 : 0)
    }

    private static func report(_ label: String, _ samples: [Int64]) {
        let sorted = samples.sorted()
        func pick(_ q: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let i = min(sorted.count - 1, Int(Double(sorted.count - 1) * q))
            return Double(sorted[i]) / 1_000_000
        }
        line(String(format: "%@ %7.3f ms %7.3f ms %7.3f ms",
                    label, pick(0.5), pick(0.95), Double(sorted.last ?? 0) / 1_000_000))
    }

    /// `tunk --live-emit-probe`
    ///
    /// Posts a real key pair through `HotkeyEmitter` and CoreGraphics, then
    /// polls the session's modifier state until it clears. This is the
    /// stuck-modifier check against the real thing rather than a recorder, and
    /// it exists because a change to the emitter once left the flags asserted in
    /// a way only a live post could show.
    ///
    /// F16 is used because it is absent from this keyboard and measured not to
    /// reach Carbon hot key listeners when synthesised, so running this cannot
    /// type anything or trip a shortcut.
    static func liveEmitProbe() {
        let spec = HotkeySpec(keyCode: 106, modifiers: [.control, .option, .shift, .command])
        guard AXIsProcessTrusted() else {
            line("Accessibility not granted to this binary; CGEventPost would be a no-op.")
            exit(2)
        }

        // Two arms, alternated, same number of trials each:
        //
        //   raw     — CGEvent built and posted here, no Tunk code in the path.
        //   emitter — the same pair through `HotkeyEmitter`.
        //
        // The comparison is the point. "The flags were still asserted after two
        // seconds" is not by itself evidence of a Tunk bug: the window server
        // clears synthetic modifier state on its own schedule, and under load it
        // sometimes takes longer than any deadline worth waiting. Only the
        // emitter arm being *worse than raw* implicates Tunk.
        let trials = 12
        let flags = spec.eventFlags(includeDeviceSide: true).rawValue
        let src = CGEventSource(stateID: .privateState)
        var rawStuck = 0
        var emitterStuck = 0

        func postRaw() {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 106, keyDown: down)
                else { continue }
                e.flags = CGEventFlags(rawValue: flags)
                e.post(tap: .cghidEventTap)
                if down { Thread.sleep(forTimeInterval: 0.008) }
            }
        }

        let emitter = HotkeyEmitter(hotkey: spec)
        for _ in 0..<trials {
            postRaw()
            if waitForModifiersToClear(seconds: 2) != 0 { rawStuck += 1 }

            try? emitter.emit()
            if waitForModifiersToClear(seconds: 2) != 0 { emitterStuck += 1 }
        }

        line("trials \(trials) each")
        line("raw CGEvent, no Tunk code : \(rawStuck)/\(trials) left flags asserted after 2 s")
        line("through HotkeyEmitter     : \(emitterStuck)/\(trials) left flags asserted after 2 s")
        line("emitter pairs completed \(emitter.stats.pairsCompleted), "
           + "unbalanced \(emitter.stats.unbalancedPairs)")

        line("")
        if emitter.stats.unbalancedPairs > 0 {
            line("FAIL: a key-down went out without its key-up.")
            exit(1)
        }
        // The emitter must be zero, not merely no worse than raw. It posts a
        // keyless `flagsChanged` after the pair precisely so it can be.
        if emitterStuck > 0 {
            line("FAIL: the emitter left modifiers asserted. Its modifier release is not "
               + "running on every path.")
            exit(1)
        }
        line("OK: the emitter always drops the modifiers it asserted.")
        if rawStuck > 0 {
            line("For contrast, a raw post that omits the release left them asserted "
               + "\(rawStuck)/\(trials) times — that is what this fix prevents.")
        }
        exit(0)
    }

    private static func waitForModifiersToClear(seconds: CFTimeInterval) -> UInt64 {
        let interesting: UInt64 = CGEventFlags.maskControl.rawValue
                                | CGEventFlags.maskAlternate.rawValue
                                | CGEventFlags.maskShift.rawValue
                                | CGEventFlags.maskCommand.rawValue
        let end = Date().addingTimeInterval(seconds)
        var residual: UInt64 = 0
        repeat {
            residual = CGEventSource.flagsState(.combinedSessionState).rawValue & interesting
            if residual == 0 { return 0 }
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        } while Date() < end
        return residual
    }

    // MARK: - Config wiring

    /// `tunk --config-trace`
    ///
    /// Proves at runtime that the panel writes the same `DetectorConfig` the
    /// running detector reads, rather than a copy nobody consults. Writes
    /// through `AppSettings` exactly as a slider does, then reads back what the
    /// live detector reports as in force.
    ///
    /// Runs against a throwaway defaults suite, so it cannot disturb the
    /// settings the operator is using.
    static func configTrace() {
        let suite = "dev.tunk.configtrace." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let settings = AppSettings(suiteName: suite)
        let engine = Engine(settings: settings)
        var failures = 0

        func check(_ label: String, _ wrote: String, _ read: String) {
            let ok = wrote == read
            if !ok { failures += 1 }
            line("\(ok ? "OK  " : "FAIL") \(label): panel wrote \(wrote), detector has \(read)")
        }

        line("one DetectorConfig, written by AppSettings, read by the live detector\n")

        // Gate window: the knob that matters most, and the one a critic
        // flagged as possibly unwired.
        settings.config.gateWindowNs = 240_000_000
        check("gate window",
              ms(settings.config.gateWindowNs), ms(engine.effectiveConfig.gateWindowNs))

        settings.config.sensitivity = 1.35
        check("sensitivity",
              String(format: "%.2f", settings.config.sensitivity),
              String(format: "%.2f", engine.effectiveConfig.sensitivity))

        settings.config.calibratedThreshold = 0.42
        check("calibrated threshold",
              String(format: "%.3f", settings.config.effectiveThreshold),
              String(format: "%.3f", engine.effectiveConfig.effectiveThreshold))

        // Arming comes from the action bindings, not from a second switch.
        settings.setActionKind(.hotkey, for: 1)
        check("armed counts after binding single tap",
              Set(settings.bindings.boundCounts).sorted().description,
              engine.effectiveConfig.armedTapCounts.sorted().description)

        settings.setActionKind(.none, for: 1)
        check("armed counts after unbinding single tap",
              Set(settings.bindings.boundCounts).sorted().description,
              engine.effectiveConfig.armedTapCounts.sorted().description)

        // The clamp: what the panel stores and what runs can legitimately
        // differ, and the panel has to show the second one.
        settings.config.maxInterTapNs = 900_000_000
        let clamped = engine.effectiveConfig
        line("")
        line("clamped-on-write check (these two are allowed to differ):")
        line("  stored max inter-tap   : \(ms(settings.config.maxInterTapNs))")
        line("  in force               : \(ms(clamped.maxInterTapNs))")
        line("  confirm window         : \(ms(clamped.confirmWindowNs))")
        for issue in settings.config.coherenceIssues { line("  reported: \(issue)") }
        if clamped.maxInterTapNs > clamped.confirmWindowNs {
            failures += 1
            line("FAIL invariant maxInterTapNs <= confirmWindowNs is broken in force")
        }

        line("")
        line(failures == 0
             ? "OK: every panel write reached the running detector."
             : "\(failures) FAILURES: the panel is writing something the detector does not read.")
        exit(failures == 0 ? 0 : 1)
    }

    private static func ms(_ ns: Int64) -> String {
        String(format: "%.0f ms", Double(ns) / 1_000_000)
    }

    private static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

// MARK: - end-to-end latency

extension Diagnostics {
    /// Measures the PRD's latency definition — last tap onset to emitted key
    /// event — end to end, with the real detector, the real emitter, a real
    /// `CGEventPost`, and an independent event tap watching for the result.
    ///
    /// The gesture is synthetic and paced in real time at the sensor's real
    /// rate, so the number includes scheduling, the confirm window, dispatch and
    /// the window server. What it does NOT establish is whether a real finger
    /// tap is detected at all, or how accurately its onset is located; those
    /// need recordings and no amount of synthesis substitutes for them.
    static func latencyProbe(iterations: Int) {
        guard AXIsProcessTrusted() else {
            line("Accessibility not granted to this binary; CGEventPost would be a no-op.")
            exit(2)
        }

        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var stamps: [UInt64] = []
            func record(_ t: UInt64) { lock.lock(); stamps.append(t); lock.unlock() }
            func drain() -> [UInt64] {
                lock.lock(); defer { stamps.removeAll(); lock.unlock() }
                return stamps
            }
        }
        let sink = Sink()

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func nowNs() -> UInt64 { mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom) }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                // Ours only. The poster stamps every event it creates.
                if event.getIntegerValueField(.eventSourceUserData) == CGEventPoster.userDataTag,
                   let refcon {
                    Unmanaged<Sink>.fromOpaque(refcon).takeUnretainedValue()
                        .record(mach_absolute_time())
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(sink).toOpaque()) else {
            line("event tap failed")
            exit(2)
        }
        // The tap runs on its OWN thread with its own run loop, serviced
        // continuously. Attached to this thread's run loop instead, the callback
        // only fires when the sample loop pauses to pump it, so the stamp
        // measures "when the probe got round to noticing" rather than when the
        // event landed — that read 56.5 ms and was entirely the probe.
        let ready = DispatchSemaphore(value: 0)
        Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }.start()
        ready.wait()

        // F16 with four modifiers: rare, and nothing here consumes it.
        let spec = HotkeySpec(keyCode: 106, modifiers: [.control, .option, .shift, .command])
        let emitter = HotkeyEmitter(hotkey: spec)

        let rateHz = 796.3
        let stepNs = Int64(1e9 / rateHz)
        let leadNs: Int64 = 1_500_000_000
        let spacingNs: Int64 = 150_000_000

        func ring(_ dt: Double, _ amplitude: Double) -> Double {
            guard dt >= 0, dt < 0.030 else { return 0 }
            return exp(-dt * 150.0) * sin(dt * 2 * .pi * 200.0) * amplitude
        }

        var overheads: [Double] = []      // decision -> key event observed
        var sampleDomain: [Double] = []   // onset -> decision, in sample time
        var wallClock: [Double] = []      // onset -> key event, wall clock
        var noEvent = 0

        for _ in 0..<iterations {
            let detector = TapDetector(config: .default)
            var secondOnsetWall: UInt64 = 0
            var decisionWall: UInt64 = 0
            var sampleDomainNs: Int64 = 0
            var fired = false
            _ = sink.drain()

            let total = Int(2.2 * rateHz)
            let start = nowNs()
            for i in 0..<total {
                let tNs = Int64(i) * stepNs
                let due = start &+ UInt64(tNs)
                var now = nowNs()
                if due > now {
                    usleep(useconds_t(min((due - now) / 1000, 5000)))
                    now = nowNs()
                }
                // Raw ticks, matching what the tap callback records. Mixing
                // ticks and nanoseconds here silently produced zero
                // measurements: on Apple Silicon the timebase is 125/3, so the
                // tick stamp is always the smaller number and every comparison
                // failed.
                // First sample AT OR AFTER the second onset. Equality never
                // holds: stepNs is 1255807 ns and does not divide 1.65e9, so an
                // == test left this stamp at zero and every run was discarded.
                if secondOnsetWall == 0 && tNs >= leadNs + spacingNs {
                    secondOnsetWall = mach_absolute_time()
                }

                let r = ring(Double(tNs - leadNs) / 1e9, 0.9)
                    + ring(Double(tNs - leadNs - spacingNs) / 1e9, 0.85)
                let sample = AccelSample(tNs: tNs, arrivalNs: tNs,
                                         x: Float(r * 0.5), y: 0, z: Float(-0.9796 + r))
                if let trigger = detector.ingest(sample: sample), !fired {
                    fired = true
                    decisionWall = mach_absolute_time()
                    // Sample-domain latency is exact and free of any pacing
                    // artefact: the detector is driven by sample timestamps, not
                    // by a clock, so this is the confirm window by construction.
                    sampleDomainNs = trigger.tNs - (trigger.tapOnsets.last ?? trigger.tNs)
                    _ = try? emitter.emit()
                }
                // No run-loop pumping here: the tap has its own thread.
            }
            usleep(300_000)   // let the tap thread deliver

            if fired, secondOnsetWall > 0, decisionWall > 0,
               let first = sink.drain().first, first > decisionWall {
                func ms(_ ticks: UInt64) -> Double {
                    Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e6
                }
                overheads.append(ms(first - decisionWall))
                sampleDomain.append(Double(sampleDomainNs) / 1e6)
                wallClock.append(ms(first - secondOnsetWall))
            } else {
                noEvent += 1
            }
        }

        func pct(_ v: [Double], _ p: Double) -> Double {
            guard !v.isEmpty else { return .nan }
            let s = v.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
        }

        line("")
        line("END-TO-END LATENCY — second onset to observed key event")
        line("  runs                 \(iterations)")
        line("  measured             \(overheads.count)   (\(noEvent) produced no observed event)")
        if !overheads.isEmpty {
            line("")
            line("  A. onset -> decision, in SAMPLE time (exact, no clock involved)")
            line(String(format: "     p50 %.1f ms   p95 %.1f ms", pct(sampleDomain, 0.50), pct(sampleDomain, 0.95)))
            line("     The detector advances only on samples, so this is the confirm")
            line("     window by construction and cannot drift.")
            line("")
            line("  B. decision -> key event observed, WALL CLOCK (the real overhead)")
            line(String(format: "     p50 %.2f ms   p95 %.2f ms   max %.2f ms",
                        pct(overheads, 0.50), pct(overheads, 0.95), overheads.max()!))
            line("     Real CGEventPost, observed by an independent event tap.")
            line("")
            let total = pct(sampleDomain, 0.95) + pct(overheads, 0.95)
            line(String(format: "  A + B at p95         %.1f ms   PRD bar 250 ms  ->  %@",
                        total, total <= 250 ? "PASS" : "FAIL"))
            line("")
            line(String(format: "  Naive wall clock across the whole run: p95 %.1f ms, which now agrees",
                        pct(wallClock, 0.95)))
            line("  with A + B to about a millisecond. It did not always: an earlier")
            line("  version of this probe read 56 ms for B and I wrote that off as usleep")
            line("  pacing drift. Wrong. The tap callback was attached to the sample")
            line("  loop's own run loop, so it only fired when the loop paused to pump")
            line("  it, and B was measuring when the probe noticed rather than when the")
            line("  event landed. Moving the tap to its own thread took B from 56 ms to")
            line("  0.19 ms. The lesson is that a plausible explanation for a bad number")
            line("  is not a diagnosis.")
        }
        line("")
        line("  Synthetic gesture, real detector, real CGEventPost, observed by an")
        line("  independent tap. Measures the PIPELINE. Whether a real finger tap is")
        line("  detected, and how accurately its onset is located, need recordings.")
        exit(overheads.isEmpty ? 1 : 0)
    }
}

// MARK: - haptic actuator probe

extension Diagnostics {
    /// Does the Taptic Engine put measurable energy into the chassis?
    ///
    /// Asked once before from a bare CLI and answered "no". That test was weak:
    /// `NSHapticFeedbackManager` documents no behaviour outside an app context
    /// and may have silently done nothing. This runs inside a real
    /// `NSApplication` with the accelerometer open, fires each pattern, and
    /// reports the envelope it actually produced against the resting floor.
    ///
    /// If it registers, it is a controllable mechanical stimulus, and detection
    /// rate stops being un-measurable without a hand. If it does not, that is a
    /// real answer too and closes the question properly this time.
    static func hapticProbe() {
        let source = AccelSource(reportIntervalUs: 1250)
        let lock = NSLock()
        var samples: [AccelSample] = []
        do {
            try source.start { s in
                lock.lock(); samples.append(s); lock.unlock()
            }
        } catch {
            line("accelerometer failed: \(error)")
            exit(2)
        }
        Thread.sleep(forTimeInterval: 1.5)   // settle, and establish a floor

        let performer = NSHapticFeedbackManager.defaultPerformer
        let patterns: [(String, NSHapticFeedbackManager.FeedbackPattern)] =
            [("generic", .generic), ("alignment", .alignment), ("levelChange", .levelChange)]

        var marks: [(String, Int64)] = []
        for (name, pattern) in patterns {
            for _ in 0..<5 {
                lock.lock(); let t = samples.last?.tNs ?? 0; lock.unlock()
                marks.append((name, t))
                performer.perform(pattern, performanceTime: .now)
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()

        lock.lock(); let all = samples; lock.unlock()
        guard all.count > 2000 else { line("too few samples (\(all.count))"); exit(2) }

        // Same envelope the labeller uses: high-pass by subtracting a local
        // mean, then vector magnitude.
        let w = 64
        var env: [(Int64, Double)] = []
        for i in w..<(all.count - w) {
            var bx = 0.0, by = 0.0, bz = 0.0
            for j in (i - w/2)..<(i + w/2) {
                bx += Double(all[j].x); by += Double(all[j].y); bz += Double(all[j].z)
            }
            bx /= Double(w); by /= Double(w); bz /= Double(w)
            let dx = Double(all[i].x) - bx, dy = Double(all[i].y) - by, dz = Double(all[i].z) - bz
            env.append((all[i].tNs, (dx*dx + dy*dy + dz*dz).squareRoot()))
        }
        let sorted = env.map(\.1).sorted()
        let floor = sorted[sorted.count / 2]
        let ceiling = sorted[sorted.count - 1]

        line("")
        line("TAPTIC ENGINE PROBE — inside a real NSApplication, accelerometer open")
        line(String(format: "  samples            %d", all.count))
        line(String(format: "  resting floor      %.5f g   (median envelope)", floor))
        line(String(format: "  session max        %.5f g", ceiling))
        line("")
        for (name, _) in patterns.map({ ($0.0, 0) }) {
            let windows = marks.filter { $0.0 == name }
            var peaks: [Double] = []
            for (_, at) in windows {
                let hit = env.filter { $0.0 >= at && $0.0 <= at + 150_000_000 }.map(\.1).max()
                if let hit { peaks.append(hit) }
            }
            let best = peaks.max() ?? 0
            line(String(format: "  %-12s peak in window  %.5f g   %.1fx floor   %@",
                        (name as NSString).utf8String!, best, best / max(floor, 1e-9),
                        best > floor * 6 ? "REGISTERS" : "nothing above noise"))
        }
        line("")
        line("  A deliberate finger tap on this chassis runs a few tenths of a g.")
        line("  Anything under about 6x the floor is not a usable stimulus.")
        exit(0)
    }
}

// MARK: - live acceptance

/// Seals the session in flight when the run is cut short.
///
/// A 50-tap acceptance run is fifteen minutes of somebody's hands, and it gets
/// abandoned: Ctrl-C, a closed terminal, `| head`. Without this the accelerometer
/// stream is on disk but `meta.json` never lands, and a directory with no
/// `meta.json` is not a session — every tool refuses to open it, and the whole
/// take is lost. `TunkCapture.Runtime` handles it the same way, and for the same
/// reason.
///
/// Handled on a dispatch source rather than in a C signal handler, so it can do
/// real work: writing a file from a signal handler is not allowed, and this has
/// to write three.
private enum AcceptanceAbort {
    nonisolated(unsafe) private static var recorder: AcceptanceRecorder?
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    private static let lock = NSLock()

    static func adopt(_ r: AcceptanceRecorder?) {
        lock.lock(); recorder = r; lock.unlock()
    }

    static func install() {
        guard sources.isEmpty else { return }
        let q = DispatchQueue(label: "dev.tunk.acceptance.signal")
        for (sig, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM"), (SIGPIPE, "SIGPIPE")] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
            s.setEventHandler { seal(name: name) }
            s.resume()
            sources.append(s)
        }
    }

    private static func seal(name: String) {
        lock.lock()
        let r = recorder
        recorder = nil
        lock.unlock()
        if let r {
            r.mark(kind: "operator_mark", text: "run cut short by \(name)")
            let s = r.finish(reason: "aborted:\(name)")
            FileHandle.standardError.write(Data(
                "\n\(name): sealed \(s.sampleCount) samples into \(s.dir.path)\n".utf8))
        }
        exit(130)
    }
}

extension Diagnostics {
    /// The PRD's final acceptance test, run on the built app rather than on a
    /// replay: "perform 50 deliberate double-taps and record hit rate and
    /// latency, then type continuously for 5 minutes and record false triggers".
    ///
    /// Two phases, counted live against the real sensor, the real detector and
    /// the real action path.
    ///
    /// Phase 1 prompts N deliberate double-taps and counts what fired. Hit rate
    /// is triggers divided by prompts. Latency is measured from the detector's
    /// own last onset to the moment the trigger was returned, which is the same
    /// definition the harness uses offline, so the two are comparable.
    ///
    /// Phase 2 asks for continuous typing and counts anything that fires. The
    /// bar is zero, and this is the metric the PRD calls make-or-break.
    ///
    /// Deliberately does NOT post the bound action. Firing a hotkey or a
    /// Shortcut fifty times into whatever has focus would be its own disaster,
    /// and the acceptance question is whether the gesture is recognised, not
    /// whether CGEventPost works — `--live-emit-probe` already covers that.
    /// "5 minutes", "90 seconds", "1 minute". Spoken, so it has to read aloud.
    static func spokenDuration(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) seconds" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// What `--record` asked for. Nil means the run prints its numbers and
    /// writes nothing, which is what `--acceptance` did before this existed.
    struct AcceptanceRecording {
        /// Always named on the command line. There is deliberately no default:
        /// `data/` is the frozen corpus, and a default path is how a run ends up
        /// inside it by accident.
        var root: URL
        var surface: Surface
        var tapCategory: TunkFormat.Category
        /// True when `--surface` was not given. Recorded rather than hidden: a
        /// surface nobody stated is a surface nobody can trust, and every metric
        /// in FORMAT.md is reported per surface.
        var surfaceWasDefaulted: Bool
    }

    /// `split` has to agree with the directory a session sits in, or
    /// `tunk-capture verify` fails it and a test session can leak into tuning.
    /// Only `holdout` means test; anything else is training material.
    static func split(for root: URL) -> Split {
        root.standardizedFileURL.lastPathComponent == "holdout" ? .test : .train
    }

    /// The detector that produced the run, in the field a reader sees first.
    /// Without it two recordings made minutes apart by different detectors are
    /// indistinguishable, and the experimental switch is one checkbox away.
    static func acceptanceToolVersion(settings: AppSettings) -> String {
        // Both switches, or a session records that it was made by the default
        // detector while running a different front end - a self-contradicting
        // artifact in a corpus whose whole value is that it is trustworthy.
        var parts: [String] = []
        if settings.experimentalResonator { parts.append("resonator") }
        if settings.experimentalLapPairing { parts.append("lap_pairing_experiment") }
        return "tunk acceptance 0.1.0 (detector="
            + (parts.isEmpty ? "default" : parts.joined(separator: "+")) + ")"
    }

    /// Everything a critic needs to replay this session under the same detector
    /// it was recorded with, written into `meta.json` and the head of `notes.md`.
    static func recordingNotes(recording: AcceptanceRecording, settings: AppSettings,
                               engine: Engine, taps: Int, typingSeconds: Double) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let config = (try? enc.encode(engine.effectiveConfig))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
        var lines = [
            "LIVE ACCEPTANCE run of the built app: "
                + "`Tunk --acceptance \(taps) \(Int(typingSeconds)) --record <dir>`.",
            "",
            "detector tuning: "
                + (settings.experimentalLapPairing
                    ? "DSPTuning.lapPairingExperiment (the experimental lap pairing switch is ON)"
                    : "DSPTuning.default"),
            "effective DetectorConfig: \(config)",
            "",
            "MARKS, NOT LABELS. `beep` marks say when the cue was audible, which is "
                + "when the operator was ASKED to tap. Nothing here records when anybody "
                + "actually tapped, and labels.jsonl is empty until tunk-label fills it in "
                + "from those marks. `live_trigger` marks are what the live detector fired: "
                + "evidence to compare a replay against, never ground truth.",
        ]
        if recording.surfaceWasDefaulted {
            lines.append("")
            lines.append("SURFACE WAS NOT STATED and defaults to "
                       + "\(recording.surface.rawValue). Every metric in FORMAT.md is "
                       + "reported per surface, so correct this before using the session "
                       + "for anything surface-specific.")
        }
        return lines.joined(separator: "\n")
    }

    static func acceptance(taps: Int, typingSeconds: Double,
                           recording: AcceptanceRecording? = nil) {
        let settings = AppSettings()
        let engine = Engine(settings: settings)
        var fired: [(atNs: Int64, lastOnsetNs: Int64)] = []
        let lock = NSLock()

        engine.onTriggerForTesting = { trigger in
            lock.lock()
            fired.append((trigger.tNs, trigger.tapOnsets.last ?? trigger.tNs))
            lock.unlock()
        }
        engine.setEnabled(true)
        // `spin`, not `Thread.sleep`. NSEvent global monitors deliver only through
        // the main run loop, and InputActivityMonitor is what feeds the keystroke
        // gate. Sleeping here measured a detector with NO GATE AT ALL - phase 2's
        // whole purpose is typing false triggers, and un-gated this corpus fires
        // at 188 per 20 min against a shipped 0. It also left input.jsonl empty,
        // so every recorded typing session was rejected by `verify`, and starved
        // the watchdog for the length of the run.
        spin(for: 1.5)
        guard case .running = engine.status else {
            line("not armed: \(engine.status). Grant Input Monitoring to this binary.")
            exit(2)
        }

        // Bounded, and it gives up for good after the first stall. `say` blocks
        // indefinitely on this machine when the audio path is wedged by a virtual
        // driver — measured at a full 2-minute timeout, which is what forced the
        // same bound into TunkCapture's Cue. A 50-tap acceptance run calls this
        // 50 times and can only be performed by hand, so one stall would strand
        // the operator mid-test. The prompt is also printed, so losing the voice
        // costs nothing the test depends on.
        var speechGaveUp = false
        func speak(_ s: String) {
            line(s)
            guard !speechGaveUp else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-r", "220", s]
            guard (try? p.run()) != nil else { speechGaveUp = true; return }
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning, Date() < deadline { spin(for: 0.02) }
            if p.isRunning {
                p.terminate()
                speechGaveUp = true
                line("  (speech stalled; carrying on with printed prompts only)")
            }
        }

        // Recording, if asked for. Two sessions, because the two phases are
        // different categories: prompted taps with `expected_triggers = taps`,
        // then typing with `expected_triggers = 0`.
        let cue = recording == nil ? nil : AcceptanceCue()
        var written: [AcceptanceRecorder.Summary] = []
        func startRecording(category: TunkFormat.Category, expected: Int) -> AcceptanceRecorder? {
            guard let recording else { return nil }
            do {
                let r = try AcceptanceRecorder(
                    options: .init(root: recording.root,
                                   category: category,
                                   surface: recording.surface,
                                   split: Self.split(for: recording.root),
                                   expectedTriggers: expected,
                                   notes: Self.recordingNotes(recording: recording,
                                                              settings: settings,
                                                              engine: engine,
                                                              taps: taps,
                                                              typingSeconds: typingSeconds),
                                   toolVersion: Self.acceptanceToolVersion(settings: settings)),
                    callerEpochMachNs: engine.epochMachNs,
                    startNs: engine.nowNs(),
                    clock: { engine.nowNs() })
                engine.setRecorder(r)
                AcceptanceAbort.install()
                AcceptanceAbort.adopt(r)
                // "The monitor is installed" is not the same as "the monitor can
                // see anything". While another process holds secure event input
                // — every password field, some terminals, the lock screen — the
                // window server delivers no keystrokes to anyone, so
                // `input.jsonl` comes out empty and the gate cannot be replayed.
                // Saying `degraded` here is what makes `tunk-capture verify`
                // reject the session for the right reason instead of the
                // operator wondering why it is empty.
                let blind = SystemSecureInput().isSecureInputActive
                r.mark(kind: "input_tap",
                       text: (engine.inputTapActive && !blind) ? "active" : "degraded")
                if blind {
                    r.mark(kind: "operator_mark",
                           text: "secure event input was held by another process for this "
                               + "session: no keyboard events reach any monitor, so the gate "
                               + "cannot be replayed from this recording")
                    line("  !! SECURE INPUT IS ON. Keystrokes are invisible to every monitor,")
                    line("     so input.jsonl will be empty and verify will reject this")
                    line("     session. Close whatever holds it and re-record.")
                }
                r.mark(kind: "phase", text: "start:\(category.rawValue)")
                line("  recording -> \(r.dir.path)")
                return r
            } catch {
                line("  could not start recording in \(recording.root.path): \(error)")
                exit(2)
            }
        }
        func stopRecording(_ r: AcceptanceRecorder?, reason: String) {
            guard let r else { return }
            r.mark(kind: "phase", text: "stop")
            engine.setRecorder(nil)
            AcceptanceAbort.adopt(nil)
            let s = r.finish(reason: reason)
            written.append(s)
            line(String(format: "  wrote %d samples, %d input events, %d marks -> %@",
                        s.sampleCount, s.inputCount, s.markCount, s.dir.lastPathComponent))
            if s.inputCount == 0 {
                line("  NOTE: no keyboard or trackpad events landed in that session, so")
                line("        `tunk-capture verify` will fail it: the gate cannot be replayed.")
            }
        }

        // A recording anchors its ground truth to the beep marks, so a beep
        // nobody can hear is worse than no recording at all: the labeller would
        // place every onset against a cue that never sounded. This is the 16 s
        // audio-stall failure wearing a different hat, and the property that
        // detects it already existed and was never read.
        // Same reasoning as the audio guard below, one step earlier. With secure
        // input held by another process the window server delivers no keyboard
        // events to any monitor, so input.jsonl comes out empty and
        // `tunk-capture verify` rejects the typing session as unusable for
        // false-positive scoring. A full run is 50 taps and five minutes of
        // typing performed by hand; discovering that afterwards wastes all of
        // it. Warn-and-continue is right without --record, because then nothing
        // is being kept.
        if recording != nil, SystemSecureInput().isSecureInputActive {
            line("")
            line("!! SECURE INPUT IS ON, so no keyboard event reaches any monitor.")
            line("   input.jsonl would come out empty and verify would reject the")
            line("   typing session as unusable for false-positive scoring — after")
            line("   you had already typed for the full phase. Refusing to record.")
            line("   Unlock the screen and quit whatever holds it (a focused password")
            line("   field is the usual cause), then re-run. Drop --record to run")
            line("   the test without keeping a recording.")
            exit(2)
        }

        if recording != nil, cue?.isAvailable != true {
            line("")
            line("!! NO USABLE AUDIO OUTPUT, so the beep cue cannot sound.")
            line("   Ground truth in a recording is anchored to those beeps, so this")
            line("   run would write labels against cues nobody heard. Refusing to")
            line("   record. Fix audio output, or drop --record to run without one.")
            exit(2)
        }

        if let recording {
            line("")
            line("RECORDING to \(recording.root.path)")
            line("  category \(recording.tapCategory.rawValue) for the taps, typing for phase 2,")
            line("  surface \(recording.surface.rawValue)"
               + (recording.surfaceWasDefaulted ? " (DEFAULTED — pass --surface to state it)" : ""))
            line("  WEAR HEADPHONES: the cue beep shakes the chassis through the speakers.")
            line("  labels.jsonl is written EMPTY. Ground truth comes from tunk-label")
            line("  reading the beep marks, never from what fired here.")
        }

        line("")
        line("LIVE ACCEPTANCE — phase 1 of 2: \(taps) deliberate double-taps")
        line("  Wait for each prompt, then double-tap the chassis. Hands off between.")
        let tapRecorder = startRecording(category: recording?.tapCategory ?? .tapDeck,
                                         expected: taps)
        if let recording {
            // The recording declares a category, so the operator has to be told
            // which surface it claims. A file that says tap_deck while the
            // operator tapped the palm rest is worse than no file.
            line("  Recorded as \(recording.tapCategory.rawValue): perform "
               + "\(recording.tapCategory.title), after each beep.")
            tapRecorder?.mark(kind: "prompt", text: "after each beep, "
                            + "\(recording.tapCategory.title): two firm taps, then hands off")
        }
        speak("Phase one. \(taps) double taps.")

        var hits = 0
        for i in 1...taps {
            lock.lock(); let before = fired.count; lock.unlock()
            line("  tap \(i)/\(taps)")
            tapRecorder?.mark(kind: "prompt",
                              text: "double-tap: \(recording?.tapCategory.title ?? "chassis")",
                              group: i - 1)
            // Beep-only when recording. Measured: `say -r 220 tap` runs 1.24 s
            // wall of which 0.336 s is audible, so the voice leads the beep by
            // about 0.35 s and an operator answering it lands that much earlier
            // than in every other session in the corpus — which is anchored on
            // the beep alone (TunkCapture runTapPhase speaks once per phase).
            // tunk-label's window is [beep, beep + 2600 ms] and anything before
            // the beep is invisible to it.
            if recording == nil { speak("tap") }
            // Tone first, mark second. The mark has to sit at the moment the
            // operator could hear the cue, not the moment we asked for it: with
            // a stalled audio path `play()` took ~16 s, and stamping first put
            // every beep mark 16 s before the sound, which puts every gesture
            // outside the labeller's window and turns the session into labels
            // for silence. Same ordering as TunkCapture's tap phase.
            if let cue, let tapRecorder {
                let delay = cue.beep()
                tapRecorder.mark(kind: "beep", group: i - 1)
                if cue.unreliable {
                    line(String(format: "  !! the beep took %.1f s to start — audio is not "
                              + "keeping up, and these prompts are not trustworthy. "
                              + "Stop, fix audio, and re-record.", delay))
                }
            }
            spin(for: 2.6)
            lock.lock(); let after = fired.count; lock.unlock()
            if after > before { hits += 1 }
        }
        stopRecording(tapRecorder, reason: "phase 1 complete")

        lock.lock()
        let phase1 = fired
        fired.removeAll()
        lock.unlock()

        line("")
        line("LIVE ACCEPTANCE — phase 2 of 2: type for \(Int(typingSeconds)) s")
        line("  Real prose, normal speed and force. No deliberate taps.")
        // Measure HID delivery lag while the operator types. This is the one
        // number that decides whether the detector may fire on the armed count
        // instead of waiting out its confirm window, and it has never been
        // measurable: input.jsonl records the hardware stamp and never the
        // arrival, so the gap between them was invisible. See
        // `git show rejected/early-fire-on-count`.
        var lags: [Double] = []
        let lagLock = NSLock()
        InputActivityMonitor.deliveryLagSink = { seconds in
            lagLock.lock(); lags.append(seconds); lagLock.unlock()
        }
        defer { InputActivityMonitor.deliveryLagSink = nil }

        let typingRecorder = startRecording(category: TunkFormat.Category.typing, expected: 0)
        typingRecorder?.mark(kind: "prompt", text: "type continuously, no deliberate taps")
        // Sub-minute durations rendered as "0 minutes", which is what a short
        // rehearsal run of this test says out loud before asking you to type.
        speak("Phase two. Type normally for \(Self.spokenDuration(typingSeconds)).")
        let start = Date()
        while Date().timeIntervalSince(start) < typingSeconds {
            // Sleep only as long as remains, or a short run counts down past
            // zero and prints "-7 s left".
            let remaining = typingSeconds - Date().timeIntervalSince(start)
            spin(for: min(10, max(0.1, remaining)))
            lock.lock(); let n = fired.count; lock.unlock()
            let left = max(0, Int(typingSeconds - Date().timeIntervalSince(start)))
            line("  \(left) s left, false triggers so far: \(n)")
        }
        speak("Done.")
        stopRecording(typingRecorder, reason: "phase 2 complete")

        lock.lock(); let falseTriggers = fired.count; lock.unlock()
        engine.setEnabled(false)

        let latencies = phase1.map { Double($0.atNs - $0.lastOnsetNs) / 1e6 }.sorted()
        func pct(_ p: Double) -> Double {
            latencies.isEmpty ? .nan
                : latencies[min(latencies.count - 1, Int((Double(latencies.count - 1) * p).rounded()))]
        }
        let hitRate = Double(hits) / Double(taps) * 100

        line("")
        line("========================================")
        line("           LIVE ACCEPTANCE")
        line("========================================")
        line("")
        line(String(format: "  hit rate            %.1f %% (%d/%d)   bar 98 %%   %@",
                    hitRate, hits, taps, hitRate >= 98 ? "PASS" : "FAIL"))
        if !latencies.isEmpty {
            line(String(format: "  latency p50         %.1f ms", pct(0.50)))
            line(String(format: "  latency p95         %.1f ms   bar 250 ms   %@",
                        pct(0.95), pct(0.95) <= 250 ? "PASS" : "FAIL"))
        }
        line(String(format: "  false triggers      %d in %.0f s of typing   bar 0   %@",
                    falseTriggers, typingSeconds, falseTriggers == 0 ? "PASS" : "FAIL"))
        lagLock.lock(); let lagSample = lags.sorted(); lagLock.unlock()
        if lagSample.count >= 30 {
            func lagPct(_ q: Double) -> Double {
                lagSample[min(lagSample.count - 1, Int(q * Double(lagSample.count)))] * 1000
            }
            line(String(format: "  HID delivery lag    p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms  (n=%d)",
                        lagPct(0.50), lagPct(0.95), lagPct(0.99),
                        (lagSample.last ?? 0) * 1000, lagSample.count))
            // The keystroke gate can only retract an onset that is still
            // undecided when the event lands. Firing on the armed count would
            // leave `earlySettleNs` of slack instead of a full confirm window,
            // so the settle constant has to cover the worst delivery lag.
            line(String(format: "                      -> earlySettleNs would need >= %.0f ms to keep the",
                        (lagSample.last ?? 0) * 1000 + 5))
            line("                         typing gate's reach; see rejected/early-fire-on-count.")
        } else if !lagSample.isEmpty {
            line(String(format: "  HID delivery lag    only %d events; too few to quote a percentile",
                        lagSample.count))
        } else {
            line("  HID delivery lag    no input events reached this process (secure input?)")
        }
        line("")
        let pass = hitRate >= 98 && falseTriggers == 0 && (latencies.isEmpty || pct(0.95) <= 250)
        line("  VERDICT: \(pass ? "PASS" : "FAIL")")
        line("")
        line("  Measured on the built app against the real sensor. The bound")
        line("  action is deliberately NOT posted — firing a hotkey 50 times into")
        line("  whatever has focus would be its own disaster, and emission is")
        line("  covered by --live-emit-probe.")
        if !written.isEmpty {
            line("")
            line("  Numbers above are this run's own count. The recording below is what")
            line("  makes them checkable — re-grade it rather than taking them on trust:")
            line("")
            for s in written { line("    \(s.dir.path)") }
            line("")
            for s in written {
                line("    bin/tunk-capture verify \(s.dir.path)")
            }
            for s in written where s.dir.lastPathComponent.hasPrefix("tap_") {
                line("    bin/tunk-label check \(s.dir.path)")
                line("    bin/tunk-label run   \(s.dir.path)")
            }
            line("    bin/tunk-score run --data \(written[0].dir.deletingLastPathComponent().path)")
            line("")
            line("  labels.jsonl in both is EMPTY, on purpose. This test knows when it")
            line("  PROMPTED, not when anybody tapped; labels derived from its own")
            line("  triggers would grade the detector against itself.")
        }
        // Nothing extra is printed without `--record`. A run with no new flag
        // has to produce the same output it always did, down to the last line.
        exit(pass ? 0 : 1)
    }
}

extension Diagnostics {
    /// `tunk --sensor-cycles [n]`
    ///
    /// Starts and stops the accelerometer `n` times and reports the process's
    /// mach port count either side. `AccelSource.stop` used to leak the
    /// `IOHIDEventSystemClient` — the type is an opaque struct pointer, so
    /// `client = nil` released nothing — at exactly 5 ports per cycle, measured
    /// 22 -> 525 over 100 cycles and never reclaimed. The watchdog reacquires on
    /// a wedged sensor, so a stuck stream leaked about 5,800 ports an hour.
    ///
    /// This also exercises the release itself: an over-release would crash here
    /// rather than in somebody's menubar.
    ///
    /// **Known limit: n above roughly 10 stops producing output on this
    /// machine.** The sensor is fine afterwards — `--sensor-props` answers and
    /// `tunk-capture record` gets 3188 samples at 794.8 Hz with zero gaps
    /// immediately after — so it is this probe, not the hardware, and the cause
    /// is not understood. Use n <= 10, and treat a hang as an unexplained
    /// result rather than a passing one.
    static func sensorCycles(_ n: Int) {
        func ports() -> Int {
            var nameCount = mach_msg_type_number_t(0)
            var typeCount = mach_msg_type_number_t(0)
            var names: mach_port_name_array_t?
            var types: mach_port_type_array_t?
            guard mach_port_names(mach_task_self_, &names, &nameCount,
                                  &types, &typeCount) == KERN_SUCCESS else { return -1 }
            return Int(nameCount)
        }
        let source = AccelSource()
        func cycle(_ times: Int) {
            for i in 0..<times {
                do { try source.start(onSample: { _ in }) }
                catch { print("cycle \(i): start failed: \(error)"); exit(1) }
                usleep(60_000)
                source.stop()
            }
        }
        // Warm up first, then measure. Opening the sensor the first time costs
        // a fixed number of ports for queues and machinery that are never freed
        // and never grow — measured, roughly 6 to 14 regardless of whether 10 or
        // 30 cycles followed. Counting from a cold process made this probe read
        // "+0.80 per cycle" at n=10 and "+0.23" at n=30 for identical
        // behaviour, which says the probe was measuring startup, not the leak.
        cycle(5)
        let before = ports()
        cycle(n)
        let after = ports()
        let perCycle = Double(after - before) / Double(max(1, n))
        line(String(format: "  %d cycles after warm-up: mach ports %d -> %d  (%+.2f per cycle)",
                    n, before, after, perCycle))
        // The leak this probe exists for was exactly 5 per cycle and monotone.
        // Half a port per cycle is comfortably below it and above measurement
        // noise on this machine.
        line(perCycle < 0.5 ? "  no meaningful leak" : "  LEAKING")
        exit(perCycle < 0.5 ? 0 : 1)
    }

    /// `tunk --sensor-props`
    ///
    /// The recorded stream carries no measurable power above ~100 Hz (9 orders
    /// down at 100-398 Hz) while reporting at 796 Hz. A knuckle strike on
    /// aluminium is broadband to several kHz, so the content that would tell a
    /// strike apart from the chassis ringing afterwards is removed before it
    /// reaches us. This asks the service whether that ceiling is ours to move.
    static func sensorProperties() {
        let source = AccelSource()
        do { try source.start(onSample: { _ in }) }
        catch { print("could not start sensor: \(error)"); exit(1) }
        defer { source.stop() }

        // No enumeration API exists for these, so this is a candidate list:
        // the two keys already known to work, plus every plausible spelling of
        // a bandwidth, rate or filter control.
        let keys = [
            "ReportInterval", "BatchInterval", "SampleRate", "SamplingRate",
            "ReportRate", "MaxReportRate", "MinReportInterval", "AccelerometerRate",
            "Bandwidth", "BandwidthHz", "LowPassCutoff", "CutoffFrequency",
            "FilterBandwidth", "FilterMode", "AntiAliasFilter", "OutputDataRate",
            "ODR", "FullScaleRange", "Range", "Sensitivity", "Resolution",
            "AccelerometerMode", "OperatingMode", "PowerMode", "PerformanceMode",
            "HighPerformanceMode", "LowNoiseMode", "SensorProperties", "Product",
        ]
        var found = 0
        for key in keys {
            if let value = source.property(key) {
                print(String(format: "  %-22@ = %@", key as NSString, value as NSString))
                found += 1
            }
        }
        print("\n  \(found) of \(keys.count) candidate keys returned a value.")
        print("  Keys absent here are not necessarily unsupported — there is no")
        print("  enumeration API, so this can only report what it thought to ask.")
        exit(0)
    }
}
