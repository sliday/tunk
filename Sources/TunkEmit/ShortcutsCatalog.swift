import Foundation

/// The user's Shortcuts, by name, for the settings panel's dropdown.
///
/// `shortcuts list` is read-only and measured at roughly 10 ms on this machine,
/// which is fine on the main thread when a panel opens and nowhere near the
/// detector's path. It is cached anyway, because the panel asks for it on every
/// redraw and the list only changes when the user edits Shortcuts.app.
///
/// ## Safety
///
/// This type lists. It never runs. A user's library contains things like
/// "Twitter" and "Track My Orders" with real side effects, so nothing here — and
/// nothing anywhere in Tunk — may run a shortcut to probe it, validate it, warm
/// it up or benchmark it. A shortcut runs when the user double-taps, or when
/// they press Test. Those are the only two.
/// The result of one `shortcuts list`.
///
/// `succeeded` is the load-bearing field. An empty `names` means two very
/// different things — the library is empty, or the listing itself broke — and
/// the difference decides whether a bound name is treated as deleted. Collapsing
/// them would let a three-second timeout silently look like the user deleting
/// every Shortcut they own.
public struct ShortcutsListing: Sendable, Equatable {
    public var names: [String]
    public var succeeded: Bool

    public init(names: [String], succeeded: Bool) {
        self.names = names
        self.succeeded = succeeded
    }

    /// Never listed successfully. Distinct from a successful empty listing.
    public static let unknown = ShortcutsListing(names: [], succeeded: false)

    public func contains(_ name: String) -> Bool {
        names.contains(name.trimmingCharacters(in: .whitespaces))
    }
}

/// Answers "does this Shortcut still exist?" without running anything.
///
/// Injected into `ActionRunner` so the stale-name check can be driven in tests
/// without a Shortcuts library.
public protocol ShortcutNameResolving: AnyObject, Sendable {
    func listing() -> ShortcutsListing
    /// The cached listing, or nil. Must never block or spawn — see
    /// `ShortcutsCatalog.cachedListing`.
    func cachedListing() -> ShortcutsListing?
}

public extension ShortcutNameResolving {
    /// Conformers that predate the hot-path split fall back to the blocking
    /// call, which is correct for tests and for the panel.
    func cachedListing() -> ShortcutsListing? { listing() }
}

/// The real resolver: whatever `ShortcutsCatalog` last listed.
public final class CatalogNameResolver: ShortcutNameResolving, @unchecked Sendable {
    public init() {}
    public func listing() -> ShortcutsListing { ShortcutsCatalog.listing() }
    public func cachedListing() -> ShortcutsListing? { ShortcutsCatalog.cachedListing() }
}

public enum ShortcutsCatalog {
    /// Deliberately generous. `shortcuts list` normally answers in ~10 ms; if it
    /// is wedged, the panel gets an empty list and a refresh button rather than a
    /// beachball.
    public static let listTimeout: TimeInterval = 3.0

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: ShortcutsListing?

    /// Cached names, listing on first call. Never throws: a missing CLI, a
    /// sandboxed process or an empty library all read as "no Shortcuts found",
    /// which is a state the panel already has to draw.
    public static func available() -> [String] { listing().names }

    /// The cached listing, including whether it worked. Lists on first call.
    /// The cache, or nil if it has never been filled. Never spawns.
    ///
    /// `listing()` falls through to `refreshListing()` on a cold cache, which
    /// spawns `shortcuts list` and waits up to 3 s. On the action path the
    /// caller is the sensor callback, so a cold cache put a subprocess on the
    /// 796 Hz thread: measured, the shortcut path costs 14.3 ms cold against
    /// 7 microseconds warm. Engine warms it asynchronously at launch, so this is
    /// a startup race rather than a standing bug — but "the warm-up usually
    /// wins" is not a guarantee, and the hot path should not be able to spawn.
    public static func cachedListing() -> ShortcutsListing? {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    public static func listing() -> ShortcutsListing {
        lock.lock()
        if let cache {
            lock.unlock()
            return cache
        }
        lock.unlock()
        return refreshListing()
    }

    /// Re-lists and replaces the cache. The settings panel calls this when it
    /// opens and when the user presses the refresh control, and the engine calls
    /// it on wake and on a slow timer, so a Shortcut renamed while Tunk was
    /// running is noticed before the next tap rather than after it.
    @discardableResult
    public static func refresh() -> [String] { refreshListing().names }

    @discardableResult
    public static func refreshListing() -> ShortcutsListing {
        let fresh = list()
        lock.lock()
        // A failed listing must not overwrite a good one. Losing the known-good
        // names because the CLI was busy for three seconds would make every
        // binding look deleted until the next successful refresh.
        if fresh.succeeded || cache == nil { cache = fresh }
        let result = cache ?? fresh
        lock.unlock()
        return result
    }

    /// Drops the cache without listing. Tests use it; the app has no reason to.
    public static func invalidate() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    /// True when the Shortcuts CLI exists at all. Distinguishes "no Shortcuts"
    /// from "no Shortcuts.app", which need different words in the panel.
    public static var isCLIAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ShortcutsProcessSpawner.executablePath)
    }

    // MARK: - The listing itself

    private static func list() -> ShortcutsListing {
        let path = ShortcutsProcessSpawner.executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else { return .unknown }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["list"]

        let outPipe = Pipe()
        let out = TextBox(cap: 1 << 20)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { out.append(chunk) }
        }
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            done.signal()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            return .unknown
        }

        if done.wait(timeout: .now() + listTimeout) == .timedOut {
            // Listing is read-only, so terminating it is safe in a way that
            // terminating a `run` would not be.
            process.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            return .unknown
        }
        guard process.terminationStatus == 0 else { return .unknown }

        // A clean exit is a real answer, even when it names nothing: that user
        // genuinely has no Shortcuts.
        return ShortcutsListing(names: parse(out.text), succeeded: true)
    }

    /// One name per line. Blank lines dropped, order preserved (the CLI already
    /// sorts), duplicates collapsed — two shortcuts may share a name, and the
    /// dropdown cannot tell them apart anyway.
    static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }
}
