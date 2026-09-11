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
        /// Written by the build that had one action and no tap count. Read once,
        /// at load, to migrate into the double-tap binding. Never written again.
        static let legacyAction = "action"
        static let bindings = "actionBindings"
        static func hotkeyDraft(_ count: Int) -> String { "hotkeyDraft.\(count)" }
        static func shortcutDraft(_ count: Int) -> String { "shortcutDraft.\(count)" }
        static func shortcutDraftListed(_ count: Int) -> String { "shortcutDraftListed.\(count)" }
        static let enabled = "enabled"
        static let lapPairing = "experimentalLapPairing"
        static let resonator = "experimentalResonator"
        static let onboardingCompleted = "onboardingCompleted"
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
    var onBindingsChange: ((ActionBindings) -> Void)?
    /// Called when `tuning` changes. Separate from `onConfigChange` because a
    /// `DSPTuning` is fixed for a detector's lifetime — the engine answers this
    /// one by building a new detector, not by writing into the live one.
    var onTuningChange: ((DSPTuning) -> Void)?

    @Published var config: DetectorConfig {
        didSet {
            guard config != oldValue else { return }
            // PERSIST the stored value, PUBLISH the derived one. Posting `config`
            // here stripped the resonator's threshold on every ordinary write -
            // one slider drag, `endCalibration`, or a reset - while leaving its
            // front end running. Measured: 0.011 in force, then 0.032 after a
            // single slider write, with `experimentalResonator` still true. That
            // is 2.9x the bar a narrow-band chain needs, so detection collapses,
            // and it healed on relaunch because `init` and `start()` both read
            // `effectiveConfig` - the classic irreproducible report.
            persist(config, key: Key.config)
            onConfigChange?(effectiveConfig)
        }
    }

    /// One action per tap count. The one value the engine reads; the panel
    /// writes only this and the per-count drafts below, which feed it.
    @Published var bindings: ActionBindings {
        didSet {
            guard bindings != oldValue else { return }
            persist(bindings, key: Key.bindings)
            armDetectorForBoundCounts()
            onBindingsChange?(bindings)
        }
    }

    /// The detector only reports gestures whose count is in
    /// `config.armedTapCounts`. Binding an action to a count is the act that
    /// arms it — two separate switches for one intention would be a trap, and a
    /// user who binds single tap and sees nothing happen would be right to call
    /// it broken.
    ///
    /// This runs one way only: bindings drive arming, never the reverse. A count
    /// with nothing bound is disarmed, which keeps the cheapest possible
    /// false-positive defence in place — an unbound single tap is not merely
    /// ignored downstream, it is never grouped in the first place.
    private func armDetectorForBoundCounts() {
        let wanted = Set(bindings.boundCounts)
            .intersection(DetectorConfig.supportedTapCounts)
        guard config.armedTapCounts != wanted else { return }
        config.armedTapCounts = wanted
    }

    /// Per-count UI memory. Kept so a user who switches a row to "Do nothing"
    /// and back gets their own combination returned rather than a shipped
    /// default. The engine never reads these; they are written into `bindings`
    /// the moment the row's kind matches.
    @Published private var hotkeyDrafts: [Int: HotkeySpec] = [:]
    @Published private var shortcutDrafts: [Int: String] = [:]
    /// Whether each shortcut draft was picked from a real listing. Carried into
    /// the binding so a name that later stops resolving can be described as
    /// renamed rather than as never having existed.
    @Published private var shortcutDraftListed: [Int: Bool] = [:]

    // MARK: - per-row accessors

    func action(for count: Int) -> TunkAction { bindings[count] }

    func hotkeyDraft(for count: Int) -> HotkeySpec {
        hotkeyDrafts[count] ?? .recommendedDefault
    }

    func setHotkeyDraft(_ spec: HotkeySpec, for count: Int) {
        guard hotkeyDrafts[count] != spec else { return }
        hotkeyDrafts[count] = spec
        defaults.set(spec.description, forKey: Key.hotkeyDraft(count))
        if bindings[count].kind == .hotkey { bindings[count] = .hotkey(spec) }
    }

    func shortcutDraft(for count: Int) -> String { shortcutDrafts[count] ?? "" }

    /// - Parameter pickedFromListing: true when the name came out of a real
    ///   `shortcuts list`, which is the only way Tunk can honestly claim it
    ///   existed at the moment of binding.
    func setShortcutDraft(_ name: String, for count: Int, pickedFromListing: Bool) {
        guard shortcutDrafts[count] != name else { return }
        shortcutDrafts[count] = name
        shortcutDraftListed[count] = pickedFromListing
        defaults.set(name, forKey: Key.shortcutDraft(count))
        defaults.set(pickedFromListing, forKey: Key.shortcutDraftListed(count))
        if bindings[count].kind == .shortcut {
            bindings[count] = .shortcut(name: name, wasListedWhenBound: pickedFromListing)
        }
    }

    func actionKind(for count: Int) -> TunkAction.Kind { bindings[count].kind }

    /// Switching a row's kind rebuilds that row's action from its own drafts, so
    /// nothing is invented and nothing is lost.
    func setActionKind(_ kind: TunkAction.Kind, for count: Int) {
        switch kind {
        case .hotkey:
            bindings[count] = .hotkey(hotkeyDraft(for: count))
        case .shortcut:
            bindings[count] = .shortcut(name: shortcutDraft(for: count),
                                        wasListedWhenBound: shortcutDraftListed[count] ?? false)
        case .none:
            bindings[count] = .none
        }
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Key.enabled)
            onEnabledChange?(enabled)
        }
    }

    /// Experimental lap pairing (M26 plus its anchor floor). Ships off, and the
    /// only thing that turns it on is the owner reading the panel and deciding
    /// to be the experiment. Persisted like every other setting.
    ///
    /// It is a `DSPTuning`, not a `DetectorConfig`: nothing about it is
    /// per-gesture, and the detector reads its tuning once at construction.
    @Published var experimentalLapPairing: Bool {
        didSet {
            guard experimentalLapPairing != oldValue else { return }
            defaults.set(experimentalLapPairing, forKey: Key.lapPairing)
            onTuningChange?(tuning)
        }
    }

    /// The resonator front end a critic ruled should ship on. It is offered as a
    /// switch rather than taken as the default, because that is a change to what
    /// fires a keystroke on this machine and it is the owner's to make. Ships OFF,
    /// so absent means the previous detector, unchanged.
    @Published var experimentalResonator: Bool {
        didSet {
            guard experimentalResonator != oldValue else { return }
            defaults.set(experimentalResonator, forKey: Key.resonator)
            onTuningChange?(tuning)
            onConfigChange?(effectiveConfig)
        }
    }

    /// The tuning the detector should be running right now.
    ///
    /// The two switches compose: the resonator is a front end, lap pairing is a
    /// grouping rule, and they were graded independently.
    var tuning: DSPTuning {
        var t = experimentalLapPairing ? DSPTuning.lapPairingExperiment : .default
        if experimentalResonator {
            let r = DSPTuning.resonatorFrontEnd
            t.resonatorHz = r.resonatorHz
            t.resonatorQ = r.resonatorQ
            t.minThresholdG = r.minThresholdG
        }
        return t
    }

    /// The config the detector should be running right now.
    ///
    /// DERIVED, never stored. The resonator narrows the band by a large factor,
    /// so it needs its own admission threshold — but writing that into `config`
    /// would overwrite a sensitivity the owner set by hand, and switching back
    /// would not restore it. So the threshold is applied on the way out and the
    /// stored value is left alone.
    var effectiveConfig: DetectorConfig {
        guard experimentalResonator else { return config }
        var c = config
        c.defaultThreshold = 0.011
        if c.calibratedThreshold != nil { c.calibratedThreshold = 0.011 }
        return c
    }

    /// Set once, when the user reaches the end of the first-run window. Read
    /// at launch to decide whether to show it. Never cleared by the app: the
    /// window stays reachable from the menu and from `tunk --onboarding`.
    @Published var onboardingCompleted: Bool {
        didSet {
            guard onboardingCompleted != oldValue else { return }
            defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted)
        }
    }

    @Published private(set) var launchAtLoginError: String?

    /// What the migration changed on this launch, for the panel to show. Empty
    /// on a fresh install and on any launch where nothing needed changing.
    ///
    /// Deliberately not persisted: it describes one migration, the panel shows
    /// it once, and the user dismisses it. A note that outlived the launch that
    /// produced it would nag about a change already made.
    @Published private(set) var migrationNotes: [SettingsMigration.Note] = []

    func dismissMigrationNotes() { migrationNotes = [] }

    /// - Parameter suiteName: the defaults suite to read and write. Only
    ///   `--dump-panel` passes anything else, so a diagnostic render cannot
    ///   touch the settings the operator is actually running with.
    init(suiteName: String = AppSettings.suiteName) {
        let d = UserDefaults(suiteName: suiteName) ?? .standard
        defaults = d
        let stored = AppSettings.load(DetectorConfig.self, key: Key.config, from: d)
        // Only a stored config is migrated. A fresh install already has the
        // current defaults and has nothing to be told about.
        if let stored {
            let result = SettingsMigration.migrate(stored)
            config = result.config
            migrationNotes = result.notes
        } else {
            config = .default
            migrationNotes = []
        }
        // The rules live in `ActionBindings.restored`, in TunkEmit, where they
        // are under test; this reads the three keys and hands them over.
        let loaded = ActionBindings.restored(bindingsData: d.data(forKey: Key.bindings),
                                             actionData: d.data(forKey: Key.legacyAction),
                                             legacyHotkeyText: d.string(forKey: Key.legacyHotkey))
        bindings = loaded
        enabled = d.object(forKey: Key.enabled) as? Bool ?? true
        // Absent means off. A fresh install, and any install that predates the
        // switch, runs the shipped detector.
        experimentalLapPairing = d.object(forKey: Key.lapPairing) as? Bool ?? false
        experimentalResonator = d.object(forKey: Key.resonator) as? Bool ?? false
        onboardingCompleted = d.object(forKey: Key.onboardingCompleted) as? Bool ?? false

        // Seed each row's drafts from what was loaded, falling back to what was
        // stored, so the first switch between kinds offers the user's own value.
        for count in ActionBindings.representableCounts {
            let action = loaded[count]
            hotkeyDrafts[count] = action.hotkeySpec
                ?? d.string(forKey: Key.hotkeyDraft(count)).flatMap { try? HotkeySpec(parsing: $0) }
                ?? .recommendedDefault
            shortcutDrafts[count] = action.shortcutName
                ?? d.string(forKey: Key.shortcutDraft(count)) ?? ""
            shortcutDraftListed[count] = action.shortcutName != nil
                ? action.shortcutWasListedWhenBound
                : (d.object(forKey: Key.shortcutDraftListed(count)) as? Bool ?? false)
        }
        // Reconcile once at launch: a settings file written before the counts
        // were linked, or hand-edited since, must not leave a bound action
        // silently disarmed.
        armDetectorForBoundCounts()

        // Write the migrated config back straight away. `config`'s `didSet` does
        // not run during init, so without this the old values would be re-read
        // and re-migrated on every launch, and the panel would keep announcing
        // a change it already made.
        if !migrationNotes.isEmpty { persist(config, key: Key.config) }
    }

    func resetDetectionToDefaults() {
        var next = DetectorConfig.default
        // Calibration is a property of this machine and this user's hand, not a
        // tuning knob. Resetting the sliders must not throw it away.
        //
        // That meant the threshold only, and the learned RHYTHM went with the
        // defaults: `calibratedInterTapNs` back to nil and the window it derived
        // back to 220 ms. Measured consequence, on the very case the calibration
        // copy exists for: a 230 ms-spaced double-tap fires with a learned
        // 235 ms window and stops firing after a reset, while the calibration
        // card still reads "calibrated" with the old threshold. The user's hand
        // did not change when they moved a slider.
        next.calibratedThreshold = config.calibratedThreshold
        next.calibratedInterTapNs = config.calibratedInterTapNs
        if let learned = config.calibratedInterTapNs {
            next.maxInterTapNs = learned
            next.confirmWindowNs = learned
        }
        // Preserve what is ARMED, or this button silently stops a bound tap
        // count from firing. `armDetectorForBoundCounts()` runs from
        // `bindings.didSet` and from `init`, never from a wholesale config
        // write, so a reset left bindings holding count 1 while armedTapCounts
        // was back to [2]. Measured: a single synthetic tap fires [1] armed
        // [1,2] and fires nothing armed [2], while the single-tap row still
        // shows its hotkey and Test still works because Test bypasses the
        // detector. A relaunch re-armed it, which is the "it worked yesterday"
        // report nobody can reproduce.
        next.armedTapCounts = config.armedTapCounts
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
