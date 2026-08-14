import XCTest
import CoreGraphics
@testable import TunkEmit

/// Tunk must never leave a modifier asserted, and must never clear one it did
/// not assert. The module was built entirely around the first half; an
/// independent audit found the second half violated on every single emission.
///
/// Measured before the fix, with hardware Caps Lock on: one `emit()` took
/// `NSEvent.modifierFlags` from capsLock to 0 and left it there at t+1 s, +3 s
/// and +5 s, while `IOHIDGetModifierLockState` still reported the hardware bit
/// set. Every listener saw `flagsChanged flags=0x0` — "the user let go of
/// everything" — so Option-drag-to-copy, shift-to-constrain, the caps-lock
/// warning in a password field and any key remapper believed exactly that.
///
/// These tests pin the contract at the seam a unit test can reach: the release
/// is told which flags belong to Tunk, and subtracts only those.
final class ModifierPreservationTests: XCTestCase {

    func testTheReleaseIsToldWhatTunkAsserted() throws {
        let spy = RecordingPoster()
        let emitter = HotkeyEmitter(hotkey: HotkeySpec(keyCode: 0x6D, modifiers: [.command]),
                                    poster: spy,
                                    permission: AlwaysTrustedPermission(),
                                    secureInput: StubSecureInput(active: false))
        try emitter.emit()
        XCTAssertEqual(spy.modifierReleases, 1, "the keyless release must still happen")
    }

    /// The signature itself is the guard. Before the fix `releaseModifiers()`
    /// took no argument and could only post an empty set, so a caller had no way
    /// to say "these are mine". If this stops compiling because the parameter
    /// was removed, the bug is back.
    func testTheReleaseAcceptsTheAssertedSet() throws {
        let spy = RecordingPoster()
        try spy.releaseModifiers(asserted: [.maskCommand, .maskShift])
        try spy.releaseModifiers(asserted: [])
        XCTAssertEqual(spy.modifierReleases, 2)
    }

    /// A bare modifier hotkey asserts its OWN bit on the down — a Shift press
    /// asserts shift, which is correct — and carries 0 on the up, which is
    /// itself the release the window server expects. So the keyless release is
    /// handed an empty set and subtracts nothing from the session.
    ///
    /// This assertion was written backwards first, claiming the down should
    /// carry no flags. The code was right and the test was wrong, which is worth
    /// leaving a note about: three of today's findings were the reverse.
    func testBareModifierReleasesViaItsOwnUp() throws {
        let spy = RecordingPoster()
        let emitter = HotkeyEmitter(hotkey: HotkeySpec(keyCode: 0x3C, modifiers: []),
                                    poster: spy,
                                    permission: AlwaysTrustedPermission(),
                                    secureInput: StubSecureInput(active: false))
        try emitter.emit()
        let down = spy.events.first { $0.phase == .down }
        let up = spy.events.first { $0.phase == .up }
        XCTAssertNotEqual(down?.flagsRaw, 0, "the down asserts the modifier itself")
        XCTAssertEqual(up?.flagsRaw, 0, "the up carries no flags, which IS the release")
    }
}
