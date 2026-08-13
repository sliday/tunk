import AppKit

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
if arguments.contains("--live-emit-probe") {
    app.setActivationPolicy(.accessory)
    Diagnostics.liveEmitProbe()
}
if arguments.contains("--config-trace") {
    app.setActivationPolicy(.accessory)
    Diagnostics.configTrace()
}
if let index = arguments.firstIndex(of: "--dump-panel") {
    let directory = index + 1 < arguments.count ? arguments[index + 1] : "."
    app.setActivationPolicy(.accessory)
    PanelDump.run(into: directory)
    exit(0)
}

let delegate = AppDelegate(openSettingsOnLaunch: arguments.contains("--settings"),
                          openCalibrationOnLaunch: arguments.contains("--calibrate"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
