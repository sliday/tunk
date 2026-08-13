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
        let controller = SettingsWindowController(settings: settings, engine: engine)

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

        let closedBefore = measure(seconds: seconds) { }
        line(String(format: "1. panel never opened : %6.2f %%", closedBefore))

        let open = measure(seconds: seconds) {
            controller.present(startCalibration: false)
        }
        line(String(format: "2. panel open         : %6.2f %%", open))

        let closedAfter = measure(seconds: seconds) {
            NSApp.windows.first { $0.title == "Tunk" }?.close()
        }
        line(String(format: "3. panel closed again : %6.2f %%", closedAfter))

        // A stopped timer should put phase 3 back near phase 1. Allowing half
        // the open-panel cost is generous and still catches the real leak,
        // which left phase 3 indistinguishable from phase 2.
        let leaked = closedAfter > closedBefore + max(0.5, (open - closedBefore) * 0.5)
        line("")
        line(leaked
             ? "LEAK: closing the panel did not stop the monitor."
             : "OK: closing the panel returned CPU to its idle level.")
        exit(leaked ? 1 : 0)
    }

    /// Runs `setup`, then spins the main run loop for `seconds` and reports the
    /// CPU this process burned over that window.
    private static func measure(seconds: Double, setup: () -> Void) -> Double {
        setup()
        // Let the change take effect before the clock starts.
        spin(for: 0.5)
        let t0 = cpuSeconds()
        let w0 = Date()
        spin(for: seconds)
        let cpu = cpuSeconds() - t0
        let wall = Date().timeIntervalSince(w0)
        return wall > 0 ? (cpu / wall) * 100 : 0
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
