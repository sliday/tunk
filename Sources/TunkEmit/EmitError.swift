import Foundation

/// Everything emission can fail with. Each case carries text the settings panel
/// can show verbatim; none of them are "it silently did nothing".
public enum EmitError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Accessibility is not granted, so `CGEventPost` would be a no-op. Detected
    /// before any event is posted.
    case accessibilityNotTrusted
    /// `CGEvent(keyboardEventSource:virtualKey:keyDown:)` returned nil.
    case eventCreationFailed(keyCode: UInt16)
    /// The poster refused the event.
    case postFailed(String)
    /// A hotkey string the parser could not read.
    case invalidHotkey(String, reason: String)
    /// The action is `.shortcut` but no name has been picked yet.
    case noShortcutChosen
    /// `/usr/bin/shortcuts` is not there. Shortcuts.app ships with macOS, so
    /// this means a stripped system or a sandbox, not a missing download.
    case shortcutsCLIMissing(path: String)
    /// `shortcuts run <name>` exited non-zero. `detail` is its own stderr.
    case shortcutFailed(name: String, exitCode: Int32, detail: String)
    /// The shortcut was still running when the watchdog gave up. It has not been
    /// killed; Tunk simply stopped waiting to hear about it.
    case shortcutTimedOut(name: String, seconds: TimeInterval)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Tunk cannot post keystrokes: Accessibility permission is not granted."
        case .eventCreationFailed(let keyCode):
            return "the system refused to build a key event for key code \(keyCode)."
        case .postFailed(let detail):
            return "posting the key event failed: \(detail)"
        case .invalidHotkey(let raw, let reason):
            return "\"\(raw)\" is not a valid hotkey: \(reason)."
        case .noShortcutChosen:
            return "Tunk is set to run a Shortcut, but no Shortcut has been picked."
        case .shortcutsCLIMissing(let path):
            return "the Shortcuts command line tool is missing at \(path)."
        case .shortcutFailed(let name, let code, let detail):
            return "the Shortcut \"\(name)\" failed (exit \(code)): \(detail)"
        case .shortcutTimedOut(let name, let seconds):
            return "the Shortcut \"\(name)\" has not finished after "
                 + "\(Int(seconds)) s; it is still running."
        }
    }

    /// What the user should actually do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .accessibilityNotTrusted:
            return """
                   Open System Settings → Privacy & Security → Accessibility, switch Tunk on \
                   (use + to add it if it is missing), then quit and reopen Tunk. If you are \
                   running Tunk from a terminal, grant the terminal instead. macOS caches this \
                   per binary, so the toggle must be re-flipped after you replace the app.
                   """
        case .eventCreationFailed:
            return "Pick a different key in Settings → Shortcut."
        case .postFailed:
            return "Check that Accessibility is still granted; macOS revokes it when the app binary changes."
        case .invalidHotkey:
            return "Write it like Ctrl+Opt+Cmd+; or ⌃⌥⌘; — modifiers first, one key last."
        case .noShortcutChosen:
            return "Pick one in Settings → Action, or switch the action back to a hotkey."
        case .shortcutsCLIMissing:
            return "Open Shortcuts.app once to let macOS install its command line tool."
        case .shortcutFailed:
            return "Open Shortcuts.app and run it by hand to see what it is asking for. "
                 + "A Shortcut that needs a confirmation or an app that is not open will "
                 + "fail the same way when Tunk runs it."
        case .shortcutTimedOut:
            return "Nothing was cancelled. If it waits for you every time, it is not a good "
                 + "fit for a double-tap; pick a Shortcut that runs unattended."
        }
    }

    public var errorDescription: String? { description }
    public var failureReason: String? { description }
}
