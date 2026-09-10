import AppKit
import Combine
import Foundation
import TunkEmit

/// State behind the first-run window. Three steps, a 1 s permission poll, and
/// the two things the last step needs to say "felt it": the engine's onset log
/// and its trigger callback.
///
/// Every input the view branches on lives here so `--dump-onboarding` can force
/// it: the permission source is injectable, and the trigger feedback can be
/// staged. The real window uses `PermissionState.current()` and the engine.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case whatItDoes = 0
        case permissions = 1
        case tryIt = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .whatItDoes: return "What it does"
            case .permissions: return "Permissions"
            case .tryIt: return "Try it"
            }
        }
    }

    @Published var step: Step
    @Published private(set) var permissions: PermissionState
    /// True once Input Monitoring went from missing to granted while this
    /// window was open. macOS applies that grant to the IOHID client of a fresh
    /// process, so the window offers a relaunch instead of pretending.
    @Published private(set) var inputMonitoringGrantedThisSession = false
    @Published var launchAtLogin: Bool
    @Published private(set) var launchAtLoginNote: String?

    // Step 3 feedback.
    /// Strength of the most recent onset, decaying toward zero at display rate.
    @Published private(set) var pulse: Double = 0
    /// How many double-taps the engine confirmed while this step was open.
    @Published private(set) var feltCount = 0
    /// True for a beat after a confirmed double-tap; drives the "Felt it" flip.
    @Published private(set) var feltRecently = false

    let settings: AppSettings
    private let engine: Engine?
    private let permissionSource: () -> PermissionState
    private var pollTimer: Timer?
    private var pulseTimer: Timer?
    private var feltReset: DispatchWorkItem?
    private var lastOnsetNs: Int64 = 0
    private var cancellables = Set<AnyCancellable>()

    /// - Parameters:
    ///   - engine: nil only under `--dump-onboarding`, which has no sensor to
    ///     read and no permissions to refresh.
    ///   - permissionSource: what the poll reads. Injected so a render can show
    ///     every combination regardless of what the calling terminal was granted.
    init(settings: AppSettings,
         engine: Engine?,
         startAt step: Step = .whatItDoes,
         permissionSource: @escaping () -> PermissionState = { PermissionState.current() }) {
        self.settings = settings
        self.engine = engine
        self.step = step
        self.permissionSource = permissionSource
        self.permissions = permissionSource()
        self.launchAtLogin = settings.launchAtLoginEnabled
    }

    deinit {
        pollTimer?.invalidate()
        pulseTimer?.invalidate()
    }

    // MARK: - permissions

    var canContinue: Bool {
        switch step {
        case .whatItDoes: return true
        case .permissions: return permissions.ready
        case .tryIt: return true
        }
    }

    /// One read a second while the window is open. Cheap: two TCC lookups.
    func startPolling() {
        guard pollTimer == nil else { return }
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopFeedback()
    }

    private func poll() {
        let now = permissionSource()
        if now != permissions {
            if now.inputMonitoring && !permissions.inputMonitoring {
                inputMonitoringGrantedThisSession = true
            }
            permissions = now
        }
        // The engine keeps its own copy and arms itself the moment both are
        // there; this is how the last step has a live detector to listen with.
        engine?.refreshPermissions()
    }

    /// Only for a render. Marks the state a user sees after granting Input
    /// Monitoring while the window was up.
    func forceRelaunchOffer() { inputMonitoringGrantedThisSession = true }

    func openInputMonitoring() {
        PermissionState.promptInputMonitoring()
        PermissionState.openInputMonitoringPane()
    }

    func openAccessibility() {
        PermissionState.promptAccessibility()
        PermissionState.openAccessibilityPane()
    }

    // MARK: - launch at login

    func setLaunchAtLogin(_ on: Bool) {
        guard settings.launchAtLoginEnabled != on else { return }
        settings.setLaunchAtLogin(on)
        launchAtLogin = settings.launchAtLoginEnabled
        launchAtLoginNote = settings.launchAtLoginError
    }

    // MARK: - navigation

    func advance() {
        guard canContinue else { return }
        switch step {
        case .whatItDoes: step = .permissions
        case .permissions: step = .tryIt
        case .tryIt: break
        }
    }

    func back() {
        switch step {
        case .whatItDoes: break
        case .permissions: step = .whatItDoes
        case .tryIt: step = .permissions
        }
    }

    // MARK: - step 3 feedback

    /// The last step listens at display rate for the engine's onsets. Onsets
    /// are what the detector saw; a confirmed double-tap arrives separately
    /// through `noteTrigger()`.
    func startFeedback() {
        guard pulseTimer == nil, let engine else { return }
        lastOnsetNs = engine.snapshot().nowNs
        let fps = min(max(NSScreen.main?.maximumFramesPerSecond ?? 60, 30), 60)
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(fps), repeats: true) {
            [weak self] _ in self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }

    func stopFeedback() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func tick() {
        guard let engine else { return }
        let snap = engine.snapshot()
        var next = pulse * 0.90
        if let newest = snap.onsets.last(where: { !$0.suppressedByGate && $0.tNs > lastOnsetNs }) {
            lastOnsetNs = newest.tNs
            // Normalised against the bar the onset had to clear, so a light tap
            // on a quiet desk and a hard one on a noisy one both read as a hit.
            let bar = max(snap.threshold, 0.005)
            next = min(1, max(next, 0.35 + 0.65 * min(1, newest.strength / (bar * 3))))
        }
        if abs(next - pulse) > 0.002 { pulse = next }
    }

    /// Called from the engine's trigger callback (via `AppDelegate`) on main.
    func noteTrigger() {
        guard step == .tryIt else { return }
        feltCount += 1
        feltRecently = true
        pulse = 1
        feltReset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.feltRecently = false }
        feltReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Only for a render: the state a beat after a double-tap landed.
    func forceFelt(count: Int) {
        feltCount = count
        feltRecently = true
        pulse = 1
    }

    // MARK: - what the last step describes

    var doubleTapAction: TunkAction { settings.action(for: 2) }

    var isListening: Bool {
        guard let engine else { return permissions.ready && settings.enabled }
        if case .running = engine.status { return true }
        return false
    }

    // MARK: - finishing

    func complete() {
        settings.onboardingCompleted = true
    }

    /// Quits and starts a fresh Tunk that opens this window on the same step.
    ///
    /// A detached shell waits for this process to exit before launching the
    /// next one, so there is never a moment with two menubar items, and the
    /// new process gets the Input Monitoring grant macOS only hands to a client
    /// created after the decision.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let args = "--onboarding --onboarding-step \(step.rawValue + 1)"
        let launch: String
        if Bundle.main.bundleURL.pathExtension == "app" {
            launch = "/usr/bin/open -n \"\(Bundle.main.bundleURL.path)\" --args \(args)"
        } else {
            let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            launch = "exec \"\(exe)\" \(args)"
        }
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; \(launch)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
        } catch {
            NSLog("tunk: relaunch failed: %@", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }
}
