import Foundation
import TunkCore

/// What the panel shows about the configured actions, and what the live
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
    /// Gestures that arrived with no action bound to their tap count. Counted so
    /// the number is visible, but deliberately not an error: an unbound count is
    /// a quiet no-op, not a problem to report.
    public var unboundCount: Int = 0
    /// Shortcuts handed to the spawner.
    public var shortcutRunCount: Int = 0
    /// Shortcuts that came back non-zero, could not start, or timed out.
    public var shortcutFailureCount: Int = 0
    /// Shortcuts that came back clean.
    public var shortcutSuccessCount: Int = 0
    /// Taps that found a bound Shortcut whose name no longer resolves. Nothing
    /// was spawned for any of these — that is the point of the counter.
    public var staleShortcutCount: Int = 0

    public var lastAction: TunkAction?
    /// The tap count of the last gesture handled, bound or not.
    public var lastTapCount: Int?
    /// Decision to handoff, for the last run of any kind.
    public var lastDispatchLatencyNs: Int64?
    /// Handoff to the shortcut exiting, for the last shortcut that reported
    /// back. Nil until one does, and it stays nil while one is in flight.
    public var lastCompletionLatencyNs: Int64?
    /// Text for the panel. Set by a failed emit, a failed shortcut, or a stale
    /// binding; cleared by the next clean run.
    public var lastErrorText: String?

    /// A configuration problem the user has to fix, as opposed to a transient
    /// failure. Set when a bound Shortcut no longer resolves, and it survives
    /// until the binding changes — the menubar reads this, so the user finds out
    /// without the panel being open.
    public var brokenBinding: BrokenBinding?

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

/// A binding that cannot run as configured. Passive: it is shown, never dialled.
public struct BrokenBinding: Sendable, Equatable {
    public var tapCount: Int
    public var name: String
    public var text: String

    public init(tapCount: Int, name: String, text: String) {
        self.tapCount = tapCount
        self.name = name
        self.text = text
    }
}

/// Dispatches the action bound to a gesture's tap count.
///
/// This is a router, not a rewrite. The hotkey path is `HotkeyEmitter`, held as
/// is and called as is, so every guarantee it makes about balanced key pairs
/// still comes from the same code that was tested for it. The shortcut path
/// hands off to a `ShortcutSpawning` and returns.
///
/// ## The two rules this type exists to keep
///
/// 1. `run` never waits for an action to finish. The hotkey path is synchronous
///    because posting a CGEvent is microseconds. The shortcut path is not,
///    because a shortcut can take seconds or hang forever, and the detector's
///    sample thread is the caller.
/// 2. A Shortcut name is checked against the catalog listing *before* it is
///    dispatched. An unknown name handed to the Shortcuts machinery puts a modal
///    dialog on screen; a tap gesture is easy to trigger by accident; so a
///    binding that went stale months ago would otherwise throw a dialog at the
///    user on every stray knock. Checking means reading the list. It never means
///    running the shortcut to see what happens.
public final class ActionRunner: @unchecked Sendable {
    private let emitter: HotkeyEmitter
    private let spawner: ShortcutSpawning
    private let resolver: ShortcutNameResolving
    private let lock = NSLock()
    private var _bindings: ActionBindings
    private var _stats = ActionStats()

    /// Called after every run and after every shortcut reports back, off the
    /// lock, on whatever thread got there. The panel and the menubar use it.
    public var onChange: (@Sendable (ActionStats) -> Void)?

    public init(bindings: ActionBindings = .default,
                emitter: HotkeyEmitter = HotkeyEmitter(),
                spawner: ShortcutSpawning = ShortcutsProcessSpawner(),
                resolver: ShortcutNameResolving = CatalogNameResolver()) {
        self._bindings = bindings
        self.emitter = emitter
        self.spawner = spawner
        self.resolver = resolver
    }

    // MARK: - Configuration

    /// One action per tap count. The single value the engine reads; setting it
    /// clears any broken-binding state, because the user has just reconfigured
    /// and the old complaint may no longer apply.
    public var bindings: ActionBindings {
        get {
            lock.lock(); defer { lock.unlock() }
            return _bindings
        }
        set {
            lock.lock()
            let changed = _bindings != newValue
            _bindings = newValue
            if changed {
                _stats.brokenBinding = nil
                _stats.lastErrorText = nil
            }
            let snapshot = changed ? _stats : nil
            lock.unlock()
            if var snapshot {
                snapshot.emit = emitter.stats
                onChange?(snapshot)
            }
        }
    }

    /// The action bound to one tap count. `.none` when nothing is.
    public func action(for tapCount: Int) -> TunkAction { bindings[tapCount] }

    public var stats: ActionStats {
        lock.lock(); defer { lock.unlock() }
        var s = _stats
        s.emit = emitter.stats
        return s
    }

    /// The hotkey emitter, for the panel's down/up readout. Read only by
    /// convention; configure through `bindings` instead of reaching in.
    public var hotkeyEmitter: HotkeyEmitter { emitter }

    public func resetStats() {
        lock.lock(); _stats = ActionStats(); lock.unlock()
        emitter.resetStats()
    }

    /// Checks what can be checked without doing anything: Accessibility, and
    /// whether every bound hotkey pair can be built. A shortcut is deliberately
    /// not preflighted by running it — the name check below is the only
    /// validation a shortcut ever gets, and it reads a list.
    public func preflight() throws {
        for spec in bindings.hotkeySpecs {
            try emitter.preflight(spec)
        }
    }

