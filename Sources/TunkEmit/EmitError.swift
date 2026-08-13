import Foundation

/// Everything emission can fail with. Each case carries text the settings panel
/// can show verbatim; none of them are "it silently did nothing".
public enum EmitError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Accessibility is not granted, so `CGEventPost` would be a no-op. Detected
    /// before any event is posted.
    case accessibilityNotTrusted
    /// Another process holds secure event input, so the window server would
    /// drop the keystroke. Detected before posting, because `CGEvent.post`
    /// returns void and would otherwise report this as a success.
    case secureInputActive
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
    /// The bound name is not in the current listing, so it was not run.
    ///
    /// This is checked *before* dispatch on purpose. Handing an unknown name to
    /// the Shortcuts machinery puts a modal dialog on screen, and a tap gesture
    /// is easy to trigger by accident — so a stale binding would throw a dialog
    /// in the user's face repeatedly, for months, until they worked out why.
    /// `wasListedWhenBound` decides the wording: renamed, or never there.
    case shortcutMissing(name: String, wasListedWhenBound: Bool)
    /// `shortcuts list` has never come back cleanly, so Tunk cannot tell whether
    /// the bound name is still good. It refuses to guess, because guessing wrong
    /// is the modal dialog above.
    case shortcutsUnreadable(name: String)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Tunk cannot post keystrokes: Accessibility permission is not granted."
        case .secureInputActive:
            return "another app has secure input on, so macOS would discard the keystroke."
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
        case .shortcutMissing(let name, let wasListed):
            return wasListed
                ? "The Shortcut \"\(name)\" no longer exists. Pick another."
                : "Tunk cannot find a Shortcut called \"\(name)\"."
        case .shortcutsUnreadable(let name):
            return "Tunk cannot read your Shortcuts, so it did not run \"\(name)\"."
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
        case .secureInputActive:
            return "Click out of the password field that has focus. If nothing obvious has "
                 + "one, a terminal or password manager may be holding secure input; quitting "
                 + "it releases it. Tunk did not send anything, rather than reporting a "
                 + "keystroke that macOS threw away."
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
                 + "fit for a tap gesture; pick a Shortcut that runs unattended."
        case .shortcutMissing(_, let wasListed):
            return wasListed
                ? "It was there when you picked it, so it has since been renamed or deleted. "
                + "Tunk did not run anything and will not, until you choose again."
                : "Open Settings → Action and choose one from the list."
        case .shortcutsUnreadable:
            return "Open Shortcuts.app once, then press Refresh in Settings → Action. Tunk "
                 + "will not run a Shortcut it cannot first confirm exists."
        }
    }

    public var errorDescription: String? { description }
    public var failureReason: String? { description }
}
