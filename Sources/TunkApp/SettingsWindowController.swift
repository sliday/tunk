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
        panel.isOnScreen = true
        if startCalibration { panel.showCalibration = true }
    }

    // MARK: - visibility

    // The tap monitor polls the engine 60 times a second. It must run only
    // while the panel is actually visible, and the window is the only thing
    // that knows: this window is kept alive between opens, so closing it orders
    // it out without unmounting the SwiftUI view, and `onDisappear` never
    // fires. Wiring the timer to the view's lifecycle left it running forever
    // after the first open.

    func windowWillClose(_ notification: Notification) {
        panel.isOnScreen = false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        panel.isOnScreen = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        panel.isOnScreen = window.isVisible
    }

    /// Also covers the window being fully hidden behind another one, where the
    /// trace is redrawing pixels nobody can see.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        panel.isOnScreen = window.isVisible && window.occlusionState.contains(.visible)
    }
}
