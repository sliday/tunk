import ApplicationServices
import Foundation

/// Injection seam for the Accessibility check, so tests can drive both branches
/// without touching the real TCC database.
public protocol AccessibilityPermissionChecking: AnyObject, Sendable {
    var isTrusted: Bool { get }
}

/// The real check. `AXIsProcessTrustedWithOptions` with the prompt suppressed;
/// prompting is a separate, explicit call so a background trigger never throws a
/// dialog at the user mid-sentence.
public final class SystemAccessibilityPermission: AccessibilityPermissionChecking, @unchecked Sendable {
    public init() {}

    public var isTrusted: Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Asks macOS to show the "grant Accessibility" dialog. Returns the trust
    /// state as of right now, which is almost always `false` on first call: the
    /// user has to flip the switch and the process usually has to restart.
    @discardableResult
    public func requestAccess() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Deep link for a "Open Settings" button in the panel.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}

/// Always-trusted stub. Tests use it; nothing in the app should.
public final class AlwaysTrustedPermission: AccessibilityPermissionChecking, @unchecked Sendable {
    public let isTrusted: Bool
    public init(isTrusted: Bool = true) { self.isTrusted = isTrusted }
}
