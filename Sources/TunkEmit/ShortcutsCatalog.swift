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
public enum ShortcutsCatalog {
    /// Deliberately generous. `shortcuts list` normally answers in ~10 ms; if it
    /// is wedged, the panel gets an empty list and a refresh button rather than a
    /// beachball.
    public static let listTimeout: TimeInterval = 3.0

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String]?

    /// Cached names, listing on first call. Never throws: a missing CLI, a
    /// sandboxed process or an empty library all read as "no Shortcuts found",
    /// which is a state the panel already has to draw.
    public static func available() -> [String] {
        lock.lock()
        if let cache {
            lock.unlock()
            return cache
        }
        lock.unlock()
        return refresh()
    }

    /// Re-lists and replaces the cache. The settings panel calls this when it
    /// opens and when the user presses the refresh control, so a Shortcut added
    /// while Tunk was running shows up without a relaunch.
    @discardableResult
    public static func refresh() -> [String] {
        let names = list()
        lock.lock()
        cache = names
        lock.unlock()
        return names
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

    private static func list() -> [String] {
        let path = ShortcutsProcessSpawner.executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else { return [] }

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
            return []
        }

        if done.wait(timeout: .now() + listTimeout) == .timedOut {
            // Listing is read-only, so terminating it is safe in a way that
            // terminating a `run` would not be.
            process.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            return []
        }

        return parse(out.text)
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
