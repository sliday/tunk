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
        }
    }

    public var errorDescription: String? { description }
    public var failureReason: String? { description }
}
