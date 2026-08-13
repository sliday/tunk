import AppKit
import SwiftUI

/// Hosts the SwiftUI panel in a plain utility window. Kept alive between opens
/// so reopening shows the panel already settled — no entrance animation on a
/// window the user has seen before.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let panel = PanelModel()

    init(settings: AppSettings, engine: Engine) {
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
        // The user may have added a Shortcut since the last time this opened.
        // Listing is read-only and measured at ~10 ms; it runs nothing.
        panel.refreshShortcuts()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if startCalibration { panel.showCalibration = true }
    }
}
