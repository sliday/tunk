import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private lazy var engine = Engine(settings: settings)

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusLine: NSMenuItem!
    private var enableItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var flashWork: DispatchWorkItem?
    private let openSettingsOnLaunch: Bool
    private let openCalibrationOnLaunch: Bool

    init(openSettingsOnLaunch: Bool = false, openCalibrationOnLaunch: Bool = false) {
        self.openSettingsOnLaunch = openSettingsOnLaunch
        self.openCalibrationOnLaunch = openCalibrationOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // belt and braces alongside LSUIElement

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarGlyph.image(for: .idle)
        statusItem.button?.imagePosition = .imageOnly
        // Not `.removalAllowed`: the menubar item is the app's only surface, so
        // a stray ⌘-drag would leave the user with no way back in.
        statusItem.isVisible = true

        buildMenu()
        statusItem.menu = menu

        engine.onTrigger = { [weak self] in self?.flash() }
        engine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.render(status: status) }
            .store(in: &cancellables)

        // A Shortcut renamed months ago surfaces here and nowhere else until the
        // user opens the panel. That is the whole point: passive, never a dialog.
        engine.$actionStats
            .map(\.brokenBinding)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.render(status: self.engine.status)
            }
            .store(in: &cancellables)

        settings.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.enableItem?.state = on ? .on : .off }
            .store(in: &cancellables)

        engine.setEnabled(settings.enabled)
        // One launch line on stderr. It is the only way to tell, from outside,
        // whether the status item got a slot in the menu bar or was collapsed
        // into a hidden section by the OS or a menu-bar manager.
        // Logged a beat later: the status item gets its slot on the first run
        // loop turn, so asking immediately always reports an empty rect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let slot = self.statusItem.button?.window?.frame ?? .zero
            let line = "tunk: menubar item at \(Int(slot.origin.x)),\(Int(slot.origin.y)) "
                + "size \(Int(slot.width))x\(Int(slot.height)), "
                + "detection \(self.settings.enabled ? "on" : "off")\n"
            FileHandle.standardError.write(Data(line.utf8))
            if self.openSettingsOnLaunch || self.openCalibrationOnLaunch {
                self.showSettings(startCalibration: self.openCalibrationOnLaunch)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.setEnabled(false)
    }

    // MARK: - menu

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine = NSMenuItem(title: "Tunk", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        permissionItem = NSMenuItem(title: "Grant Permissions…",
                                    action: #selector(grantPermissions), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        menu.addItem(.separator())

        enableItem = NSMenuItem(title: "Enable Detection",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = settings.enabled ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(.separator())

        let calibrate = NSMenuItem(title: "Calibrate…", action: #selector(openCalibration),
                                   keyEquivalent: "")
        calibrate.target = self
        menu.addItem(calibrate)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin),
                               keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let quit = NSMenuItem(title: "Quit Tunk", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        engine.refreshPermissions()
        refreshMenuText()
    }

    private func statusText() -> String {
        switch engine.status {
        case .running:
            if let broken = engine.brokenBinding {
                return "Shortcut \"\(broken.name)\" is missing — open Settings"
            }
            return String(format: "Listening · %.0f Hz · %d fired",
                          engine.sampleRateHz, engine.triggerCount)
        case .off:
            return "Detection off"
        case .needsPermission:
            return "Blocked: permissions needed"
        case .sensorLost(let why):
            return "Sensor lost: \(why)"
        }
    }

    private func refreshMenuText() {
        let text = statusText()
        // Tabular figures so the Hz readout does not jitter the menu width while
        // it is open.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
        statusLine.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        permissionItem.isHidden = engine.permissions.ready
        loginItem.state = settings.launchAtLoginEnabled ? .on : .off
        enableItem.state = settings.enabled ? .on : .off
    }

    // MARK: - glyph

    private func render(status: EngineStatus) {
        var state: MenuBarGlyph.State
        switch status {
        case .running: state = .armed
        case .off: state = .idle
        case .sensorLost: state = .lost
        case .needsPermission: state = .blocked
        }
        // A broken binding does not stop detection, so it only overrides the
        // armed glyph. A sensor or permission problem is the bigger one and
        // keeps its own mark.
        if state == .armed && engine.brokenBinding != nil { state = .actionBroken }
        statusItem.button?.image = MenuBarGlyph.image(for: state)
        statusItem.button?.toolTip = "Tunk — " + statusText()
        refreshMenuText()
    }

    /// One-shot: the glyph swells for 140 ms when a gesture fires. Re-firing
    /// inside that window replaces the pending restore rather than queueing a
    /// second one, so a burst of taps cannot leave a backlog of animations.
    private func flash() {
        flashWork?.cancel()
        statusItem.button?.image = MenuBarGlyph.image(for: .firing)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.render(status: self.engine.status)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    // MARK: - actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
    }

    @objc private func toggleLogin() {
        settings.setLaunchAtLogin(!settings.launchAtLoginEnabled)
        loginItem.state = settings.launchAtLoginEnabled ? .on : .off
        if let error = settings.launchAtLoginError { present(message: error) }
    }

    @objc private func grantPermissions() {
        let state = engine.permissions
        if !state.accessibility {
            PermissionState.promptAccessibility()
            PermissionState.openAccessibilityPane()
        } else if !state.inputMonitoring {
            PermissionState.promptInputMonitoring()
            PermissionState.openInputMonitoringPane()
        }
    }

    @objc private func openSettings() {
        showSettings(startCalibration: false)
    }

    @objc private func openCalibration() {
        showSettings(startCalibration: true)
    }

    private func showSettings(startCalibration: Bool) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, engine: engine)
        }
        settingsWindow?.present(startCalibration: startCalibration)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func present(message: String) {
        let alert = NSAlert()
        alert.messageText = "Tunk"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
