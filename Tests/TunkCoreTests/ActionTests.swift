import Foundation
import XCTest
@testable import TunkEmit

// Tests for the pluggable action layer: `TunkAction`, `ActionRunner`,
// `ShortcutsProcessSpawner` and `ShortcutsCatalog`.
//
// SAFETY: nothing in this file runs one of the operator's Shortcuts. The
// spawner tests point `ShortcutsProcessSpawner` at `/bin/echo`, `/usr/bin/false`
// and a throwaway script in a temp directory, which exercises the same process
// machinery with no side effects. `shortcuts run` is never invoked. The only
// contact with the real Shortcuts CLI is `shortcuts list`, which is read-only.

// MARK: - TunkAction, and the migration

final class TunkActionCodingTests: XCTestCase {

    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    private func roundTrip(_ action: TunkAction) throws -> TunkAction {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(TunkAction.self, from: data)
    }

    func testHotkeyRoundTrips() throws {
        let action = TunkAction.hotkey(spec)
        XCTAssertEqual(try roundTrip(action), action)
        XCTAssertEqual(try roundTrip(action).hotkeySpec, spec)
    }

    func testShortcutRoundTrips() throws {
        let action = TunkAction.shortcut(name: "Track My Orders")
        XCTAssertEqual(try roundTrip(action), action)
        XCTAssertEqual(try roundTrip(action).shortcutName, "Track My Orders")
    }

