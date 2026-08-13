import AppKit
import SwiftUI
import TunkEmit

/// `tunk --dump-panel <dir>` renders the settings panel to PNGs, one per action
/// kind, in light and dark. The same idea as `--dump-glyphs`: a reviewer should
/// be able to look at the artifact rather than at a description of it, without
/// granting Accessibility to a build first.
///
/// It renders against a throwaway defaults suite, so running it cannot disturb
/// the settings the operator is using. It never runs a Shortcut — the panel
/// lists them, which is read-only.
enum PanelDump {
    static func run(into directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let suite = "dev.tunk.paneldump." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let settings = AppSettings(suiteName: suite)
        let engine = Engine(settings: settings)
        let panel = PanelModel()
        panel.refreshShortcuts()

        for kind in TunkAction.Kind.allCases {
            settings.actionKind = kind
            for dark in [false, true] {
                let name = "panel-\(kind.rawValue)-\(dark ? "dark" : "light").png"
                let file = url.appendingPathComponent(name)
                let view = SettingsView(settings: settings, engine: engine, panel: panel)
                guard let data = render(view, dark: dark) else {
                    FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                    continue
                }
                try? data.write(to: file)
                FileHandle.standardOutput.write(Data("wrote \(file.path)\n".utf8))
            }
        }
    }

    /// Hosts the panel in an offscreen window so it picks up a real appearance,
    /// lays it out, then caches the display into a bitmap.
    private static func render<V: View>(_ view: V, dark: Bool) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 452, height: 900)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host

        // Two passes: the first gives SwiftUI a chance to measure its own
        // content, the second lays out at the height that measurement asked for.
        host.layoutSubtreeIfNeeded()
        let height = max(host.fittingSize.height, 1)
        host.frame = NSRect(x: 0, y: 0, width: 452, height: height)
        window.setContentSize(NSSize(width: 452, height: height))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
