import AppKit
import TunkFormat

// LSUIElement lives in the bundle's Info.plist (see dist/Info.plist). The
// activation policy is also set in code so that running the bare SwiftPM binary
// during development behaves the same way: no dock icon, no menu bar takeover,
// no main window.
let app = NSApplication.shared

// Diagnostics, for a reviewer who needs to look at the artifact rather than a
// description of it. Neither flag changes normal behaviour.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--dump-glyphs") {
    let directory = index + 1 < arguments.count ? arguments[index + 1] : "."
    GlyphDump.run(into: directory)
    exit(0)
}
if let i = arguments.firstIndex(of: "--sensor-cycles") {
    let n = i + 1 < arguments.count ? Int(arguments[i + 1]) ?? 20 : 20
    app.setActivationPolicy(.accessory)
    Diagnostics.sensorCycles(n)
}
if let i = arguments.firstIndex(of: "--reacquire-probe") {
    let n = i + 1 < arguments.count ? Int(arguments[i + 1]) ?? 10 : 10
    app.setActivationPolicy(.accessory)
    Diagnostics.reacquireProbe(cycles: n)
}
if arguments.contains("--sleep-gate-probe") {
    app.setActivationPolicy(.accessory)
    Diagnostics.sleepGateProbe()
}
if arguments.contains("--sensor-props") {
    app.setActivationPolicy(.accessory)
    Diagnostics.sensorProperties()
}
if let index = arguments.firstIndex(of: "--cpu-probe") {
    let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 10 : 10
    app.setActivationPolicy(.accessory)
    Diagnostics.cpuProbe(seconds: seconds)
}
if let index = arguments.firstIndex(of: "--emit-probe") {
    let n = index + 1 < arguments.count ? Int(arguments[index + 1]) ?? 200 : 200
    app.setActivationPolicy(.accessory)
    Diagnostics.emitProbe(iterations: n)
}
if let index = arguments.firstIndex(of: "--latency-probe") {
    let n = index + 1 < arguments.count ? Int(arguments[index + 1]) ?? 30 : 30
    app.setActivationPolicy(.accessory)
    Diagnostics.latencyProbe(iterations: n)
}
if let index = arguments.firstIndex(of: "--collect-taps") {
    // Run the app normally, but keep the seconds around every tap-shaped
    // transient. Removes the need for a scripted recording session to gather a
    // tap PROFILE; it cannot replace prompted sessions for detection rate.
    let dir = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-")
        ? arguments[index + 1] : "data/raw"
    PassiveCollection.enable(at: dir)
}
if let index = arguments.firstIndex(of: "--acceptance") {
    // The PRD's final sign-off, run on the built app against the real sensor.
    let taps = index + 1 < arguments.count ? Int(arguments[index + 1]) ?? 50 : 50
    let typing = index + 2 < arguments.count ? Double(arguments[index + 2]) ?? 300 : 300

    /// Value after `flag`, or nil. A missing value, or another flag where the
    /// value should be, is an error rather than a silent default — this decides
    /// where files get written and which surface they claim.
    func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag) else { return nil }
        guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else {
            FileHandle.standardError.write(Data("\(flag) needs a value\n".utf8))
            exit(2)
        }
        return arguments[i + 1]
    }

    // No --record, no writing. There is deliberately no default path: data/ is
    // the frozen corpus, and a default is how a run lands inside it by accident.
    var recording: Diagnostics.AcceptanceRecording?
    if let path = value(after: "--record") {
        var surface = Surface.desk
        let stated = value(after: "--surface")
        if let stated {
            guard let s = Surface(rawValue: stated) else {
                FileHandle.standardError.write(Data(
                    "--surface must be one of \(Surface.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                exit(2)
            }
            surface = s
        }
        var category = Category.tapDeck
        if let stated = value(after: "--tap-category") {
            guard let c = Category(rawValue: stated), c.isTapCategory else {
                FileHandle.standardError.write(Data(
                    "--tap-category must be tap_palmrest, tap_deck or tap_bottom\n".utf8))
                exit(2)
            }
            category = c
        }
        recording = Diagnostics.AcceptanceRecording(
            root: URL(fileURLWithPath: path, isDirectory: true),
            surface: surface,
            tapCategory: category,
            surfaceWasDefaulted: stated == nil)
    } else if arguments.contains("--surface") || arguments.contains("--tap-category") {
        FileHandle.standardError.write(Data(
            "--surface and --tap-category only mean something with --record\n".utf8))
        exit(2)
    }

    app.setActivationPolicy(.accessory)
    Diagnostics.acceptance(taps: taps, typingSeconds: typing, recording: recording)
}
if arguments.contains("--haptic-probe") {
    app.setActivationPolicy(.accessory)
    Diagnostics.hapticProbe()
}
if arguments.contains("--live-emit-probe") {
    app.setActivationPolicy(.accessory)
    Diagnostics.liveEmitProbe()
}
if arguments.contains("--config-trace") {
    app.setActivationPolicy(.accessory)
    Diagnostics.configTrace()
}
if arguments.contains("--calibration-config-probe") {
    app.setActivationPolicy(.accessory)
    Diagnostics.calibrationConfigProbe()
}
if let index = arguments.firstIndex(of: "--dump-panel") {
    let directory = index + 1 < arguments.count ? arguments[index + 1] : "."
    app.setActivationPolicy(.accessory)
    PanelDump.run(into: directory)
    exit(0)
}

if let index = arguments.firstIndex(of: "--dump-onboarding") {
    let directory = index + 1 < arguments.count ? arguments[index + 1] : "."
    app.setActivationPolicy(.accessory)
    OnboardingDump.run(into: directory)
    exit(0)
}

// `--onboarding` opens the first-run window even after it was completed;
// `--onboarding-step N` (1-3) is what a relaunch passes to land on the same
// step. Neither writes anything.
var onboardingStep: OnboardingModel.Step?
if arguments.contains("--onboarding") {
    var step = OnboardingModel.Step.whatItDoes
    if let index = arguments.firstIndex(of: "--onboarding-step"),
       index + 1 < arguments.count,
       let n = Int(arguments[index + 1]),
       let parsed = OnboardingModel.Step(rawValue: n - 1) {
        step = parsed
    }
    onboardingStep = step
}

let delegate = AppDelegate(openSettingsOnLaunch: arguments.contains("--settings"),
                          openCalibrationOnLaunch: arguments.contains("--calibrate"),
                          openOnboardingAt: onboardingStep)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
