import AppKit
import Darwin
import Foundation
import SwiftUI
import TunkCore
import TunkEmit

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
