import ApplicationServices
import Carbon.HIToolbox
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

/// Injection seam for the secure-event-input check.
public protocol SecureInputChecking: AnyObject, Sendable {
    var isSecureInputActive: Bool { get }
}

/// The real check.
///
/// While any process holds secure event input — every password field does, plus
/// some terminals and password managers — the window server drops synthetic key
/// events. `CGEvent.post` returns void and cannot report it, so an emission that
/// went nowhere is indistinguishable from one that worked unless this is asked
/// first. It is cheap: a Carbon call that reads a global flag.
///
/// It says nothing about *who* holds it. Naming the process needs a private
/// SkyLight call, and a wrong name would be worse than none.
public final class SystemSecureInput: SecureInputChecking, @unchecked Sendable {
    public init() {}
    public var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}

/// Fixed answer. Tests use it; nothing in the app should.
public final class StubSecureInput: SecureInputChecking, @unchecked Sendable {
    public let isSecureInputActive: Bool
    public init(active: Bool = false) { self.isSecureInputActive = active }
}
