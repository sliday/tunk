import AppKit
import Foundation
import IOKit.hid
import ServiceManagement
import TunkCore
import TunkEmit

/// The one place settings live. The panel writes here, the engine reads here,
/// and the detector is handed exactly this `DetectorConfig`. Nothing anywhere
/// else reaches for `DetectorConfig.default` at runtime — that constant is only
/// the seed for a first launch and the target of "Reset to defaults".
final class AppSettings: ObservableObject {
    private enum Key {
        static let config = "detectorConfig"
        /// Written by builds that predate `TunkAction`: a bare hotkey string.
        /// Read once, at load, to migrate. Never written again.
        static let legacyHotkey = "hotkey"
        static let action = "action"
        static let hotkeyDraft = "hotkeyDraft"
        static let shortcutDraft = "shortcutDraft"
        static let enabled = "enabled"
    }

    /// A named suite, not the bundle's own domain, so the bare SwiftPM binary
    /// and the .app bundle read and write the same settings instead of drifting
    /// apart during development.
    static let suiteName = "dev.tunk.settings"
    private let defaults: UserDefaults

    /// Called on the main thread whenever the detector config changes, however
    /// it changed. The engine hooks this.
    var onConfigChange: ((DetectorConfig) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onActionChange: ((TunkAction) -> Void)?

    @Published var config: DetectorConfig {
        didSet {
            guard config != oldValue else { return }
            persist(config, key: Key.config)
            onConfigChange?(config)
        }
    }

    /// What a confirmed double-tap does. The one value the engine reads; the
    /// panel writes only this and the two drafts below, which feed it.
    @Published var action: TunkAction {
        didSet {
            guard action != oldValue else { return }
            persist(action, key: Key.action)
            onActionChange?(action)
        }
    }

    /// The combination to use when the action kind is `.hotkey`. Kept while the
    /// user is in another mode so switching to "Run a Shortcut" and back does
    /// not lose the shortcut they spent a minute picking. UI memory only — the
    /// engine never reads it, and it is written into `action` the moment the
    /// kind matches.
    @Published var hotkeyDraft: HotkeySpec {
        didSet {
            guard hotkeyDraft != oldValue else { return }
            defaults.set(hotkeyDraft.description, forKey: Key.hotkeyDraft)
            if action.kind == .hotkey { action = .hotkey(hotkeyDraft) }
        }
    }

    /// Same idea for the chosen Shortcut's name.
    @Published var shortcutDraft: String {
        didSet {
            guard shortcutDraft != oldValue else { return }
            defaults.set(shortcutDraft, forKey: Key.shortcutDraft)
            if action.kind == .shortcut { action = .shortcut(name: shortcutDraft) }
        }
    }

    /// The picker's value. Switching kind rebuilds `action` from the draft for
    /// that kind, so nothing is invented and nothing is lost.
    var actionKind: TunkAction.Kind {
        get { action.kind }
        set {
            switch newValue {
            case .hotkey:   action = .hotkey(hotkeyDraft)
            case .shortcut: action = .shortcut(name: shortcutDraft)
            case .none:     action = .none
            }
        }
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Key.enabled)
            onEnabledChange?(enabled)
        }
    }

    @Published private(set) var launchAtLoginError: String?

    /// - Parameter suiteName: the defaults suite to read and write. Only
    ///   `--dump-panel` passes anything else, so a diagnostic render cannot
    ///   touch the settings the operator is actually running with.
    init(suiteName: String = AppSettings.suiteName) {
        let d = UserDefaults(suiteName: suiteName) ?? .standard
        defaults = d
        config = AppSettings.load(DetectorConfig.self, key: Key.config, from: d) ?? .default
        let loaded = AppSettings.loadAction(from: d)
        action = loaded
        // Seed the drafts from whatever was loaded, so the first switch between
        // kinds offers the user's own value rather than a shipped default.
        hotkeyDraft = loaded.hotkeySpec
            ?? d.string(forKey: Key.hotkeyDraft).flatMap { try? HotkeySpec(parsing: $0) }
            ?? .recommendedDefault
        shortcutDraft = loaded.shortcutName ?? d.string(forKey: Key.shortcutDraft) ?? ""
        enabled = d.object(forKey: Key.enabled) as? Bool ?? true
    }

    /// Loads the action, migrating settings written before `TunkAction` existed.
    /// The rules live in `TunkAction.restored`, in TunkEmit, where they are
    /// under test; this reads the two keys and hands them over.
    private static func loadAction(from d: UserDefaults) -> TunkAction {
        TunkAction.restored(actionData: d.data(forKey: Key.action),
                            legacyHotkeyText: d.string(forKey: Key.legacyHotkey))
    }

    func resetDetectionToDefaults() {
        var next = DetectorConfig.default
        // Calibration is a property of this machine and this user's hand, not a
        // tuning knob. Resetting the sliders must not throw it away.
        next.calibratedThreshold = config.calibratedThreshold
        config = next
    }

    // MARK: - launch at login

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Only meaningful for a real bundle. Running the bare SwiftPM binary, the
    /// registration fails; we report that instead of pretending it worked.
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
            objectWillChange.send()
            return true
        } catch {
            launchAtLoginError = "Launch at login needs Tunk to run from a real app bundle "
                + "(\(error.localizedDescription))"
            objectWillChange.send()
            return false
        }
    }

    // MARK: - storage

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String,
                                           from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// What macOS has actually granted us. Tunk refuses to arm without both, because
/// a running detector that cannot see keystrokes cannot suppress typing, and
/// typing false positives are the make-or-break metric.
struct PermissionState: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool

    var ready: Bool { accessibility && inputMonitoring }

    static func current() -> PermissionState {
        PermissionState(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
    }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func promptInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilityPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}
