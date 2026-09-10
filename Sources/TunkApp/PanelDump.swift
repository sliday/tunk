import AppKit
import SwiftUI
import TunkCore
import TunkEmit

/// `tunk --dump-panel <dir>` renders the settings window to PNGs: every
/// section, in light and dark, plus the states a reviewer cannot reach from a
/// terminal that already holds both grants. The same idea as `--dump-glyphs`:
/// a reviewer should be able to look at the artifact rather than at a
/// description of it, without granting Accessibility to a build first.
///
/// It renders against a throwaway defaults suite, so running it cannot disturb
/// the settings the operator is using. It never runs a Shortcut — the panel
/// lists them, which is read-only.
///
/// Each PNG's rendered height is printed next to its path. The General page is
/// held to 680 pt without scrolling; the number on stdout is the measurement.
enum PanelDump {
    static func run(into directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let suite = "dev.tunk.paneldump." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let settings = AppSettings(suiteName: suite)
        let engine = Engine(settings: settings)
        engine.refreshShortcutCatalog()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // Both grants forced on, whatever the calling terminal holds, so every
        // section renders the way a set-up machine shows it. The one render
        // that wants the permission card forces the opposite below.
        let granted = PermissionState(accessibility: true, inputMonitoring: true)

        // Every section, shipped defaults, double tap bound to a hotkey.
        settings.setActionKind(.hotkey, for: 2)
        settings.setActionKind(.none, for: 1)
        for section in SettingsSection.allCases {
            write("panel-\(section.rawValue)", into: url,
                  settings: settings, engine: engine, section: section, permissions: granted)
        }

        // The permission card, on the page it appears on. Forced rather than
        // read: a dump made from a terminal that has both grants would never
        // show it otherwise.
        write("panel-nopermissions", into: url, settings: settings, engine: engine,
              section: .general,
              permissions: PermissionState(accessibility: false, inputMonitoring: false))
        write("panel-onepermission", into: url, settings: settings, engine: engine,
              section: .general,
              permissions: PermissionState(accessibility: true, inputMonitoring: false))

        // Actions, one per kind. Both rows to the same kind, so one render shows
        // the double-tap row and the single-tap row with its caution side by side.
        for kind in TunkAction.Kind.allCases {
            settings.setActionKind(kind, for: 2)
            settings.setActionKind(kind, for: 1)
            write("panel-actions-\(kind.rawValue)", into: url,
                  settings: settings, engine: engine, section: .actions, permissions: granted)
        }
        settings.setActionKind(.hotkey, for: 2)
        settings.setActionKind(.none, for: 1)

        renderMigrationCard(into: url)

        // One pass with the resonator switched on. This is the only place the
        // switch's WIRING is checked end to end: the Advanced page's "effective
        // threshold" readout comes from `engine.effectiveConfig`, so if the
        // derivation in `AppSettings.effectiveConfig` were not reaching the
        // detector this render would still say 0.032. A switch that silently
        // does nothing is the failure this project keeps finding, and reading
        // the number off the artifact is how it gets caught. General gets the
        // same pass, for the plain-words line that points at Advanced.
        settings.experimentalResonator = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        write("panel-resonator", into: url, settings: settings, engine: engine,
              section: .advanced, permissions: granted)
        write("panel-resonator-general", into: url, settings: settings, engine: engine,
              section: .general, permissions: granted)
        settings.experimentalResonator = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // One extra pass at the gate slider's floor, so the caution that only
        // appears at low values is inspectable rather than merely written.
        settings.config.gateWindowNs = Int64(SettingsView.gateFloorMs) * 1_000_000
        write("panel-gatefloor", into: url, settings: settings, engine: engine,
              section: .calibration, permissions: granted)

        // And one at the far end of the tap-spacing slider, where the detector
        // clamps what the panel stores. Both halves of that story have to be on
        // screen: the issue the clamp reported, and a slider readout that names
        // the value in force instead of only the one that was dragged to.
        settings.config.gateWindowNs = DetectorConfig.default.gateWindowNs
        settings.config.maxInterTapNs = 700_000_000
        write("panel-clamped", into: url, settings: settings, engine: engine,
              section: .advanced, permissions: granted, showAdvanced: true)
    }

    /// One state, light and dark.
    private static func write(_ stem: String, into url: URL,
                              settings: AppSettings, engine: Engine,
                              section: SettingsSection, permissions: PermissionState,
                              showAdvanced: Bool = false) {
        for dark in [false, true] {
            let name = "\(stem)-\(dark ? "dark" : "light").png"
            let file = url.appendingPathComponent(name)
            let panel = PanelModel()
            panel.section = section
            let view = SettingsView(settings: settings, engine: engine, panel: panel,
                                    showAdvanced: showAdvanced, forcedPermissions: permissions)
            guard let (data, height) = render(view, dark: dark) else {
                FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                continue
            }
            try? data.write(to: file)
            FileHandle.standardOutput.write(
                Data("wrote \(file.path) (\(Int(height)) pt tall)\n".utf8))
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
        let granted = PermissionState(accessibility: true, inputMonitoring: true)
        // The card, with every note verbatim, lives under Advanced; General
        // gets one plain sentence pointing there. Both rendered, so the critic
        // can check that the detector vocabulary stays off General.
        write("panel-migration", into: url, settings: settings, engine: engine,
              section: .advanced, permissions: granted)
        write("panel-migration-general", into: url, settings: settings, engine: engine,
              section: .general, permissions: granted)
    }

    /// Hosts the panel in an offscreen window so it picks up a real appearance,
    /// lays it out, then caches the display into a bitmap. Returns the PNG and
    /// the height the content asked for.
    private static func render<V: View>(_ view: V, dark: Bool) -> (Data, CGFloat)? {
        let width = SettingsView.width
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)

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
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.setContentSize(NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, height)
    }
}
