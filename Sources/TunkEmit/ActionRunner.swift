import Foundation
import TunkCore

/// What the panel shows about the configured action, and what the live
/// acceptance test counts.
///
/// ## Two latencies, kept apart on purpose
///
/// - `lastDispatchLatencyNs` — decision to handoff. The PRD's 250 ms p95 target
///   is measured against this. It is the part Tunk controls, and it must stay
///   around a millisecond for every action kind.
/// - `lastCompletionLatencyNs` — how long the shortcut itself then took. Best
///   effort, reported only. It gates nothing, it is not compared to any target,
///   and a shortcut that takes nine seconds is not a Tunk latency failure.
///
/// Collapsing the two would make a slow shortcut look like a slow detector.
public struct ActionStats: Sendable, Equatable {
    /// The hotkey path's own numbers, straight from `HotkeyEmitter`, including
    /// the down/up balance the stuck-modifier rule is asserted against.
    public var emit = EmitStats()

    /// Actions dispatched, of every kind, `.none` included.
    public var runCount: Int = 0
    /// Shortcuts handed to the spawner.
    public var shortcutRunCount: Int = 0
    /// Shortcuts that came back non-zero, could not start, or timed out.
    public var shortcutFailureCount: Int = 0
    /// Shortcuts that came back clean.
    public var shortcutSuccessCount: Int = 0

    public var lastAction: TunkAction?
    /// Decision to handoff, for the last run of any kind.
    public var lastDispatchLatencyNs: Int64?
    /// Handoff to the shortcut exiting, for the last shortcut that reported
    /// back. Nil until one does, and it stays nil while one is in flight.
    public var lastCompletionLatencyNs: Int64?
    /// Text for the panel. Set by a failed emit or a failed shortcut, cleared by
    /// the next success of the same kind.
    public var lastErrorText: String?

    /// Never true. Mirrors `EmitStats.hasStuckKey` so the panel has one thing to
    /// watch rather than two.
    public var hasStuckKey: Bool { emit.hasStuckKey }

    public var lastDispatchMs: Double? {
        lastDispatchLatencyNs.map { Double($0) / 1_000_000 }
    }

    public var lastCompletionMs: Double? {
        lastCompletionLatencyNs.map { Double($0) / 1_000_000 }
    }

    public init() {}
}

/// Dispatches the configured `TunkAction` on a confirmed gesture.
///
/// This is a router, not a rewrite. The hotkey path is `HotkeyEmitter`, held as
/// is and called as is, so every guarantee it makes about balanced key pairs
/// still comes from the same code that was tested for it. The shortcut path
/// hands off to a `ShortcutSpawning` and returns.
///
/// ## The rule this type exists to keep
///
/// `run()` never waits for an action to finish. The hotkey path is synchronous
/// because posting a CGEvent is microseconds. The shortcut path is not, because
/// a shortcut can take seconds or hang forever, and the detector's sample thread
/// is the caller.
public final class ActionRunner: @unchecked Sendable {
    private let emitter: HotkeyEmitter
    private let spawner: ShortcutSpawning
    private let lock = NSLock()
    private var _action: TunkAction
    private var _stats = ActionStats()

    /// Called after every run and after every shortcut reports back, off the
    /// lock, on whatever thread got there. The panel uses it to refresh.
    public var onChange: (@Sendable (ActionStats) -> Void)?

    public init(action: TunkAction = .hotkey(.recommendedDefault),
                emitter: HotkeyEmitter = HotkeyEmitter(),
                spawner: ShortcutSpawning = ShortcutsProcessSpawner()) {
        self._action = action
        self.emitter = emitter
        self.spawner = spawner
        if let spec = action.hotkeySpec { emitter.hotkey = spec }
    }

    // MARK: - Configuration

    /// The action a confirmed double-tap runs. Setting it also updates the
    /// emitter's hotkey, so there is one value to change and no way for the two
    /// to drift.
    public var action: TunkAction {
        get {
            lock.lock(); defer { lock.unlock() }
            return _action
        }
        set {
            lock.lock()
            _action = newValue
            lock.unlock()
            if let spec = newValue.hotkeySpec { emitter.hotkey = spec }
        }
    }

    public var stats: ActionStats {
        lock.lock(); defer { lock.unlock() }
        var s = _stats
        s.emit = emitter.stats
        return s
    }

    /// The hotkey emitter, for the panel's down/up readout and preflight. Read
    /// only by convention; configure through `action` instead of reaching in.
    public var hotkeyEmitter: HotkeyEmitter { emitter }

    public func resetStats() {
        lock.lock(); _stats = ActionStats(); lock.unlock()
        emitter.resetStats()
    }

