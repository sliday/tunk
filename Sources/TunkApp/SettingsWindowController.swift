import AppKit
import SwiftUI

/// Hosts the SwiftUI panel in a plain utility window. Kept alive between opens
/// so reopening shows the panel already settled — no entrance animation on a
/// window the user has seen before.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let panel = PanelModel()

    private let engine: Engine

    init(settings: AppSettings, engine: Engine) {
        self.engine = engine
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 452, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        super.init()

        // Vertically resizable, fixed width: the panel is a single column and
        // stretching it sideways would only strand the readouts.
        window.contentMinSize = NSSize(width: 452, height: 380)
        window.contentMaxSize = NSSize(width: 452, height: 4000)
        window.title = "Tunk"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("dev.tunk.settings")

        let root = SettingsView(settings: settings, engine: engine, panel: panel)
        window.contentView = NSHostingView(rootView: root)
        window.center()
    }

    func present(startCalibration: Bool) {
        // The user may have added, renamed or deleted a Shortcut since the last
        // time this opened. Listing is read-only and ~10 ms; it runs nothing.
        engine.refreshShortcutCatalog()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panel.monitor.start(engine: engine)
        if startCalibration { panel.showCalibration = true }
    }

    /// Closes the panel the way the user's red button does, for `--cpu-probe`.
    func dismiss() { window.close() }

    /// For `--cpu-probe`, so a phase that proves nothing says so.
    var debugState: String {
        "polling=\(panel.monitor.isRunning) visible=\(window.isVisible)"
    }

    // MARK: - visibility

    // The tap monitor polls the engine 60 times a second, and this is the only
    // place it is stopped. The window has to do it: it is kept alive between
    // opens, so closing it orders it out without unmounting the SwiftUI view,
    // and once it is closed SwiftUI stops running updates for that hierarchy —
    // so neither `onDisappear` nor an `onChange` on a visibility flag ever
    // arrives. Both were tried and both left it polling. Measured with
    // `tunk --cpu-probe`.
    //
    // Occlusion is deliberately not used as a trigger. `occlusionState` reports
    // the panel as occluded even while it is on screen under the probe, so
    // stopping on it would freeze the trace in front of a user who is watching
    // it. Closing and miniaturising are unambiguous; being behind another
    // window is not.

    func windowWillClose(_ notification: Notification) {
        panel.monitor.stop()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        panel.monitor.stop()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        panel.monitor.start(engine: engine)
    }
}