    /// Re-checks every bound Shortcut name against the current listing and
    /// records the first that no longer resolves. Runs nothing.
    ///
    /// The engine calls this when the panel opens, on wake, and on a slow timer,
    /// so a rename is noticed before the next tap rather than after it.
    @discardableResult
    public func revalidateShortcutBindings() -> BrokenBinding? {
        let bindings = self.bindings
        let listing = resolver.listing()
        var found: BrokenBinding?
        for binding in bindings.shortcutBindings {
            // A row the user has not finished configuring is not a broken
            // binding. The picker already says "Choose a Shortcut…"; telling
            // them Tunk cannot find "" on top of that is noise, and it would put
            // the menubar into an error state for a row nobody has armed.
            guard !binding.name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let error = staleness(name: binding.name,
                                        wasListed: binding.wasListedWhenBound,
                                        listing: listing) else { continue }
            found = BrokenBinding(tapCount: binding.count, name: binding.name,
                                  text: error.userText)
            break
        }
        lock.lock()
        let changed = _stats.brokenBinding != found
        _stats.brokenBinding = found
        var snapshot = _stats
        lock.unlock()
        if changed {
            snapshot.emit = emitter.stats
            onChange?(snapshot)
        }
        return found
    }

    // MARK: - Running

    /// Run the action bound to `tapCount`.
    ///
    /// Nothing bound to that count is a quiet no-op: no error, no dialog, no
    /// text in the panel. That is what makes triple tap safe to leave unwired
    /// and single tap safe to leave unbound.
    ///
    /// Throws only on the hotkey path, and only for failures that are already
    /// `HotkeyEmitter`'s to report. A shortcut cannot throw here: it either
    /// fails the name check, which is recorded, or its failure happens later in
    /// another process and arrives through `onChange`.
    @discardableResult
    public func run(tapCount: Int) throws -> ActionStats {
        let action = bindings[tapCount]
        guard action != .none else {
            lock.lock()
            _stats.unboundCount += 1
            _stats.lastTapCount = tapCount
            var snapshot = _stats
            lock.unlock()
            snapshot.emit = emitter.stats
            return snapshot
        }
        return try run(action, tapCount: tapCount)
    }

    /// Run a specific action once. Used by each panel row's Test button, which
    /// tests the row it belongs to.
    @discardableResult
    public func run(_ action: TunkAction, tapCount: Int? = nil) throws -> ActionStats {
        let t0 = EmitClock.nowNanos()
        switch action {
        case .hotkey(let spec):
            do {
                _ = try emitter.emit(spec)
            } catch {
                _ = record(action: action, tapCount: tapCount,
                           dispatchNs: dispatch(since: t0, for: action), error: describe(error))
                throw error
            }
            return record(action: action, tapCount: tapCount,
                          dispatchNs: dispatch(since: t0, for: action), error: nil)

        case .shortcut(let name, let wasListed):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return record(action: action, tapCount: tapCount,
                              dispatchNs: dispatch(since: t0, for: action),
                              error: EmitError.noShortcutChosen.userText)
            }
            // The check that keeps a modal dialog off the screen. It reads the
            // cached listing; it does not run anything, and it costs a lock and
            // an array scan.
            if let error = staleness(name: trimmed, wasListed: wasListed,
                                     listing: resolver.listing()) {
                return recordStale(action: action, tapCount: tapCount, name: trimmed,
                                   dispatchNs: dispatch(since: t0, for: action), error: error)
            }
            // Handoff. Everything past this line happens on someone else's
            // thread; the detector gets control back at `record` below.
            spawner.spawn(shortcut: trimmed) { [weak self] outcome in
                self?.absorb(outcome)
            }
            lock.lock(); _stats.shortcutRunCount += 1; lock.unlock()
            return record(action: action, tapCount: tapCount,
                          dispatchNs: dispatch(since: t0, for: action), error: nil)

        case .none:
            return record(action: action, tapCount: tapCount,
                          dispatchNs: dispatch(since: t0, for: action), error: nil)
        }
    }

    /// What the engine calls on a confirmed gesture. The count comes from the
    /// detector; nothing here decides it.
    @discardableResult
    public func run(for trigger: Trigger) throws -> ActionStats {
        try run(tapCount: trigger.tapCount)
    }

    // MARK: - Internals

    /// Nil when the name is safe to dispatch.
    ///
    /// A listing that has never succeeded is treated as "do not dispatch", not
    /// as "assume fine". If `shortcuts list` cannot answer, Tunk has no way to
    /// tell a good name from one that will raise a dialog, and guessing wrong is
    /// the exact failure this check exists to prevent.
    private func staleness(name: String, wasListed: Bool,
                           listing: ShortcutsListing) -> EmitError? {
        guard listing.succeeded else { return .shortcutsUnreadable(name: name) }
        guard !listing.contains(name) else { return nil }
        return .shortcutMissing(name: name, wasListedWhenBound: wasListed)
    }

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

    private func record(action: TunkAction, tapCount: Int?,
                        dispatchNs: Int64, error: String?) -> ActionStats {
        lock.lock()
        _stats.runCount += 1
        _stats.lastAction = action
        if let tapCount { _stats.lastTapCount = tapCount }
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

    /// A tap that found a stale binding. Nothing was spawned. The complaint is
    /// parked in `brokenBinding` so it outlives this one tap and reaches the
    /// menubar, rather than flashing past in a panel nobody has open.
    private func recordStale(action: TunkAction, tapCount: Int?, name: String,
                             dispatchNs: Int64, error: EmitError) -> ActionStats {
        lock.lock()
        _stats.staleShortcutCount += 1
        _stats.brokenBinding = BrokenBinding(tapCount: tapCount ?? 0, name: name,
                                             text: error.userText)
        lock.unlock()
        return record(action: action, tapCount: tapCount, dispatchNs: dispatchNs,
                      error: error.userText)
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
