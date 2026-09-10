import AppKit
import Combine
import SwiftUI

/// Hosts the first-run window. Fixed size, kept alive between opens, and the
/// only thing that starts or stops the model's timers: the permission poll
/// runs while the window is up, the tap feedback only on the last step.
///
/// Timers are stopped from here rather than from the view for the reason
/// `SettingsWindowController` documents: `onDisappear` never arrives for a
/// hosted view whose window is merely ordered out.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private let window: NSWindow
    private var cancellables = Set<AnyCancellable>()
    /// Called after the user finishes, so the owner can drop the window.
    var onFinish: (() -> Void)?

    init(settings: AppSettings, engine: Engine, startAt step: OnboardingModel.Step) {
        model = OnboardingModel(settings: settings, engine: engine, startAt: step)
        let size = OnboardingView.size
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init()

        window.title = "Set up Tunk"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.center()

        model.$step
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] step in
                guard let self, self.window.isVisible else { return }
                if step == .tryIt { self.model.startFeedback() } else { self.model.stopFeedback() }
            }
            .store(in: &cancellables)

        settings.$onboardingCompleted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] done in
                guard done, let self, self.window.isVisible else { return }
                self.window.close()
                self.onFinish?()
            }
            .store(in: &cancellables)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.startPolling()
        if model.step == .tryIt { model.startFeedback() }
        // One line on stderr, like the menubar slot line: the only way to tell
        // from outside, without Screen Recording, that the window is up and on
        // which step.
        let f = window.frame
        let line = "tunk: onboarding window at \(Int(f.origin.x)),\(Int(f.origin.y)) "
            + "size \(Int(f.width))x\(Int(f.height)), step \(model.step.rawValue + 1), "
            + "permissions \(model.permissions.inputMonitoring ? "input" : "-")"
            + "/\(model.permissions.accessibility ? "ax" : "-")\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    var isVisible: Bool { window.isVisible }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.stopFeedback()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if model.step == .tryIt { model.startFeedback() }
    }
}
