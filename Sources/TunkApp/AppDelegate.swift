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
    private var bindingItem: NSMenuItem!
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var flashWork: DispatchWorkItem?
    private let openSettingsOnLaunch: Bool
    private let openCalibrationOnLaunch: Bool
    /// Set by `--onboarding`; nil means "only if never completed".
    private let openOnboardingAt: OnboardingModel.Step?

    init(openSettingsOnLaunch: Bool = false, openCalibrationOnLaunch: Bool = false,
         openOnboardingAt: OnboardingModel.Step? = nil) {
        self.openSettingsOnLaunch = openSettingsOnLaunch
        self.openCalibrationOnLaunch = openCalibrationOnLaunch
        self.openOnboardingAt = openOnboardingAt
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

        engine.onTrigger = { [weak self] in
            self?.flash()
            self?.onboardingWindow?.model.noteTrigger()
        }
        engine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.render(status: status) }
            .store(in: &cancellables)

        // Same treatment for a live action failure: it changes the glyph and the
        // tooltip, so the render has to be driven by it too or the state only
        // appears the next time something else happens to redraw.
        engine.$lastActionFailed
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.render(status: self.engine.status)
            }
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
            // First launch, or asked for explicitly. The window is the only
            // way a non-technical person finds out there are two permissions
            // to grant; a lone menubar glyph says nothing.
            if let step = self.openOnboardingAt {
                self.showOnboarding(at: step)
            } else if !self.settings.onboardingCompleted {
                self.showOnboarding(at: .whatItDoes)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.setEnabled(false)
        // Drain the emit queue before the process goes away. A pair holds its
        // key down for 8 ms on that queue, and macOS does NOT clean up after a
        // posting process dies: measured, a child that posted a key-down with
        // maskControl and exited left the session at 0x40000 at t+0.5 s and
        // t+2.5 s, cleared only by a later keyless flagsChanged. The window is
        // small — a few hundred microseconds to 8 ms — but a crash, a logout or
        // a killall landing inside it leaves a chord asserted with nothing left
        // running to release it.
        engine.drainPendingEmissions()
    }

    // MARK: - menu

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Order and wording follow the bar: status line, Enable detection,
        // separator, the bound double-tap readout, Calibrate…, Settings…,
        // separator, Launch at Login, Quit Tunk. "Set up Tunk…" sits with
        // Settings…, since that is where a person looks for it.
        statusLine = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        enableItem = NSMenuItem(title: "Enable detection",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = settings.enabled ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(.separator())

        bindingItem = NSMenuItem(title: "Double tap: nothing", action: nil, keyEquivalent: "")
        bindingItem.isEnabled = false
        menu.addItem(bindingItem)

        let calibrate = NSMenuItem(title: "Calibrate…", action: #selector(openCalibration),
                                   keyEquivalent: "")
        calibrate.target = self
        menu.addItem(calibrate)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let setup = NSMenuItem(title: "Set up Tunk…", action: #selector(openOnboarding),
                               keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

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

    /// Plain words for the menu's first line. The numbers live in the tooltip
    /// and the panel, not here.
    private func statusText() -> String {
        switch engine.status {
        case .running:
            if let broken = engine.brokenBinding {
                return "Shortcut \u{201C}\(broken.name)\u{201D} is missing"
            }
            if engine.lastActionFailed { return "Last action failed" }
            return "Listening"
        case .off: return "Off"
        case .needsPermission: return "Needs permission"
        case .sensorLost: return "Sensor unavailable"
        }
    }

    /// The fuller line, for the glyph's tooltip: same words plus the numbers.
    private func tooltipText() -> String {
        guard case .running = engine.status, engine.brokenBinding == nil,
              !engine.lastActionFailed else { return statusText() }
        return String(format: "Listening · %.0f Hz · %d fired",
                      engine.sampleRateHz, engine.triggerCount)
    }

    private func statusDotColor() -> NSColor {
        switch engine.status {
        case .running:
            return (engine.brokenBinding != nil || engine.lastActionFailed)
                ? .systemOrange : .systemGreen
        case .off: return .tertiaryLabelColor
        case .needsPermission, .sensorLost: return .systemOrange
        }
    }

    private func bindingText() -> String {
        switch settings.action(for: 2) {
        case .hotkey(let spec): return "Double tap: \(spec.description)"
        case .shortcut(let name, _):
            return name.isEmpty ? "Double tap: no Shortcut chosen"
                                : "Double tap: Shortcut \u{201C}\(name)\u{201D}"
        case .none: return "Double tap: nothing"
        }
    }

    private func refreshMenuText() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLine.attributedTitle = NSAttributedString(
            string: statusText(),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        statusLine.image = AppDelegate.dot(statusDotColor())
        // Tabular figures so a readout with digits in it does not jitter the
        // menu width while it is open.
        let small = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                     weight: .regular)
        bindingItem.attributedTitle = NSAttributedString(
            string: bindingText(),
            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
        loginItem.state = settings.launchAtLoginEnabled ? .on : .off
        enableItem.state = settings.enabled ? .on : .off
    }

    /// An 8 pt filled circle for the status line. Not a template image: its
    /// colour is the information.
    private static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        return image
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
        if state == .armed && (engine.brokenBinding != nil || engine.lastActionFailed) {
            state = .actionBroken
        }
        statusItem.button?.image = MenuBarGlyph.image(for: state)
        statusItem.button?.toolTip = "Tunk — " + tooltipText()
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

    @objc private func openOnboarding() {
        showOnboarding(at: .whatItDoes)
    }

    private func showOnboarding(at step: OnboardingModel.Step) {
        if let existing = onboardingWindow, existing.isVisible {
            existing.model.step = step
            existing.present()
            return
        }
        let controller = OnboardingWindowController(settings: settings, engine: engine,
                                                    startAt: step)
        controller.onFinish = { [weak self] in self?.onboardingWindow = nil }
        onboardingWindow = controller
        controller.present()
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
