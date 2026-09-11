import CoreGraphics
import Darwin
import Foundation
import TunkCore

/// Converts `mach_absolute_time()` ticks to nanoseconds, the one clock in
/// FORMAT.md. Internal on purpose: the emitter may read a clock, the detector
/// may not, and nothing should be able to borrow this from here.
enum EmitClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    @inline(__always)
    static func nowNanos() -> Int64 {
        Int64(mach_absolute_time() &* UInt64(timebase.numer) / UInt64(timebase.denom))
    }
}

/// What the menubar shows and what the live acceptance test counts.
public struct EmitStats: Sendable, Equatable {
    /// Successful emissions (one confirmed double-tap = one emission).
    public var emitCount: Int = 0
    /// Emissions that threw. Included so a permission problem is visible as a
    /// number, not just as a missing count.
    public var failureCount: Int = 0
    /// `mach_absolute_time()` ns of the last successful emission, same timebase
    /// as every `t_ns` in the dataset. Nil until the first emission.
    public var lastEmitMachNs: Int64?
    /// Wall clock of the last successful emission, for "fired 3 s ago".
    public var lastEmitDate: Date?
    /// The combination last emitted.
    public var lastEmitted: HotkeySpec?
    /// Human text of the last failure, for the settings panel.
    public var lastErrorText: String?

    /// Key-downs and key-ups the emitter actually handed to the poster. The
    /// stuck-modifier invariant is `keyUpsPosted >= keyDownsPosted`, always.
    public var keyDownsPosted: Int = 0
    public var keyUpsPosted: Int = 0

    /// `mach_absolute_time()` ns of the moment the last key-down went out.
    ///
    /// This, not the return of `emit()`, is when the keystroke reached the
    /// system: the key is then deliberately held for `keyDownHoldNs` before the
    /// up, and that hold is not latency. `ActionRunner` measures dispatch
    /// latency to this stamp. Nil until a key-down has actually been posted.
    public var lastKeyDownMachNs: Int64?

    /// Pairs that got as far as posting a key-down.
    public var pairsCompleted: Int = 0
    /// Pairs whose key-down went out and whose key-up did not. This is the
    /// stuck-modifier failure, counted per emission.
    ///
    /// The aggregate `keyDownsPosted > keyUpsPosted` cannot see an interleaving:
    /// three downs followed by three ups sums to balanced while the middle of it
    /// held three keys at once. This counter and the serial post queue address
    /// the two halves of that — one makes it visible, the other makes it
    /// impossible.
    public var unbalancedPairs: Int = 0

    /// True if any key-down was posted whose key-up was not. Must never be true.
    public var hasStuckKey: Bool { unbalancedPairs > 0 }

    /// Seconds since the last emission, for "fired 3 s ago". Nil if never fired.
    public func secondsSinceLastEmit(now: Date = Date()) -> TimeInterval? {
        lastEmitDate.map { now.timeIntervalSince($0) }
    }

    public init() {}
}

