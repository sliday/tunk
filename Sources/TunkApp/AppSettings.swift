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
        static let hotkey = "hotkey"
        static let enabled = "enabled"
    }

    /// A named suite, not the bundle's own domain, so the bare SwiftPM binary
    /// and the .app bundle read and write the same settings instead of drifting
    /// apart during development.
    static let suiteName = "dev.tunk.settings"
    private let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard

    /// Called on the main thread whenever the detector config changes, however
    /// it changed. The engine hooks this.
    var onConfigChange: ((DetectorConfig) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onHotkeyChange: ((HotkeySpec) -> Void)?

    @Published var config: DetectorConfig {
        didSet {
            guard config != oldValue else { return }
            persist(config, key: Key.config)
            onConfigChange?(config)
        }
    }

    /// Stored as the text form ("Ctrl+Opt+Cmd+;") so the value in `defaults` is
    /// the same string the user pastes into VoiceInk.
    @Published var hotkey: HotkeySpec {
        didSet {
            guard hotkey != oldValue else { return }
            defaults.set(hotkey.description, forKey: Key.hotkey)
            onHotkeyChange?(hotkey)
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

    init() {
        let d = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        config = AppSettings.load(DetectorConfig.self, key: Key.config, from: d) ?? .default
        hotkey = (d.string(forKey: Key.hotkey).flatMap { try? HotkeySpec(parsing: $0) })
            ?? .recommendedDefault
        enabled = d.object(forKey: Key.enabled) as? Bool ?? true
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