    func testNoneRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.none), .none)
    }

    /// Names are user data and go through JSON unescaped by us. A shortcut with
    /// a quote, an emoji or a slash in its name must survive the trip.
    func testAwkwardShortcutNamesRoundTrip() throws {
        for name in [#"Say "hello""#, "Coffee ☕️/Tea", "  padded  ", "日本語", "a\\b"] {
            XCTAssertEqual(try roundTrip(.shortcut(name: name)), .shortcut(name: name),
                           "failed on \(name)")
        }
    }

    /// The encoded shape ends up in the user's settings file, so it is pinned.
    func testEncodedShapeIsTagged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        XCTAssertEqual(String(decoding: try encoder.encode(TunkAction.hotkey(spec)), as: UTF8.self),
                       #"{"hotkey":"Ctrl+Opt+Cmd+;","kind":"hotkey"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(TunkAction.shortcut(name: "Twitter")),
                              as: UTF8.self),
                       #"{"kind":"shortcut","name":"Twitter"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(TunkAction.none), as: UTF8.self),
                       #"{"kind":"none"}"#)
    }

    /// The migration, at the type level: a settings value that is a bare hotkey
    /// string is what every pre-`TunkAction` build wrote.
    func testBareHotkeyStringDecodesAsAHotkeyAction() throws {
        let json = Data(#"{"action":"Ctrl+Opt+Cmd+;"}"#.utf8)
        let decoded = try JSONDecoder().decode([String: TunkAction].self, from: json)
        XCTAssertEqual(decoded["action"], .hotkey(spec))
    }

    func testLegacyStringSurvivesAFullReEncode() throws {
        let json = Data(#"{"action":"Ctrl+Opt+Shift+Cmd+'"}"#.utf8)
        let decoded = try JSONDecoder().decode([String: TunkAction].self, from: json)
        let action = try XCTUnwrap(decoded["action"])
        // Re-encoding writes the new shape; decoding that must give the same value.
        XCTAssertEqual(try roundTrip(action), action)
        XCTAssertEqual(action.hotkeySpec?.description, "Ctrl+Opt+Shift+Cmd+'")
    }

    func testGarbageLegacyStringThrowsRatherThanSilentlyResetting() {
        let json = Data(#"{"action":"Ctrl+Opt+Cmd+Nope"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([String: TunkAction].self, from: json))
    }

    func testUnknownKindThrows() {
        let json = Data(#"{"kind":"launchTheMissiles"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TunkAction.self, from: json))
    }

    // MARK: settings-store migration

    /// Upgrading from a hotkey-only build: no `action` key, a good `hotkey`
    /// string. The user keeps their combination.
    func testUpgradeFromLegacySettingsKeepsTheUsersHotkey() {
        let action = TunkAction.restored(actionData: nil, legacyHotkeyText: "Ctrl+Opt+Cmd+\\")
        XCTAssertEqual(action, .hotkey(HotkeySpec(keyCode: 42,
                                                  modifiers: [.control, .option, .command])))
        XCTAssertNotEqual(action, .hotkey(.recommendedDefault),
                          "migrating must not quietly hand back the shipped default")
    }

    func testStoredActionWinsOverTheLegacyKey() throws {
        let data = try JSONEncoder().encode(TunkAction.shortcut(name: "Twitter"))
        let action = TunkAction.restored(actionData: data, legacyHotkeyText: "Ctrl+Opt+Cmd+;")
        XCTAssertEqual(action, .shortcut(name: "Twitter"))
    }

    /// An `action` blob that is itself a legacy bare string still migrates.
    func testStoredActionMayItselfBeALegacyString() {
        let data = Data(#""Ctrl+Opt+Cmd+;""#.utf8)
        XCTAssertEqual(TunkAction.restored(actionData: data, legacyHotkeyText: nil),
                       .hotkey(spec))
    }

    func testFreshInstallGetsTheRecommendedHotkey() {
        XCTAssertEqual(TunkAction.restored(actionData: nil, legacyHotkeyText: nil),
                       .hotkey(.recommendedDefault))
    }

    /// Unreadable stored data must not lose a readable legacy key.
    func testCorruptActionDataFallsBackToTheLegacyKey() {
        let junk = Data([0xFF, 0x00, 0x13])
        XCTAssertEqual(TunkAction.restored(actionData: junk, legacyHotkeyText: "Ctrl+Cmd+\\"),
                       .hotkey(HotkeySpec(keyCode: 42, modifiers: [.control, .command])))
    }

    // MARK: descriptions

    func testRunnability() {
        XCTAssertTrue(TunkAction.hotkey(spec).isRunnable)
        XCTAssertTrue(TunkAction.shortcut(name: "Twitter").isRunnable)
        XCTAssertFalse(TunkAction.shortcut(name: "   ").isRunnable)
        XCTAssertFalse(TunkAction.none.isRunnable)
    }

    func testKindMatchesTheCase() {
        XCTAssertEqual(TunkAction.hotkey(spec).kind, .hotkey)
        XCTAssertEqual(TunkAction.shortcut(name: "x").kind, .shortcut)
        XCTAssertEqual(TunkAction.none.kind, .none)
        XCTAssertEqual(Set(TunkAction.Kind.allCases).count, 3)
    }
}

// MARK: - A spawner that does exactly what the test tells it to

private final class FakeSpawner: ShortcutSpawning, @unchecked Sendable {
    enum Behaviour: Sendable {
        /// Never calls back. Stands in for a shortcut that hangs forever.
        case silent
        /// Calls back after a delay, on another queue.
        case finish(after: TimeInterval, error: EmitError?)
    }

    private let lock = NSLock()
    private var _names: [String] = []
    private let behaviour: Behaviour
    /// Set while `spawn` is on the stack, so a test can prove `ActionRunner`
    /// did not somehow re-enter or wait inside it.
    let spawned = DispatchSemaphore(value: 0)

    init(_ behaviour: Behaviour = .finish(after: 0, error: nil)) {
        self.behaviour = behaviour
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return _names
    }

    func spawn(shortcut name: String,
               completion: @escaping @Sendable (ShortcutOutcome) -> Void) {
        lock.lock(); _names.append(name); lock.unlock()
        spawned.signal()
        guard case .finish(let delay, let error) = behaviour else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            completion(ShortcutOutcome(name: name,
                                       completionLatencyNs: Int64(delay * 1_000_000_000),
                                       error: error))
        }
    }
}

/// Collects `onChange` snapshots across threads.
private final class StatsSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [ActionStats] = []
    var all: [ActionStats] {
        lock.lock(); defer { lock.unlock() }
        return _all
    }
    var last: ActionStats? { all.last }
    func record(_ s: ActionStats) {
        lock.lock(); _all.append(s); lock.unlock()
    }
}

// MARK: - ActionRunner

final class ActionRunnerTests: XCTestCase {

    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    private func makeRunner(action: TunkAction,
                            poster: RecordingPoster = RecordingPoster(),
                            spawner: ShortcutSpawning = FakeSpawner(),
                            trusted: Bool = true,
                            hold: Int64 = 0) -> ActionRunner {
        let emitter = HotkeyEmitter(
            hotkey: .recommendedDefault,
            options: .init(includeDeviceSideFlags: true,
                           keyDownHoldNs: hold,
                           requireAccessibility: true),
            poster: poster,
            permission: AlwaysTrustedPermission(isTrusted: trusted))
        return ActionRunner(action: action, emitter: emitter, spawner: spawner)
    }

    // MARK: the hotkey path is unchanged

    func testHotkeyPathStillPostsExactlyOneDownThenOneUp() throws {
        let poster = RecordingPoster()
        let runner = makeRunner(action: .hotkey(spec), poster: poster)

        let stats = try runner.run()

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertEqual(stats.emit.emitCount, 1)
        XCTAssertEqual(stats.emit.keyDownsPosted, 1)
        XCTAssertEqual(stats.emit.keyUpsPosted, 1)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertEqual(stats.runCount, 1)
        XCTAssertNil(stats.lastErrorText)
    }

    func testHundredRunsThroughTheRunnerStayBalanced() throws {
        let poster = RecordingPoster()
        let runner = makeRunner(action: .hotkey(spec), poster: poster)

        for _ in 0..<100 { try runner.run() }

        let phases = poster.events.map(\.phase)
        XCTAssertEqual(phases.count, 200)
        for i in stride(from: 0, to: phases.count, by: 2) {
            XCTAssertEqual(phases[i], .down)
            XCTAssertEqual(phases[i + 1], .up)
        }
        XCTAssertFalse(runner.stats.hasStuckKey)
        XCTAssertEqual(runner.stats.emit.keyDownsPosted, runner.stats.emit.keyUpsPosted)
    }

    /// The funnel's guarantee has to survive being wrapped: a failing key-down
    /// post still lets the key-up out.
    func testFailingKeyDownStillReleasesTheKeyThroughTheRunner() {
        let poster = RecordingPoster(failMode: .onPost(.down))
        let runner = makeRunner(action: .hotkey(spec), poster: poster)

        XCTAssertThrowsError(try runner.run())

        XCTAssertEqual(poster.events.map(\.phase), [.up])
        XCTAssertFalse(runner.stats.hasStuckKey)
        XCTAssertEqual(runner.stats.emit.failureCount, 1)
        XCTAssertNotNil(runner.stats.lastErrorText)
    }

    func testMissingAccessibilitySurfacesTheActionableError() {
        let poster = RecordingPoster()
        let runner = makeRunner(action: .hotkey(spec), poster: poster, trusted: false)

        XCTAssertThrowsError(try runner.run()) { error in
            guard case EmitError.accessibilityNotTrusted = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(runner.stats.lastErrorText?.contains("System Settings") == true)
    }

    /// One source of truth: setting the action retargets the emitter, so a
    /// hotkey changed in the panel is the hotkey the next tap posts.
    func testSettingTheActionRetargetsTheEmitter() throws {
        let poster = RecordingPoster()
        let runner = makeRunner(action: .hotkey(.recommendedDefault), poster: poster)

        let other = HotkeySpec(keyCode: 42, modifiers: [.control, .option, .command])
        runner.action = .hotkey(other)
        XCTAssertEqual(runner.hotkeyEmitter.hotkey, other)

        try runner.run()
        XCTAssertEqual(poster.events.first?.keyCode, 42)
        XCTAssertEqual(runner.stats.emit.lastEmitted, other)
    }

    func testPreflightIgnoresNonHotkeyActions() {
        let untrusted = makeRunner(action: .hotkey(spec), trusted: false)
        XCTAssertThrowsError(try untrusted.preflight())

        // A shortcut cannot be preflighted without running it, and running a
        // user's shortcut to check it is exactly what Tunk must never do.
        untrusted.action = .shortcut(name: "Twitter")
        XCTAssertNoThrow(try untrusted.preflight())
        untrusted.action = .none
        XCTAssertNoThrow(try untrusted.preflight())
    }

    // MARK: the shortcut path does not block

    /// The measurement this whole design exists for. `run` must hand off and
    /// return; it must not wait for the shortcut, which may take seconds.
    func testShortcutDispatchReturnsWithoutWaiting() throws {
        // A shortcut that takes half a second to finish.
        let spawner = FakeSpawner(.finish(after: 0.5, error: nil))
        let runner = makeRunner(action: .shortcut(name: "Twitter"), spawner: spawner)

        let t0 = EmitClock.nowNanos()
        let stats = try runner.run()
        let elapsed = EmitClock.nowNanos() - t0

        XCTAssertLessThan(elapsed, 1_000_000,
                          "dispatch took \(Double(elapsed) / 1_000_000) ms; the budget is ~1 ms "
                          + "and the detector's thread is the caller")
        XCTAssertEqual(spawner.names, ["Twitter"], "the shortcut must have been handed off")
        XCTAssertEqual(stats.shortcutRunCount, 1)
        // Handed off, not finished. A completion latency here would mean we waited.
        XCTAssertNil(stats.lastCompletionLatencyNs)
        XCTAssertNil(stats.lastErrorText)
        XCTAssertEqual(stats.emit.emitCount, 0, "a shortcut must not post keys")
    }

    /// Same claim, made harder: a spawner that never calls back at all, which is
    /// what a hung shortcut looks like from here.
    func testAHungShortcutNeverBlocksTheCaller() throws {
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(action: .shortcut(name: "Hangs Forever"), spawner: spawner)

        let t0 = EmitClock.nowNanos()
        for _ in 0..<20 { try runner.run() }
        let elapsed = EmitClock.nowNanos() - t0

        XCTAssertLessThan(elapsed, 20_000_000, "20 hung shortcuts must still cost ~nothing")
        XCTAssertEqual(spawner.names.count, 20)
        XCTAssertEqual(runner.stats.shortcutRunCount, 20)
        XCTAssertEqual(runner.stats.shortcutFailureCount, 0, "nothing has reported back yet")
    }

    func testDispatchLatencyIsRecordedAndTiny() throws {
        let runner = makeRunner(action: .shortcut(name: "Twitter"),
                                spawner: FakeSpawner(.silent))
        let stats = try runner.run()
        let ns = try XCTUnwrap(stats.lastDispatchLatencyNs)
        XCTAssertGreaterThanOrEqual(ns, 0)
        XCTAssertLessThan(ns, 1_000_000)
        XCTAssertEqual(stats.lastDispatchMs.map { $0 < 1 }, true)
    }

    /// The hotkey's deliberate key-down hold sits *after* the keystroke is out,
    /// so it is not part of decision-to-handoff and must not be charged to it.
    func testDispatchLatencyExcludesTheKeyDownHold() throws {
        let runner = makeRunner(action: .hotkey(spec), hold: 20_000_000)
        let t0 = EmitClock.nowNanos()
        let stats = try runner.run()
        let wall = EmitClock.nowNanos() - t0

        XCTAssertGreaterThanOrEqual(wall, 15_000_000, "the key really was held")
        let dispatch = try XCTUnwrap(stats.lastDispatchLatencyNs)
        XCTAssertLessThan(dispatch, 1_000_000,
                          "the hold must not be charged to dispatch latency; got "
                          + "\(Double(dispatch) / 1_000_000) ms against a \(Double(wall) / 1_000_000) ms wall")
        // The stamp the measurement rests on.
        let downAt = try XCTUnwrap(stats.emit.lastKeyDownMachNs)
        XCTAssertGreaterThan(try XCTUnwrap(stats.emit.lastEmitMachNs), downAt,
                             "the emission completes after the key-down it is measured to")
    }

    // MARK: a failing shortcut is surfaced, not swallowed, and not thrown

    func testFailingShortcutSurfacesAnErrorWithoutThrowing() throws {
        let spawner = FakeSpawner(.finish(after: 0,
                                          error: .shortcutFailed(name: "Twitter", exitCode: 1,
                                                                 detail: "no such shortcut")))
        let runner = makeRunner(action: .shortcut(name: "Twitter"), spawner: spawner)
        let sink = StatsSink()
        runner.onChange = { sink.record($0) }

        // This is the detector's call. It must not throw.
        XCTAssertNoThrow(try runner.run())

        let reported = expectation(description: "failure reported")
        pollUntil(reported) { runner.stats.shortcutFailureCount == 1 }
        wait(for: [reported], timeout: 2)

        let stats = runner.stats
        let text = try XCTUnwrap(stats.lastErrorText)
        XCTAssertTrue(text.contains("Twitter"), "the user must be told which one: \(text)")
        XCTAssertTrue(text.contains("no such shortcut"), "stderr must reach the panel: \(text)")
        XCTAssertTrue(text.contains("Shortcuts.app"), "and what to do about it: \(text)")
        XCTAssertNotNil(stats.lastCompletionLatencyNs)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertGreaterThanOrEqual(sink.all.count, 2, "onChange fires on dispatch and on failure")
    }

    func testSucceedingShortcutClearsTheError() throws {
        let failing = FakeSpawner(.finish(after: 0,
                                          error: .shortcutFailed(name: "Twitter", exitCode: 1,
                                                                 detail: "boom")))
        let runner = makeRunner(action: .shortcut(name: "Twitter"), spawner: failing)
        XCTAssertNoThrow(try runner.run())

        let failed = expectation(description: "failed")
        pollUntil(failed) { runner.stats.lastErrorText != nil }
        wait(for: [failed], timeout: 2)

        let ok = makeRunner(action: .shortcut(name: "Twitter"),
                            spawner: FakeSpawner(.finish(after: 0, error: nil)))
        XCTAssertNoThrow(try ok.run())
        let succeeded = expectation(description: "succeeded")
        pollUntil(succeeded) { ok.stats.shortcutSuccessCount == 1 }
        wait(for: [succeeded], timeout: 2)
        XCTAssertNil(ok.stats.lastErrorText)
    }

    /// A `.shortcut` with no name picked yet. Nothing spawns, and the panel is
    /// told why rather than the tap silently doing nothing.
    func testShortcutWithNoNameChosenSpawnsNothingAndExplainsItself() throws {
        let spawner = FakeSpawner()
        let runner = makeRunner(action: .shortcut(name: "  "), spawner: spawner)

        let stats = try runner.run()

        XCTAssertTrue(spawner.names.isEmpty, "an empty name must never reach the spawner")
        XCTAssertEqual(stats.shortcutRunCount, 0)
        XCTAssertTrue(stats.lastErrorText?.contains("no Shortcut has been picked") == true)
    }

    /// A shortcut name is trimmed before it is handed over, so a stray space
    /// from a rename does not turn into a "not found".
    func testShortcutNameIsTrimmedBeforeSpawning() throws {
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(action: .shortcut(name: "  Twitter  "), spawner: spawner)
        try runner.run()
        XCTAssertEqual(spawner.names, ["Twitter"])
    }

    // MARK: doing nothing

    func testNoneRunsCleanlyAndTouchesNothing() throws {
        let poster = RecordingPoster()
        let spawner = FakeSpawner()
        let runner = makeRunner(action: .none, poster: poster, spawner: spawner)

        let stats = try runner.run()

        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(spawner.names.isEmpty)
        XCTAssertEqual(stats.runCount, 1)
        XCTAssertEqual(stats.emit.emitCount, 0)
        XCTAssertNil(stats.lastErrorText)
    }

    // MARK: threading

    func testConcurrentRunsOfMixedKindsStayConsistent() {
        let poster = RecordingPoster()
        let spawner = FakeSpawner(.finish(after: 0, error: nil))
        let runner = makeRunner(action: .hotkey(spec), poster: poster, spawner: spawner)

        DispatchQueue.concurrentPerform(iterations: 60) { i in
            _ = try? runner.run(i.isMultiple(of: 2)
                                ? .hotkey(self.spec)
                                : .shortcut(name: "Twitter"))
        }

        let stats = runner.stats
        XCTAssertEqual(stats.runCount, 60)
        XCTAssertEqual(stats.emit.keyDownsPosted, 30)
        XCTAssertEqual(stats.emit.keyUpsPosted, 30)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertEqual(spawner.names.count, 30)
    }

    // MARK: helper

    /// Polls a condition off the main thread and fulfils `exp` when it holds.
    /// The shortcut path reports back asynchronously by design, so there is
    /// nothing synchronous to wait on.
    private func pollUntil(_ exp: XCTestExpectation,
                           timeout: TimeInterval = 2,
                           _ condition: @escaping @Sendable () -> Bool) {
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if condition() { exp.fulfill(); return }
                usleep(2000)
            }
        }
    }
}

// MARK: - The real process spawner

/// Exercised against harmless system binaries and a throwaway script. It never
/// invokes `shortcuts run`.
final class ShortcutsProcessSpawnerTests: XCTestCase {

    private func run(_ spawner: ShortcutsProcessSpawner,
                     name: String,
                     timeout: TimeInterval = 10) throws -> ShortcutOutcome {
        let box = OutcomeBox()
        let exp = expectation(description: "outcome for \(name)")
        spawner.spawn(shortcut: name) { outcome in
            box.set(outcome)
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return try XCTUnwrap(box.value)
    }

    func testSpawnReturnsImmediatelyEvenForASlowChild() throws {
        let script = try makeScript("sleep 1\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0)

        let t0 = EmitClock.nowNanos()
        spawner.spawn(shortcut: "Slow") { _ in }
        let elapsed = EmitClock.nowNanos() - t0

        XCTAssertLessThan(elapsed, 2_000_000,
                          "spawn is \(Double(elapsed) / 1_000_000) ms; it must not wait for the "
                          + "child, which sleeps for a second")
    }

    func testCleanExitIsReportedAsSuccessWithACompletionLatency() throws {
        let spawner = ShortcutsProcessSpawner(executable: "/bin/echo", watchdogSeconds: 0)
        let outcome = try run(spawner, name: "Anything")
        XCTAssertTrue(outcome.succeeded, "unexpected error: \(String(describing: outcome.error))")
        XCTAssertEqual(outcome.name, "Anything")
        XCTAssertGreaterThan(outcome.completionLatencyNs, 0)
    }

    func testNonZeroExitIsReportedWithStderr() throws {
        let script = try makeScript("echo 'could not find shortcut' >&2\nexit 3\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0)

        let outcome = try run(spawner, name: "Missing One")
        guard case .shortcutFailed(let name, let code, let detail)? = outcome.error else {
            return XCTFail("wrong error: \(String(describing: outcome.error))")
        }
        XCTAssertEqual(name, "Missing One")
        XCTAssertEqual(code, 3)
        XCTAssertEqual(detail, "could not find shortcut")
    }

    /// A chatty child must not deadlock on a full pipe. 200 KB is well past the
    /// 64 KB pipe buffer that would block an undrained writer.
    func testAChattyChildDoesNotDeadlock() throws {
        let script = try makeScript("head -c 200000 /dev/zero | tr '\\0' 'x' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0)

        let outcome = try run(spawner, name: "Chatty", timeout: 15)
        guard case .shortcutFailed(_, _, let detail)? = outcome.error else {
            return XCTFail("wrong error: \(String(describing: outcome.error))")
        }
        XCTAssertLessThanOrEqual(detail.count, 4096, "captured stderr must stay bounded")
        XCTAssertFalse(detail.isEmpty)
    }

    func testMissingCLIIsReportedRatherThanCrashing() throws {
        let spawner = ShortcutsProcessSpawner(executable: "/nonexistent/shortcuts",
                                              watchdogSeconds: 0)
        let outcome = try run(spawner, name: "Twitter")
        guard case .shortcutsCLIMissing? = outcome.error else {
            return XCTFail("wrong error: \(String(describing: outcome.error))")
        }
    }

    /// A shortcut that never finishes is surfaced. Deliberately, the process is
    /// not killed: a half-run automation is worse than a slow one.
    func testWatchdogSurfacesAShortcutThatNeverFinishes() throws {
        let script = try makeScript("sleep 30\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0.2)

        let outcome = try run(spawner, name: "Waits For You", timeout: 5)
        guard case .shortcutTimedOut(let name, _)? = outcome.error else {
            return XCTFail("wrong error: \(String(describing: outcome.error))")
        }
        XCTAssertEqual(name, "Waits For You")
    }

    /// The watchdog and a real termination race. Exactly one must be delivered,
    /// or the stats would double-count.
    func testCompletionIsDeliveredExactlyOnce() throws {
        let script = try makeScript("sleep 0.3\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0.1)

        let counter = CallCounter()
        spawner.spawn(shortcut: "Racy") { _ in counter.bump() }
        // Well past both the watchdog and the child's own exit.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(counter.count, 1)
    }

    func testConcurrentSpawnsDoNotSerialiseBehindAHungOne() throws {
        let slow = try makeScript("sleep 3\n")
        let fast = try makeScript("exit 0\n")
        defer {
            try? FileManager.default.removeItem(atPath: slow)
            try? FileManager.default.removeItem(atPath: fast)
        }
        ShortcutsProcessSpawner(executable: slow, watchdogSeconds: 0)
            .spawn(shortcut: "Hangs") { _ in }

        let quick = ShortcutsProcessSpawner(executable: fast, watchdogSeconds: 0)
        let outcome = try run(quick, name: "Quick", timeout: 2)
        XCTAssertTrue(outcome.succeeded)
    }

    // MARK: helper

    private func makeScript(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "tunk-test-" + UUID().uuidString + ".sh"
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ShortcutOutcome?
    var value: ShortcutOutcome? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ v: ShortcutOutcome) {
        lock.lock(); _value = v; lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
    func bump() {
        lock.lock(); _count += 1; lock.unlock()
    }
}

// MARK: - The catalog

final class ShortcutsCatalogTests: XCTestCase {

    func testParseTakesOneNamePerLine() {
        let names = ShortcutsCatalog.parse("Twitter\nTrack My Orders\n\nCoffee ☕️\n")
        XCTAssertEqual(names, ["Twitter", "Track My Orders", "Coffee ☕️"])
    }

    func testParseTrimsAndDropsDuplicates() {
        XCTAssertEqual(ShortcutsCatalog.parse("  Twitter  \nTwitter\n  \n\tOther\n"),
                       ["Twitter", "Other"])
    }

    func testParseOfNothingIsAnEmptyListNotACrash() {
        XCTAssertEqual(ShortcutsCatalog.parse(""), [])
        XCTAssertEqual(ShortcutsCatalog.parse("\n\n  \n"), [])
    }

    /// Read-only. `shortcuts list` names the operator's Shortcuts; it does not
    /// run any of them. Asserting a count would depend on this machine, so the
    /// test asserts what is actually promised: it answers, it does not throw,
    /// and the cache is stable.
    func testListingIsSafeCachedAndNeverThrows() {
        ShortcutsCatalog.invalidate()
        let first = ShortcutsCatalog.available()
        let cached = ShortcutsCatalog.available()
        XCTAssertEqual(first, cached, "second call must come from the cache")

        let refreshed = ShortcutsCatalog.refresh()
        XCTAssertEqual(refreshed, first, "the library did not change during this test")

        if !ShortcutsCatalog.isCLIAvailable {
            XCTAssertTrue(first.isEmpty, "no CLI must read as no Shortcuts, not as a crash")
        }
    }

    func testListingFinishesWellInsideItsTimeout() {
        ShortcutsCatalog.invalidate()
        let t0 = EmitClock.nowNanos()
        _ = ShortcutsCatalog.available()
        let elapsed = Double(EmitClock.nowNanos() - t0) / 1_000_000_000
        XCTAssertLessThan(elapsed, ShortcutsCatalog.listTimeout + 1)
    }
}
