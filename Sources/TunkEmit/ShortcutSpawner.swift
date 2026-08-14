import Foundation

/// How a shortcut run ended. Delivered asynchronously, on whatever queue the
/// spawner happens to be on, and always after `ActionRunner.run` has returned.
public struct ShortcutOutcome: Sendable, Equatable {
    public var name: String
    /// Handoff to the shortcut actually finishing. Best effort, reported only —
    /// nothing in Tunk waits on it or gates on it. See `ActionStats` for why the
    /// two latencies are kept apart.
    public var completionLatencyNs: Int64
    /// Nil on success. A non-zero exit, a missing CLI, or the watchdog giving up.
    public var error: EmitError?

    public init(name: String, completionLatencyNs: Int64, error: EmitError?) {
        self.name = name
        self.completionLatencyNs = completionLatencyNs
        self.error = error
    }

    public var succeeded: Bool { error == nil }
}

/// Starts a macOS Shortcut and returns immediately.
///
/// The contract is the whole point of this protocol, so it is spelled out:
/// `spawn` must not block the caller, must not wait for the shortcut, and must
/// not throw. Everything that can go wrong is reported through `completion`,
/// which fires exactly once, later, off the caller's thread.
///
/// Tunk calls this from the detector's sample thread. A shortcut that hangs for
/// a minute must cost that thread nothing.
public protocol ShortcutSpawning: AnyObject, Sendable {
    func spawn(shortcut name: String,
               completion: @escaping @Sendable (ShortcutOutcome) -> Void)
}

/// Runs `/usr/bin/shortcuts run <name>` as a detached child process.
///
/// Why not the URL scheme: `NSWorkspace.open("shortcuts://run-shortcut?name=…")`
/// was measured on this machine at p50 38 ms and a max of 345 ms. One call could
/// spend more than the PRD's entire 250 ms p95 latency budget. Spawning the CLI
/// measured p50 0.27 ms, max 0.81 ms. So: spawn, never the URL.
///
/// Even 0.81 ms is more than the detector should ever pay, so `run()` itself
/// happens on a background queue and `spawn` returns after a `DispatchQueue`
/// enqueue — tens of microseconds, and bounded by nothing the shortcut does.
public final class ShortcutsProcessSpawner: ShortcutSpawning, @unchecked Sendable {
    public static let executablePath = "/usr/bin/shortcuts"

    /// How long to wait before telling the user a shortcut has not come back.
    /// The process is deliberately left running: a half-finished "Track My
    /// Orders" is worse than a slow one, and killing a user's automation to
    /// tidy up a status line is not Tunk's call.
    public static let defaultWatchdogSeconds: TimeInterval = 30

    /// Cap on captured stderr. Enough for the CLI's one-line complaints without
    /// letting a chatty shortcut grow the panel's error string without bound.
    private static let stderrCap = 4096

    private let executable: String
    private let watchdog: TimeInterval
    /// Concurrent on purpose: a hung shortcut must not delay the next spawn.
    /// Nothing here waits, so this queue never holds a thread for long.
    private let queue = DispatchQueue(label: "dev.tunk.shortcut.spawn",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    public init(executable: String = ShortcutsProcessSpawner.executablePath,
                watchdogSeconds: TimeInterval = ShortcutsProcessSpawner.defaultWatchdogSeconds) {
        self.executable = executable
        self.watchdog = watchdogSeconds
    }

    public func spawn(shortcut name: String,
                      completion: @escaping @Sendable (ShortcutOutcome) -> Void) {
        let started = EmitClock.nowNanos()
        let once = OneShot(completion)
        let executable = self.executable
        let watchdog = self.watchdog

        queue.async {
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                once.fire(ShortcutOutcome(name: name,
                                          completionLatencyNs: EmitClock.nowNanos() - started,
                                          error: .shortcutsCLIMissing(path: executable)))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["run", name]

            // Drained asynchronously. An unread pipe fills at 64 KB and then
            // blocks the child, which would turn a chatty shortcut into a hang.
            let errPipe = Pipe()
            let errText = TextBox(cap: Self.stderrCap)
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errText.append(chunk)
                }
            }
            process.standardError = errPipe
            // Whoever fires the completion first — real termination or the
            // watchdog — must also detach the reader and close the pipe. Firing
            // alone left both ends open for as long as the child lived, and a
            // child that trips the watchdog is by definition one that does not
            // exit. Measured: 60 hung spawns took /dev/fd from 4 to 124 and it
            // stayed there after every completion had fired; 200 clean spawns
            // leaked nothing. A Shortcut waiting on user input plus a user who
            // keeps tapping walks the app to its file-descriptor limit.
            once.onFire = {
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? errPipe.fileHandleForReading.close()
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            // Set before `run()`: a fast shortcut can exit before the next line.
            process.terminationHandler = { proc in
                errPipe.fileHandleForReading.readabilityHandler = nil
                let elapsed = EmitClock.nowNanos() - started
                let code = proc.terminationStatus
                guard code != 0 || proc.terminationReason != .exit else {
                    once.fire(ShortcutOutcome(name: name, completionLatencyNs: elapsed, error: nil))
                    return
                }
                let detail = errText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                once.fire(ShortcutOutcome(
                    name: name,
                    completionLatencyNs: elapsed,
                    error: .shortcutFailed(name: name, exitCode: code,
                                           detail: detail.isEmpty ? "exit status \(code)" : detail)))
            }

            do {
                try process.run()
            } catch {
                errPipe.fileHandleForReading.readabilityHandler = nil
                once.fire(ShortcutOutcome(
                    name: name,
                    completionLatencyNs: EmitClock.nowNanos() - started,
                    error: .shortcutFailed(name: name, exitCode: -1,
                                           detail: String(describing: error))))
            }
        }

        guard watchdog > 0 else { return }
        queue.asyncAfter(deadline: .now() + watchdog) {
            once.fire(ShortcutOutcome(name: name,
                                      completionLatencyNs: EmitClock.nowNanos() - started,
                                      error: .shortcutTimedOut(name: name, seconds: watchdog)))
        }
    }
}

/// Guarantees the completion handler runs at most once. The watchdog and the
/// real termination race by design; whichever arrives first wins and the other
/// is dropped.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ShortcutOutcome) -> Void)?
    private var cleanup: (@Sendable () -> Void)?

    init(_ handler: @escaping @Sendable (ShortcutOutcome) -> Void) {
        self.handler = handler
    }

    /// Runs once, whichever path fires first. Used to close the stderr pipe:
    /// the watchdog path used to fire the completion and leave the pipe open.
    var onFire: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return cleanup }
        set { lock.lock(); cleanup = newValue; lock.unlock() }
    }

    func fire(_ outcome: ShortcutOutcome) {
        lock.lock()
        let h = handler
        let c = cleanup
        handler = nil
        cleanup = nil
        lock.unlock()
        c?()
        h?(outcome)
    }
}

/// Bounded, thread-safe accumulator for a child's stderr.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < cap { data.append(chunk.prefix(cap - data.count)) }
        lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
