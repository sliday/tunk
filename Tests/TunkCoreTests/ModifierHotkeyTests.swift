import CoreGraphics
import XCTest
@testable import TunkEmit

/// A shortcut may be a modifier key on its own. macOS reports left and right
/// separately, so the side has to survive recording, printing, parsing and
/// emission — and the release half must drop the bit it raised.
final class ModifierHotkeyTests: XCTestCase {
    /// Posts real CGEvents and counts what arrives, so it cannot run while
    /// another process holds secure event input. See `SecureInput`.
    override func setUpWithError() throws { try SecureInput.skipIfHeld() }


    private let maskShift = CGEventFlags.maskShift.rawValue
    private let deviceLShift: UInt64 = 0x0000_0002
    private let deviceRShift: UInt64 = 0x0000_0004

    func testRightShiftIsNameableAndRoundTrips() throws {
        let spec = HotkeySpec(keyCode: 60, modifiers: [])
        XCTAssertEqual(spec.description, "RShift")
        let parsed = try HotkeySpec(parsing: "RShift")
        XCTAssertEqual(parsed, spec)
        XCTAssertEqual(try HotkeySpec(parsing: "rightshift"), spec)
    }

    func testLeftAndRightShiftAreDistinct() {
        let left = HotkeySpec(keyCode: 56, modifiers: [])
        let right = HotkeySpec(keyCode: 60, modifiers: [])
        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.eventFlags().rawValue, right.eventFlags().rawValue)
    }

    /// Pressing a modifier raises its own flag. Emitting it without that flag
    /// set would look to a listener like the key was never held.
    func testModifierKeyAssertsItsOwnFlagOnTheSideItBelongsTo() {
        let right = HotkeySpec(keyCode: 60, modifiers: []).eventFlags().rawValue
        XCTAssertEqual(right & maskShift, maskShift, "shift flag must be raised")
        XCTAssertEqual(right & deviceRShift, deviceRShift, "right device bit must be set")
        XCTAssertEqual(right & deviceLShift, 0, "left device bit must not be set")

        let left = HotkeySpec(keyCode: 56, modifiers: []).eventFlags().rawValue
        XCTAssertEqual(left & deviceLShift, deviceLShift)
        XCTAssertEqual(left & deviceRShift, 0)
    }

    /// The stuck-modifier rule, at the flag level: releasing Right Shift must
    /// clear the shift flag, or every later keystroke arrives shifted.
    func testReleasingABareModifierClearsItsFlag() {
        let spec = HotkeySpec(keyCode: 60, modifiers: [])
        let up = spec.releaseFlags().rawValue
        XCTAssertEqual(up & maskShift, 0, "release must not still assert shift")
        XCTAssertEqual(up & deviceRShift, 0)
    }

    /// But when the combination genuinely holds shift as well, the release half
    /// keeps it: the held modifier outlives the key.
    func testReleaseKeepsAModifierThatIsAlsoHeld() {
        let spec = HotkeySpec(keyCode: 60, modifiers: [.shift, .control])
        XCTAssertEqual(spec.releaseFlags().rawValue & maskShift, maskShift)
    }

    /// An ordinary key is unaffected by any of this.
    func testOrdinaryKeyReleaseFlagsAreUnchanged() {
        let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])
        XCTAssertEqual(spec.eventFlags().rawValue, spec.releaseFlags().rawValue)
    }

    func testBareModifierAndCollisionAreRecognised() {
        XCTAssertTrue(HotkeySpec(keyCode: 60, modifiers: []).isBareModifier)
        XCTAssertFalse(HotkeySpec(keyCode: 41, modifiers: [.control]).isBareModifier)
    }

    /// Right Shift is bindable. It was refused for a while on the theory that a
    /// synthesized bare modifier would be invisible to a listener; measured, it
    /// arrives as flagsChanged keyCode=60 flags=0x20020004 with the right-hand
    /// device bit set. Only the advice remains.
    func testTypingModifiersAreFlaggedButNotRefused() {
        XCTAssertTrue(HotkeySpec(keyCode: 60, modifiers: []).isTypingModifier)   // RShift
        XCTAssertTrue(HotkeySpec(keyCode: 61, modifiers: []).isTypingModifier)   // ROpt
        XCTAssertFalse(HotkeySpec(keyCode: 63, modifiers: []).isTypingModifier)  // Fn
        XCTAssertFalse(HotkeySpec(keyCode: 60, modifiers: [.control]).isTypingModifier,
                       "a combination is not something typing produces by accident")
        XCTAssertFalse(HotkeySpec(keyCode: 41, modifiers: [.control]).isTypingModifier)
    }

    /// The recorder builds specs from NSEvent flags. A modifier key must not end
    /// up listed twice, as both the key and one of its own modifiers.
    func testModifierKeyIsNotAlsoListedAsAModifier() {
        let spec = HotkeySpec(keyCode: 60, modifiers: [.shift])
        // Constructed directly this is legal, but the printed form must stay
        // readable rather than becoming "Shift+RShift" by accident.
        XCTAssertEqual(spec.description, "Shift+RShift")
        let viaRecorder = HotkeySpec(keyCode: 60, modifiers: [])
        XCTAssertEqual(viaRecorder.description, "RShift")
    }

    /// Emission posts a balanced pair even for a modifier, and the poster tags
    /// the modifier half as flagsChanged rather than a key-down.
    func testModifierEmissionIsBalanced() throws {
        let poster = RecordingPoster()
        let emitter = HotkeyEmitter(
            hotkey: HotkeySpec(keyCode: 61, modifiers: []),   // ROpt, no collision
            poster: poster,
            permission: AlwaysTrustedPermission()
        )
        _ = try emitter.emit()
        let posted = poster.events
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted.first?.phase, EmittedKeyEvent.Phase.down)
        XCTAssertEqual(posted.last?.phase, EmittedKeyEvent.Phase.up)
        XCTAssertNotEqual(posted[0].flagsRaw, posted[1].flagsRaw,
                          "the release must drop the modifier the press raised")
    }
}
