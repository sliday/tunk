import CoreGraphics
import Foundation

/// One synthetic key event, described in plain data so a test can record it.
public struct EmittedKeyEvent: Sendable, Equatable, CustomStringConvertible {
    public enum Phase: String, Sendable, Equatable, Codable {
        case down, up
    }

    public var phase: Phase
    public var keyCode: UInt16
    /// Raw `CGEventFlags`. Identical on the down and the up of one emission.
    public var flagsRaw: UInt64

    public init(phase: Phase, keyCode: UInt16, flagsRaw: UInt64) {
        self.phase = phase
        self.keyCode = keyCode
        self.flagsRaw = flagsRaw
    }

    public var flags: CGEventFlags { CGEventFlags(rawValue: flagsRaw) }

    public var description: String {
        "\(phase.rawValue) key=\(KeyCodes.name(for: keyCode)) flags=0x\(String(flagsRaw, radix: 16))"
    }
}

/// Where key events go. The real implementation talks to CoreGraphics; tests
/// substitute a recorder so the down/up balance can be asserted without needing
/// Accessibility permission in the test process.
public protocol KeyEventPosting: AnyObject {
    /// Prove this event can be built and posted, without posting it. The emitter
    /// validates both halves of a pair *before* posting either, so a failure can
    /// never strand a key-down.
    func validate(_ event: EmittedKeyEvent) throws

    func post(_ event: EmittedKeyEvent) throws
}

public extension KeyEventPosting {
    func validate(_ event: EmittedKeyEvent) throws {}
}

/// Posts to the HID event tap location, the same place hardware key events
/// enter, so every hotkey listener in the system sees them: Carbon
/// `RegisterEventHotKey`, `NSEvent` global monitors and CGEventTap clients alike.
public final class CGEventPoster: KeyEventPosting {
    /// Stamped into `eventSourceUserData` on every event Tunk posts, so a tap
    /// (ours, in tests; anyone's, in the field) can tell our events from the
    /// user's fingers.
    public static let userDataTag: Int64 = 0x54_55_4E_4B  // "TUNK"

    private let source: CGEventSource?
    private let tapLocation: CGEventTapLocation

    /// - Parameter stateID: `.privateState` by default. That keeps the user's
    ///   physically held modifiers out of our synthetic event; with
    ///   `.hidSystemState` a hand resting on Shift would leak into the flags.
    public init(stateID: CGEventSourceStateID = .privateState,
                tapLocation: CGEventTapLocation = .cghidEventTap) {
        self.source = CGEventSource(stateID: stateID)
        self.tapLocation = tapLocation
    }

    public func validate(_ event: EmittedKeyEvent) throws {
        guard makeEvent(event) != nil else {
            throw EmitError.eventCreationFailed(keyCode: event.keyCode)
        }
    }

    public func post(_ event: EmittedKeyEvent) throws {
        guard let cg = makeEvent(event) else {
            throw EmitError.eventCreationFailed(keyCode: event.keyCode)
        }
        cg.post(tap: tapLocation)
    }

    private func makeEvent(_ event: EmittedKeyEvent) -> CGEvent? {
        guard let cg = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(event.keyCode),
                               keyDown: event.phase == .down) else { return nil }
        // A modifier does not produce key-down / key-up. Pressing Right Shift
        // raises a flagsChanged, and a listener bound to it watches for exactly
        // that; a synthesized key-down with keycode 60 would be ignored.
        if KeyCodes.isModifier(event.keyCode) {
            cg.type = .flagsChanged
        }
        // Flags go on both halves: a listener that reads them off the key-up
        // (VoiceInk's toggle mode does) must see the same combination. The
        // caller clears the key's own bit on the release half.
        cg.flags = event.flags
        cg.setIntegerValueField(.eventSourceUserData, value: Self.userDataTag)
        return cg
    }
}

/// Records instead of posting. Used by the balance tests and by `--dry-run`.
public final class RecordingPoster: KeyEventPosting, @unchecked Sendable {
    public enum FailMode: Sendable, Equatable {
        case none
        case onValidate(EmittedKeyEvent.Phase)
        case onPost(EmittedKeyEvent.Phase)
    }

    private let lock = NSLock()
    private var _events: [EmittedKeyEvent] = []
    public var failMode: FailMode

    public init(failMode: FailMode = .none) { self.failMode = failMode }

    public var events: [EmittedKeyEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        _events.removeAll()
    }

    public func validate(_ event: EmittedKeyEvent) throws {
        if case .onValidate(let phase) = failMode, phase == event.phase {
            throw EmitError.eventCreationFailed(keyCode: event.keyCode)
        }
    }

    public func post(_ event: EmittedKeyEvent) throws {
        if case .onPost(let phase) = failMode, phase == event.phase {
            throw EmitError.postFailed("injected failure on \(phase.rawValue)")
        }
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }
}
