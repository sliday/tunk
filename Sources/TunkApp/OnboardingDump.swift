import AppKit
import SwiftUI
import TunkEmit

/// `tunk --dump-onboarding <dir>` renders the first-run window to PNGs: every
/// step, light and dark, with the permissions forced to each combination on
/// the step that shows them, plus the relaunch offer and the "felt it" state.
///
/// Same rules as `PanelDump`: a throwaway defaults suite, no engine started,
/// nothing granted or prompted. What the calling terminal has been granted
/// does not reach the render, because the model reads permissions from an
/// injected source.
enum OnboardingDump {
    static func run(into directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let suite = "dev.tunk.onboardingdump." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(suiteName: suite)

        func write(_ name: String, _ model: OnboardingModel, dark: Bool) {
            let file = url.appendingPathComponent("onboarding-\(name)-\(dark ? "dark" : "light").png")
            guard let data = render(OnboardingView(model: model), dark: dark) else {
                FileHandle.standardError.write(Data("could not render \(file.lastPathComponent)\n".utf8))
                return
            }
            try? data.write(to: file)
            FileHandle.standardOutput.write(Data("wrote \(file.path)\n".utf8))
        }

        for dark in [false, true] {
            // Step 1 has no state.
            write("1-what", OnboardingModel(settings: settings, engine: nil,
                                            startAt: .whatItDoes), dark: dark)

            // Step 2, one render per permission combination.
            let combos: [(String, PermissionState)] = [
                ("none", PermissionState(accessibility: false, inputMonitoring: false)),
                ("accessibility-only", PermissionState(accessibility: true, inputMonitoring: false)),
                ("input-only", PermissionState(accessibility: false, inputMonitoring: true)),
                ("both", PermissionState(accessibility: true, inputMonitoring: true)),
            ]
            for (label, state) in combos {
                let model = OnboardingModel(settings: settings, engine: nil,
                                            startAt: .permissions,
                                            permissionSource: { state })
                write("2-permissions-\(label)", model, dark: dark)
            }
            // Both granted, and Input Monitoring arrived while the window was
            // open: the relaunch offer replaces the note.
            let relaunch = OnboardingModel(
                settings: settings, engine: nil, startAt: .permissions,
                permissionSource: { PermissionState(accessibility: true, inputMonitoring: true) })
            relaunch.forceRelaunchOffer()
            write("2-permissions-relaunch", relaunch, dark: dark)

            // Step 3 waiting, and a beat after a double-tap landed. Both with
            // the default hotkey binding, which is the VoiceInk path.
            let granted = { PermissionState(accessibility: true, inputMonitoring: true) }
            settings.setActionKind(.hotkey, for: 2)
            write("3-try-waiting", OnboardingModel(settings: settings, engine: nil,
                                                   startAt: .tryIt,
                                                   permissionSource: granted), dark: dark)
            let felt = OnboardingModel(settings: settings, engine: nil, startAt: .tryIt,
                                       permissionSource: granted)
            felt.forceFelt(count: 2)
            write("3-try-felt", felt, dark: dark)

            // And with nothing bound, since that is what a user who skipped
            // Settings sees.
            settings.setActionKind(.none, for: 2)
            write("3-try-unbound", OnboardingModel(settings: settings, engine: nil,
                                                   startAt: .tryIt,
                                                   permissionSource: granted), dark: dark)
            settings.setActionKind(.hotkey, for: 2)
        }
    }

    /// Hosts the view in an offscreen window at the real window's size so it
    /// picks up an appearance, then caches the display into a bitmap.
    private static func render<V: View>(_ view: V, dark: Bool) -> Data? {
        let size = OnboardingView.size
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
