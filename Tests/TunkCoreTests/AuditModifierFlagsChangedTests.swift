import CoreGraphics
import XCTest
@testable import TunkEmit

/// A bare-modifier hotkey is posted as two `flagsChanged` events, and a
/// `flagsChanged` carries the session's whole modifier set, not a delta. The
/// pair used to stamp the spec's own flags verbatim: the down said "only Right
/// Shift is held" and the up said "nothing is held", the exact shape
/// `releaseModifiers` documents as clearing hardware Caps Lock and a held
/// Control that Tunk never asserted. These tests pin the pair to the rule the
/// release already follows: add our bits to what the session holds, then
/// subtract only our bits.
///
/// They build the events without posting them, so they run with the screen
/// locked and need no Accessibility permission.
final class AuditModifierFlagsChangedTests: XCTestCase {
    private let rShift = HotkeySpec(keyCode: 60, modifiers: [])
    private let deviceRShift = CGEventFlags(rawValue: 0x0000_0004)
    private let capsLock = CGEventFlags.maskAlphaShift

    private func poster(live: CGEventFlags) -> CGEventPoster {
        let p = CGEventPoster()
        p.liveFlags = { live }
        return p
    }

    private func flags(_ poster: CGEventPoster, _ phase: EmittedKeyEvent.Phase,
                       _ spec: HotkeySpec) throws -> CGEventFlags {
        let raw = phase == .down ? spec.eventFlags().rawValue : spec.releaseFlags().rawValue
        let event = EmittedKeyEvent(phase: phase, keyCode: spec.keyCode, flagsRaw: raw)
        let cg = try XCTUnwrap(poster.makeEvent(event))
        XCTAssertEqual(cg.type, .flagsChanged)
        return cg.flags
    }

    func testBareModifierDownKeepsTheModifiersTheSessionAlreadyHolds() throws {
        let down = try flags(poster(live: capsLock), .down, rShift)
        XCTAssertTrue(down.contains(.maskShift))
        XCTAssertTrue(down.contains(deviceRShift))
        XCTAssertTrue(down.contains(capsLock),
                      "the down said only shift was held: 0x\(String(down.rawValue, radix: 16))")
    }

    func testBareModifierUpSubtractsOnlyItsOwnBits() throws {
        // What the session holds once our down has landed: hardware Caps Lock,
        // a Control the user is physically holding, and our own shift.
        let live: CGEventFlags = [capsLock, .maskControl, .maskShift, deviceRShift]
        let up = try flags(poster(live: live), .up, rShift)
        XCTAssertFalse(up.contains(.maskShift))
        XCTAssertFalse(up.contains(deviceRShift))
        XCTAssertEqual(up, [capsLock, .maskControl],
                       "the up cleared modifiers Tunk never asserted: 0x\(String(up.rawValue, radix: 16))")
    }

    func testCombinationUpDropsTheKeyButKeepsItsHeldModifiers() throws {
        let spec = HotkeySpec(keyCode: 60, modifiers: [.control])
        let deviceLCtrl = CGEventFlags(rawValue: 0x0000_0001)
        let live: CGEventFlags = [capsLock, .maskControl, deviceLCtrl, .maskShift, deviceRShift]
        let up = try flags(poster(live: live), .up, spec)
        XCTAssertFalse(up.contains(.maskShift))
        XCTAssertFalse(up.contains(deviceRShift))
        XCTAssertTrue(up.contains(.maskControl),
                      "the release half must still carry the held combination")
        XCTAssertTrue(up.contains(capsLock))
    }

    func testOrdinaryKeyFlagsAreStampedVerbatim() throws {
        let spec = HotkeySpec(keyCode: 41, modifiers: [.command])
        let event = EmittedKeyEvent(phase: .down, keyCode: 41, flagsRaw: spec.eventFlags().rawValue)
        let cg = try XCTUnwrap(poster(live: capsLock).makeEvent(event))
        XCTAssertEqual(cg.type, .keyDown)
        XCTAssertEqual(cg.flags.rawValue, event.flagsRaw,
                       "an ordinary key must not pick up the session's modifiers")
    }
}