/// Posts the configured global hotkey when the detector confirms a double-tap.
///
/// The one hard rule (PRD, FORMAT.md scoring table): never leave a stuck
/// modifier. Structure, not diligence, is what guarantees it here:
///
/// 1. Both halves of the pair are built and validated before either is posted,
///    so nothing can fail *between* the down and the up.
/// 2. The key-up is posted from a `defer` in the same scope as the key-down.
///    Any early return, thrown error or future edit inside that scope still
///    runs the up.
/// 3. `postBalanced` is the only place in this module that posts a key-down.
///
/// Modifiers ride as flags on both events rather than as separate modifier key
/// presses, so there is no second class of down/up pair to keep balanced.
public final class HotkeyEmitter: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        /// Mimic hardware by setting the left-side device-dependent modifier
        /// bits as well as the device-independent ones.
        public var includeDeviceSideFlags: Bool
        /// How long the key stays down. 8 ms costs nothing against the 250 ms
        /// latency budget (it lands after the down, which is what latency is
        /// measured to) and keeps listeners that poll key state happy.
        public var keyDownHoldNs: Int64
        /// Refuse to post when Accessibility is not granted. Off only in tests.
        public var requireAccessibility: Bool

        public static let `default` = Options(includeDeviceSideFlags: true,
                                              keyDownHoldNs: 8_000_000,
                                              requireAccessibility: true)

        public init(includeDeviceSideFlags: Bool, keyDownHoldNs: Int64, requireAccessibility: Bool) {
            self.includeDeviceSideFlags = includeDeviceSideFlags
            self.keyDownHoldNs = keyDownHoldNs
            self.requireAccessibility = requireAccessibility
        }
    }

    private let poster: KeyEventPosting
    private let permission: AccessibilityPermissionChecking
    private let secureInput: SecureInputChecking
    private let lock = NSLock()
    private var _hotkey: HotkeySpec
    private var _options: Options
    private var _stats = EmitStats()

    /// Held for the whole of one key pair, so two emissions can never interleave
    /// into N key-downs before any key-up — each pair individually balanced,
    /// the system's modifier state briefly not.
    ///
    /// A lock rather than a serial queue, and that is deliberate. Routing the
    /// synchronous path through `queue.sync` also moved `CGEvent.post` onto a
    /// different thread from the caller, and measured against a live
    /// `CGEventTap` that left the modifier flags asserted in the session two
    /// seconds after the pair went out — a real stuck modifier, caught by
    /// `HotkeyEmitterLiveTapTests`. A lock serialises without moving the post.
    private let postLock = NSLock()

    /// Where `emitAsync` runs the pair. Only the asynchronous path hops threads;
    /// it has to, because its caller is the 796 Hz sensor callback and the pair
    /// deliberately holds the key down for 8 ms.
    ///
    /// `.userInteractive` because this is a keystroke the user is waiting on.
    private let postQueue = DispatchQueue(label: "dev.tunk.emit.post", qos: .userInteractive)

    /// Blocks until any in-flight pair has finished posting.
    ///
    /// A pair holds its key down for 8 ms on `postQueue`, and macOS does not
    /// clean up after a posting process dies — measured, a child that posted a
    /// key-down with maskControl and exited left the session at 0x40000 at
    /// t+0.5 s and t+2.5 s. Called from `applicationWillTerminate` so a normal
    /// quit cannot leave a chord asserted with nothing running to release it.
    public func drainPending() {
        postQueue.sync {}
    }

    /// Called after every emission attempt, outside the lock, on whichever
    /// thread ran the emission — the post queue for `emitAsync`, the caller's
    /// thread for `emit`. The menubar uses it to refresh the "fired N s ago" line.
    public var onEmit: (@Sendable (EmitStats) -> Void)?

    public init(hotkey: HotkeySpec = HotkeySpec.recommendedDefault,
                options: Options = .default,
                poster: KeyEventPosting = CGEventPoster(),
                permission: AccessibilityPermissionChecking = SystemAccessibilityPermission(),
                secureInput: SecureInputChecking = SystemSecureInput()) {
        self._hotkey = hotkey
        self._options = options
        self.poster = poster
        self.permission = permission
        self.secureInput = secureInput
    }

    // MARK: - Configuration

    public var hotkey: HotkeySpec {
        get { lock.lock(); defer { lock.unlock() }; return _hotkey }
        set { lock.lock(); _hotkey = newValue; lock.unlock() }
    }

    public var options: Options {
        get { lock.lock(); defer { lock.unlock() }; return _options }
        set { lock.lock(); _options = newValue; lock.unlock() }
    }

    public var stats: EmitStats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    public func resetStats() {
        lock.lock(); _stats = EmitStats(); lock.unlock()
    }

    // MARK: - Emission

    /// Checks everything that can be checked without posting: permission, and
    /// whether both halves of the pair can be built. Call it at launch and when
    /// the shortcut changes so the panel can show the problem before a tap does.
    public func preflight() throws {
        let (spec, opts) = currentConfig()
        try preflight(spec: spec, options: opts)
    }

    /// Same check for a combination that is not the configured one. Needed once
    /// more than one hotkey can be bound at a time (one per tap count).
    public func preflight(_ spec: HotkeySpec) throws {
        try preflight(spec: spec, options: options)
    }

    /// Emit the configured hotkey.
    @discardableResult
    public func emit() throws -> EmitStats {
        let (spec, opts) = currentConfig()
        return try emit(spec, options: opts)
    }

    /// Emit a specific combination, and wait for it. Used by the settings "Test"
    /// button, by the live acceptance harness and by the tests.
    ///
    /// Blocks the calling thread for `keyDownHoldNs`. **Never call this from the
    /// sensor callback** — use `emitAsync`. The hold is 8 ms and the callback
    /// arrives every 1.26 ms, so blocking it drops about six samples per
    /// emission and corrupts the very stream the gesture was detected in.
    @discardableResult
    public func emit(_ spec: HotkeySpec, options opts: Options? = nil) throws -> EmitStats {
        // On the caller's own thread, holding the lock the async path also
        // takes, so both entry points are ordered against each other and a pair
        // can never interleave with another pair.
        try perform(spec, options: opts)
    }

    /// Emit without waiting. Hands the pair to the post queue and returns in
    /// microseconds; the caller learns the outcome through `onEmit` and `stats`.
    ///
    /// This is the detector's path. `Thread.sleep` inside the pair used to run
    /// on whatever thread called `emit`, which in production is the 796 Hz HID
    /// delivery callback — FORMAT.md's measured 0.34 ms p95 callback lag cannot
    /// survive an 8 ms sleep in it.
    public func emitAsync(_ spec: HotkeySpec? = nil, options opts: Options? = nil) {
        let spec = spec ?? hotkey
        postQueue.async { [weak self] in
            _ = try? self?.perform(spec, options: opts)
        }
    }

    /// Shared body, and the only holder of `postLock`. One pair at a time,
    /// whichever entry point started it and whichever thread it runs on.
    @discardableResult
    private func perform(_ spec: HotkeySpec, options opts: Options?) throws -> EmitStats {
        postLock.lock()
        defer { postLock.unlock() }
        let opts = opts ?? options
        let flags = spec.eventFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        let upFlags = spec.releaseFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        let down = EmittedKeyEvent(phase: .down, keyCode: spec.keyCode, flagsRaw: flags)
        let up = EmittedKeyEvent(phase: .up, keyCode: spec.keyCode, flagsRaw: upFlags)

        do {
            // Everything that can throw happens here, before a single event is
            // posted: permission, secure input, and both halves of the pair
            // being buildable. Past this line the pair is committed.
            try preflight(spec: spec, options: opts)

            try postBalanced(down: down, up: up, holdNs: opts.keyDownHoldNs)
            return recordSuccess(spec)
        } catch {
            _ = recordFailure(error)
            throw error
        }
    }

    /// Convenience for the app: fire on a confirmed gesture. Returns the stats
    /// snapshot so the caller can log latency against `trigger.tNs`.
    @discardableResult
    public func emit(for trigger: Trigger) throws -> EmitStats {
        try emit()
    }

    // MARK: - The funnel

    /// The only place a key-down is posted. Do not add a second one.
    ///
    /// The key-up sits in a `defer` attached to the same scope, so it runs on
    /// every exit path: normal, thrown, or whatever someone adds later. Errors
    /// from either half are collected and rethrown only after the up has gone
    /// out, so no error path can skip it.
    ///
    /// Balance is recorded per pair, not only in totals. Aggregate counters
    /// cannot see an interleaving — three downs then three ups sums to balanced
    /// while the middle of it had three keys held at once. `postQueue` makes
    /// that impossible, and `unbalancedPairs` makes it detectable if it ever
    /// becomes possible again.
    ///
    /// The modifier release is the third thing this scope guarantees. The pair
    /// asserts modifier flags on both halves deliberately, and nothing in the
    /// pair ever drops them — measured, the window server then reports the chord
    /// as held indefinitely, across processes, until some later event says
    /// otherwise. So the release sits in the same `defer` as the up, after it,
    /// and runs on every path the up runs on.
    private func postBalanced(down: EmittedKeyEvent, up: EmittedKeyEvent, holdNs: Int64) throws {
        var failures: [Error] = []
        var downWentOut = false
        var upWentOut = false
        defer { recordPair(downPosted: downWentOut, upPosted: upWentOut) }
        do {
            defer {
                do {
                    try poster.post(up)
                    upWentOut = true
                    countUp()
                } catch {
                    failures.append(error)
                }
                // After the up, unconditionally. A failed up is exactly when a
                // modifier is most likely to be left asserted, so this must not
                // be skipped because the up threw.
                if up.flagsRaw != 0 {
                    do { try poster.releaseModifiers(asserted: CGEventFlags(rawValue: up.flagsRaw)) }
                    catch { failures.append(error) }
                }
            }

            do {
                try poster.post(down)
                downWentOut = true
                countDown()
            } catch {
                failures.append(error)
            }

            // Sleeping here is safe *because of the queue*: `emitAsync` runs
            // this on `postQueue`, not on the caller's thread. Anything that
            // moves this call back onto a caller's thread puts the 8 ms sleep
            // back into the sensor callback.
            if holdNs > 0 {
                Thread.sleep(forTimeInterval: Double(holdNs) / 1_000_000_000)
            }
        }
        if let first = failures.first {
            throw (first as? EmitError) ?? EmitError.postFailed(String(describing: first))
        }
    }

    // MARK: - Internals

    private func preflight(spec: HotkeySpec, options opts: Options) throws {
        // Secure event input. Any password field anywhere on the system takes
        // it, and while it is held `CGEvent.post` is silently dropped. The API
        // returns void and cannot fail, so without this check a swallowed
        // keystroke is recorded as a successful emission: the count goes up,
        // the panel says "fired", and nothing happened. Checked before posting
        // so the failure is honest rather than invisible.
        if opts.requireAccessibility && secureInput.isSecureInputActive {
            throw EmitError.secureInputActive
        }
        if opts.requireAccessibility && !permission.isTrusted {
            throw EmitError.accessibilityNotTrusted
        }
        // Both halves validated AS THEY WILL BE POSTED. The up used to be
        // validated with the DOWN's flags, so `RShift` validated
        // ["down:0x20004", "up:0x20004"] and posted ["down:0x20004", "up:0x0"].
        // Harmless today, because CGEvent creation ignores flags — but the class
        // docstring rests on "both halves are built and validated before either
        // is posted", which is the load-bearing claim for "nothing can fail
        // between the down and the up". A guarantee that validates a different
        // event than it posts is not that guarantee.
        let flags = spec.eventFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        let upFlags = spec.releaseFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        try poster.validate(EmittedKeyEvent(phase: .down, keyCode: spec.keyCode, flagsRaw: flags))
        try poster.validate(EmittedKeyEvent(phase: .up, keyCode: spec.keyCode, flagsRaw: upFlags))
    }

    private func currentConfig() -> (HotkeySpec, Options) {
        lock.lock(); defer { lock.unlock() }
        return (_hotkey, _options)
    }

    private func countDown() {
        let now = EmitClock.nowNanos()
        lock.lock()
        _stats.keyDownsPosted += 1
        _stats.lastKeyDownMachNs = now
        lock.unlock()
    }

    /// One pair's own verdict, recorded whatever happened inside it. A down that
    /// went out without its up is the stuck-modifier failure, and this is the
    /// only place it can be seen as a single event rather than as a total.
    private func recordPair(downPosted: Bool, upPosted: Bool) {
        guard downPosted else { return }
        lock.lock()
        _stats.pairsCompleted += 1
        if !upPosted { _stats.unbalancedPairs += 1 }
        lock.unlock()
    }

    private func countUp() {
        lock.lock(); _stats.keyUpsPosted += 1; lock.unlock()
    }

    private func recordSuccess(_ spec: HotkeySpec) -> EmitStats {
        lock.lock()
        _stats.emitCount += 1
        _stats.lastEmitMachNs = EmitClock.nowNanos()
        _stats.lastEmitDate = Date()
        _stats.lastEmitted = spec
        _stats.lastErrorText = nil
        let snapshot = _stats
        lock.unlock()
        onEmit?(snapshot)
        return snapshot
    }

    private func recordFailure(_ error: Error) -> EmitStats {
        lock.lock()
        _stats.failureCount += 1
        _stats.lastErrorText = describe(error)
        let snapshot = _stats
        lock.unlock()
        onEmit?(snapshot)
        return snapshot
    }

    private func describe(_ error: Error) -> String {
        guard let e = error as? EmitError else { return String(describing: error) }
        guard let fix = e.recoverySuggestion else { return e.description }
        return "\(e.description) \(fix)"
    }
}
