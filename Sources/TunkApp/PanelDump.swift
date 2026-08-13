import AppKit
import SwiftUI
import TunkCore
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
        engine.refreshShortcutCatalog()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        for kind in TunkAction.Kind.allCases {
            // Both rows to the same kind, so one render shows the double-tap row
            // and the single-tap row with its caution side by side.
            settings.setActionKind(kind, for: 2)
            settings.setActionKind(kind, for: 1)
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

        renderMigrationCard(into: url)

        // One extra pass at the gate slider's floor, so the caution that only
        // appears at low values is inspectable rather than merely written.
        settings.setActionKind(.hotkey, for: 2)
        settings.setActionKind(.none, for: 1)
        settings.config.gateWindowNs = Int64(SettingsView.gateFloorMs) * 1_000_000
        for dark in [false, true] {
            let file = url.appendingPathComponent("panel-gatefloor-\(dark ? "dark" : "light").png")
            let view = SettingsView(settings: settings, engine: engine, panel: panel)
            guard let data = render(view, dark: dark) else { continue }
            try? data.write(to: file)
            FileHandle.standardOutput.write(Data("wrote \(file.path)\n".utf8))
        }

        // And one at the far end of the tap-spacing slider, where the detector
        // clamps what the panel stores. Both halves of that story have to be on
        // screen: the issue the clamp reported, and a slider readout that names
        // the value in force instead of only the one that was dragged to.
        settings.config.gateWindowNs = DetectorConfig.default.gateWindowNs
        settings.config.maxInterTapNs = 700_000_000
        for dark in [false, true] {
            let file = url.appendingPathComponent("panel-clamped-\(dark ? "dark" : "light").png")
            let view = SettingsView(settings: settings, engine: engine, panel: panel,
                                    showAdvanced: true)
            guard let data = render(view, dark: dark) else { continue }
            try? data.write(to: file)
            FileHandle.standardOutput.write(Data("wrote \(file.path)\n".utf8))
        }
    }

    /// Seeds a throwaway suite with the settings an earlier build left behind,
    /// then renders the panel that a user upgrading into this build would see.
    ///
    /// This is the only path that exercises the migration through `AppSettings`
    /// rather than through `SettingsMigration` alone — the app target cannot be
    /// imported by the tests, so without this the wiring is only inspected.
    private static func renderMigrationCard(into url: URL) {
        let suite = "dev.tunk.paneldump.migration." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return }

        // The owner's actual persisted values: a gate below the safe floor, a
        // join window wider than the confirm window, and a confirm window from
        // before the default moved.
        var stale = DetectorConfig.default
        stale.gateWindowNs = 110_000_000
        stale.maxInterTapNs = 400_000_000
        stale.confirmWindowNs = 180_000_000
        guard let data = try? JSONEncoder().encode(stale) else { return }
        defaults.set(data, forKey: "detectorConfig")

        let settings = AppSettings(suiteName: suite)
        guard !settings.migrationNotes.isEmpty else {
            FileHandle.standardError.write(Data("migration produced no notes\n".utf8))
            return
        }
        for note in settings.migrationNotes {
            FileHandle.standardOutput.write(Data("migrated: \(note)\n".utf8))
        }

        let engine = Engine(settings: settings)
        for dark in [false, true] {
            let file = url.appendingPathComponent("panel-migration-\(dark ? "dark" : "light").png")
            let view = SettingsView(settings: settings, engine: engine, panel: PanelModel())
            guard let data = render(view, dark: dark) else { continue }
            try? data.write(to: file)
            FileHandle.standardOutput.write(Data("wrote \(file.path)\n".utf8))
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
