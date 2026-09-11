import XCTest
@testable import TunkEmit

/// `EmitStats.hasStuckKey` is the panel's orange light and the diagnostics
/// exit code. It must mean "a key-down went out and its key-up did not", which
/// is what `unbalancedPairs` records, and nothing else.
///
/// A pair deliberately holds its key down for `keyDownHoldNs` between the down
/// and the up. During that window the aggregate counters read one down and
/// zero ups, and that is a healthy pair in progress, not a stuck key.
final class AuditEmitStatsTests: XCTestCase {

    private func makeEmitter(poster: RecordingPoster, holdNs: Int64) -> HotkeyEmitter {
        HotkeyEmitter(hotkey: HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command]),
                      options: .init(includeDeviceSideFlags: true,
                                     keyDownHoldNs: holdNs,
                                     requireAccessibility: true),
                      poster: poster,
                      permission: AlwaysTrustedPermission(isTrusted: true),
                      secureInput: StubSecureInput(active: false))
    }

    func testAHealthyPairMidHoldIsNotReportedAsStuck() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster, holdNs: 300_000_000)

        emitter.emitAsync()

        // Wait for the down to go out, then read while the 300 ms hold is on.
        let deadline = Date().addingTimeInterval(2)
        while poster.events.count < 1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let midHold = emitter.stats
        XCTAssertEqual(midHold.keyDownsPosted, 1)
        XCTAssertEqual(midHold.keyUpsPosted, 0, "read during the hold, before the up")
        XCTAssertEqual(midHold.unbalancedPairs, 0)
        XCTAssertFalse(midHold.hasStuckKey,
                       "a pair in progress is not a stuck key; the panel would paint "
                       + "orange and the diagnostics probe would exit 1 on a healthy hold")

        emitter.drainPending()
        let done = emitter.stats
        XCTAssertEqual(done.keyDownsPosted, 1)
        XCTAssertEqual(done.keyUpsPosted, 1)
        XCTAssertFalse(done.hasStuckKey)
    }

    func testAFailedKeyUpIsStillReportedAsStuck() {
        let poster = RecordingPoster(failMode: .onPost(.up))
        let emitter = makeEmitter(poster: poster, holdNs: 0)

        XCTAssertThrowsError(try emitter.emit())

        XCTAssertEqual(emitter.stats.unbalancedPairs, 1)
        XCTAssertTrue(emitter.stats.hasStuckKey, "the one shape that strands a key stays visible")
    }
}