    /// Checks what can be checked without doing anything: Accessibility, and
    /// whether the hotkey pair can be built. A shortcut is deliberately not
    /// preflighted — the only way to check one is to run it, and running a
    /// user's shortcut to find out whether it works is exactly what Tunk must
    /// not do.
    public func preflight() throws {
        guard action.hotkeySpec != nil else { return }
        try emitter.preflight()
    }

    // MARK: - Running

    /// Run the configured action once.
    ///
    /// Throws only on the hotkey path, and only for failures that are already
    /// `HotkeyEmitter`'s to report. A shortcut cannot throw here: its failure
    /// happens later, in another process, and arrives through `onChange` and
    /// `stats.lastErrorText` instead.
    @discardableResult
    public func run() throws -> ActionStats {
        try run(action)
    }

    /// Run a specific action once. Used by the panel's Test button.
    @discardableResult
    public func run(_ action: TunkAction) throws -> ActionStats {
        let t0 = EmitClock.nowNanos()
        switch action {
        case .hotkey(let spec):
            do {
                _ = try emitter.emit(spec)
            } catch {
                _ = record(action: action, dispatchNs: dispatch(since: t0, for: action),
                           error: describe(error))
                throw error
            }
            return record(action: action, dispatchNs: dispatch(since: t0, for: action), error: nil)

        case .shortcut(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return record(action: action, dispatchNs: dispatch(since: t0, for: action),
                              error: EmitError.noShortcutChosen.userText)
            }
            // Handoff. Everything past this line happens on someone else's
            // thread; the detector gets control back at `record` below.
            spawner.spawn(shortcut: trimmed) { [weak self] outcome in
                self?.absorb(outcome)
            }
            lock.lock(); _stats.shortcutRunCount += 1; lock.unlock()
            return record(action: action, dispatchNs: dispatch(since: t0, for: action), error: nil)

        case .none:
            return record(action: action, dispatchNs: dispatch(since: t0, for: action), error: nil)
        }
    }

    /// Convenience mirroring `HotkeyEmitter.emit(for:)`, so the engine's call
    /// site reads the same as it did.
    @discardableResult
    public func run(for trigger: Trigger) throws -> ActionStats {
        try run()
    }

    // MARK: - Internals

    /// Decision to handoff.
    ///
    /// For a shortcut or `.none`, that is simply how long `run` took. For a
    /// hotkey it is measured to the moment the key-down went out, which the
    /// emitter stamps: the key is then deliberately held for `keyDownHoldNs`
    /// (8 ms by default) before the up, and that hold is not latency — the
    /// keystroke had already reached the system.
    ///
    /// Subtracting the configured hold instead would fold `Thread.sleep`'s
    /// overshoot into the figure, which measured at 5 ms on a 20 ms hold.
    private func dispatch(since t0: Int64, for action: TunkAction) -> Int64 {
        let elapsed = EmitClock.nowNanos() - t0
        guard action.hotkeySpec != nil else { return elapsed }
        // Falls back to the wall figure if the down never went out, which is
        // the failure path — there is nothing to measure to in that case.
        guard let downAt = emitter.stats.lastKeyDownMachNs, downAt >= t0 else { return elapsed }
        return downAt - t0
    }

    private func record(action: TunkAction, dispatchNs: Int64, error: String?) -> ActionStats {
        lock.lock()
        _stats.runCount += 1
        _stats.lastAction = action
        _stats.lastDispatchLatencyNs = dispatchNs
        if action.hotkeySpec != nil || error != nil {
            // A fresh shortcut run has no completion yet; showing the previous
            // one's would be a lie about the run that just happened.
            _stats.lastCompletionLatencyNs = nil
        }
        _stats.lastErrorText = error
        var snapshot = _stats
        lock.unlock()
        snapshot.emit = emitter.stats
        onChange?(snapshot)
        return snapshot
    }

    /// A shortcut reporting back, long after `run` returned. Never throws, never
    /// touches the detector, and cannot fail loudly enough to matter — but it is
    /// not swallowed either: a failure lands in `lastErrorText`, which the panel
    /// shows.
    private func absorb(_ outcome: ShortcutOutcome) {
        lock.lock()
        _stats.lastCompletionLatencyNs = outcome.completionLatencyNs
        if let error = outcome.error {
            _stats.shortcutFailureCount += 1
            _stats.lastErrorText = describe(error)
        } else {
            _stats.shortcutSuccessCount += 1
            if _stats.lastAction?.shortcutName == outcome.name { _stats.lastErrorText = nil }
        }
        var snapshot = _stats
        lock.unlock()
        snapshot.emit = emitter.stats
        onChange?(snapshot)
    }

    private func describe(_ error: Error) -> String {
        (error as? EmitError)?.userText ?? String(describing: error)
    }
}

extension EmitError {
    /// Problem plus fix, in one string the panel can print verbatim.
    var userText: String {
        guard let fix = recoverySuggestion else { return description }
        return "\(description) \(fix)"
    }
}
