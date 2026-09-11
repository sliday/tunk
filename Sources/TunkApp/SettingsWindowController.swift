import AppKit
import SwiftUI

/// Hosts the SwiftUI panel in a plain utility window. Kept alive between opens
/// so reopening shows the panel already settled — no entrance animation on a
/// window the user has seen before.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let panel = PanelModel()

    private let engine: Engine

    /// What the sidebar's Set up Tunk… does. The app delegate owns the
    /// first-run window, so it hands this in after construction.
    var openSetup: (() -> Void)? {
        get { panel.openSetup }
        set { panel.openSetup = newValue }
    }

    init(settings: AppSettings, engine: Engine) {
        self.engine = engine
        let width = SettingsView.width
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init()

        // Vertically resizable, fixed width: the content column is sized for
        // one card width and stretching it sideways would only strand the
        // readouts. The sidebar runs up under the title bar, System Settings
        // style, so the title bar is transparent and its text hidden.
        window.contentMinSize = NSSize(width: width, height: 380)
        window.contentMaxSize = NSSize(width: width, height: 4000)
        window.title = "Tunk"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        // New name with the new width, so a frame saved by the 452 pt panel
        // is not restored and then fought over by the size constraints.
        window.setFrameAutosaveName("dev.tunk.settings.sidebar")

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
        if startCalibration {
            // Land on the page the sheet belongs to, so dismissing it leaves
            // the user next to the Calibrate… button and the learned value.
            panel.section = .calibration
            panel.showCalibration = true
        }
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
        endAnyCalibration()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        panel.monitor.stop()
        // Not `endAnyCalibration()`. Miniaturising is not abandoning: the sheet
        // is still there when the window comes back, and the timer restarts in
        // `windowDidDeminiaturize`. Only closing gives up the calibration.
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        panel.monitor.start(engine: engine)
    }

    /// Give the config back if the window is closed while the calibration sheet
    /// is up.
    ///
    /// `CalibrationView` tears down in `.onDisappear`, and this file's own rule
    /// at the top of SettingsView says why that is not enough: `onDisappear`
    /// never fires for a hosted view whose window is merely ordered out, and
    /// "anything that must stop when the panel closes has to be stopped by the
    /// thing that closed it".
    ///
    /// The consequence was not a leaked timer but a wedged app. `beginCalibration`
    /// hands the live config to `configBeforeCalibration`, and while that is set
    /// `Engine.apply(config:)` diverts EVERY write into the saved copy instead of
    /// the detector. Close the window mid-calibration and no slider does anything
    /// afterwards, with nothing on screen to explain it and no way back short of
    /// quitting.
    private func endAnyCalibration() {
        guard panel.showCalibration else { return }
        panel.showCalibration = false
        engine.endCalibration(commit: nil)
    }
}
