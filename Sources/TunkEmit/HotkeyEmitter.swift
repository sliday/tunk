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

    /// True if a key-down was posted whose key-up was not. Must never be true.
    public var hasStuckKey: Bool { keyDownsPosted > keyUpsPosted }

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
    private let lock = NSLock()
    private var _hotkey: HotkeySpec
    private var _options: Options
    private var _stats = EmitStats()

    /// Called after every emission attempt, on the calling thread, outside the
    /// lock. The menubar uses it to refresh the "fired N s ago" line.
    public var onEmit: (@Sendable (EmitStats) -> Void)?

    public init(hotkey: HotkeySpec = HotkeySpec.recommendedDefault,
                options: Options = .default,
                poster: KeyEventPosting = CGEventPoster(),
                permission: AccessibilityPermissionChecking = SystemAccessibilityPermission()) {
        self._hotkey = hotkey
        self._options = options
        self.poster = poster
        self.permission = permission
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

    /// Emit a specific combination. Used by the settings "Test" button and by
    /// the live acceptance harness.
    @discardableResult
    public func emit(_ spec: HotkeySpec, options opts: Options? = nil) throws -> EmitStats {
        let opts = opts ?? options
        let flags = spec.eventFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        let upFlags = spec.releaseFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        let down = EmittedKeyEvent(phase: .down, keyCode: spec.keyCode, flagsRaw: flags)
        let up = EmittedKeyEvent(phase: .up, keyCode: spec.keyCode, flagsRaw: upFlags)

        do {
            // Everything that can throw happens here, before a single event is
            // posted: permission, and both halves of the pair being buildable.
            // Past this line the pair is committed.
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
    private func postBalanced(down: EmittedKeyEvent, up: EmittedKeyEvent, holdNs: Int64) throws {
        var failures: [Error] = []
        do {
            defer {
                do {
                    try poster.post(up)
                    countUp()
                } catch {
                    failures.append(error)
                }
            }

            do {
                try poster.post(down)
                countDown()
            } catch {
                failures.append(error)
            }

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
        if opts.requireAccessibility && !permission.isTrusted {
            throw EmitError.accessibilityNotTrusted
        }
        let flags = spec.eventFlags(includeDeviceSide: opts.includeDeviceSideFlags).rawValue
        try poster.validate(EmittedKeyEvent(phase: .down, keyCode: spec.keyCode, flagsRaw: flags))
        try poster.validate(EmittedKeyEvent(phase: .up, keyCode: spec.keyCode, flagsRaw: flags))
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
