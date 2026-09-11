import XCTest
@testable import TunkEmit

/// Audit finding `emit-paneldowns`: the panel's "key downs / ups" readout is fed
/// only by `ActionRunner.onChange`. On the detector path the pair is posted on
/// the emitter's queue after `record` has already taken its snapshot, and the
/// pair's own completion reached the runner through `onEmit` only when it
/// failed. So after a clean tap the panel showed the previous tap's counts.
final class AuditEmitPanelCountsTests: XCTestCase {

    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [ActionStats] = []
        var all: [ActionStats] {
            lock.lock(); defer { lock.unlock() }
            return _all
        }
        func record(_ s: ActionStats) {
            lock.lock(); _all.append(s); lock.unlock()
        }
    }

    private final class SilentSpawner: ShortcutSpawning, @unchecked Sendable {
        func spawn(shortcut name: String,
                   completion: @escaping @Sendable (ShortcutOutcome) -> Void) {}
    }

    private final class EmptyResolver: ShortcutNameResolving, @unchecked Sendable {
        func listing() -> ShortcutsListing { ShortcutsListing(names: [], succeeded: true) }
        func cachedListing() -> ShortcutsListing? { nil }
    }

    /// Secure input is stubbed off so this runs on a locked screen too: it
    /// counts what the runner reports, and posts nothing real.
    private func makeRunner(poster: RecordingPoster) -> ActionRunner {
        let emitter = HotkeyEmitter(
            hotkey: spec,
            options: .init(includeDeviceSideFlags: true,
                           keyDownHoldNs: 20_000_000,
                           requireAccessibility: true),
            poster: poster,
            permission: AlwaysTrustedPermission(),
            secureInput: StubSecureInput(active: false))
        return ActionRunner(bindings: ActionBindings([2: .hotkey(spec)]),
                            emitter: emitter,
                            spawner: SilentSpawner(),
                            resolver: EmptyResolver())
    }

    func testDetectorPathSnapshotSeesItsOwnPair() throws {
        let poster = RecordingPoster()
        let runner = makeRunner(poster: poster)
        let sink = Sink()
        runner.onChange = { sink.record($0) }

        try runner.run(tapCount: 2)
        runner.drainPending()

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        let emitter = runner.stats.emit
        XCTAssertEqual(emitter.keyDownsPosted, 1)
        XCTAssertEqual(emitter.keyUpsPosted, 1)

        let panel = try XCTUnwrap(sink.all.last).emit
        XCTAssertEqual(panel.keyUpsPosted, emitter.keyUpsPosted,
                       "AUDIT after one tap: panel sees downs/ups "
                       + "\(panel.keyDownsPosted)/\(panel.keyUpsPosted), emitter has "
                       + "\(emitter.keyDownsPosted)/\(emitter.keyUpsPosted), "
                       + "snapshots delivered \(sink.all.count)")
        XCTAssertEqual(panel.keyDownsPosted, emitter.keyDownsPosted)
        XCTAssertEqual(panel.emitCount, 1)
        XCTAssertNil(try XCTUnwrap(sink.all.last).lastErrorText)
    }

    func testDetectorPathFailureStillReachesThePanel() throws {
        let poster = RecordingPoster(failMode: .onPost(.down))
        let runner = makeRunner(poster: poster)
        let sink = Sink()
        runner.onChange = { sink.record($0) }

        try runner.run(tapCount: 2)
        runner.drainPending()

        let last = try XCTUnwrap(sink.all.last)
        XCTAssertNotNil(last.lastErrorText)
        XCTAssertEqual(last.emit.failureCount, 1)
        XCTAssertEqual(last.emit.failureCount, runner.stats.emit.failureCount)
    }
}
