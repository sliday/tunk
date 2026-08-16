import Foundation
import TunkCore
import XCTest
@testable import TunkEmit

// Tests for the pluggable action layer: `TunkAction`, `ActionBindings`,
// `ActionRunner`, `ShortcutsProcessSpawner` and `ShortcutsCatalog`.
//
// SAFETY: nothing in this file runs one of the operator's Shortcuts. The
// spawner tests point `ShortcutsProcessSpawner` at `/bin/echo` and throwaway
// scripts in a temp directory, which exercises the same process machinery with
// no side effects. `shortcuts run` is never invoked. The only contact with the
// real Shortcuts CLI is `shortcuts list`, which is read-only — and validating a
// binding means checking it against that list, never running it to find out.

// MARK: - TunkAction

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

    /// The bit that decides whether a missing Shortcut is described as renamed
    /// or as never having existed. It has to survive the settings file.
    func testWasListedWhenBoundRoundTrips() throws {
        let listed = TunkAction.shortcut(name: "Twitter", wasListedWhenBound: true)
        XCTAssertEqual(try roundTrip(listed), listed)
        XCTAssertTrue(try roundTrip(listed).shortcutWasListedWhenBound)

        let unlisted = TunkAction.shortcut(name: "Twitter", wasListedWhenBound: false)
        XCTAssertEqual(try roundTrip(unlisted), unlisted)
        XCTAssertFalse(try roundTrip(unlisted).shortcutWasListedWhenBound)
        XCTAssertNotEqual(listed, unlisted, "the two must not compare equal")
    }

    /// Blobs written before the stale-name check existed have no such key. False
    /// is the only honest reading: no listing was ever seen.
    func testShortcutWithoutTheListedFlagDecodesAsNotListed() throws {
        let json = Data(#"{"kind":"shortcut","name":"Twitter"}"#.utf8)
        let action = try JSONDecoder().decode(TunkAction.self, from: json)
        XCTAssertEqual(action, .shortcut(name: "Twitter"))
        XCTAssertFalse(action.shortcutWasListedWhenBound)
    }

    /// Names are user data and go through JSON unescaped by us.
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

// MARK: - ActionBindings

final class ActionBindingsTests: XCTestCase {

    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    /// The safety default, and the one most worth pinning: single tap ships
    /// unbound. Every mug and footfall is a single transient, so nobody gets a
    /// single-tap action they did not deliberately arm.
    func testDefaultBindsDoubleAndLeavesSingleUnbound() {
        let b = ActionBindings.default
        XCTAssertEqual(b[2], .hotkey(.recommendedDefault))
        XCTAssertEqual(b[1], .none)
        XCTAssertEqual(b[3], .none)
        XCTAssertEqual(b.boundCounts, [2])
    }

    func testUnboundCountsReadAsNone() {
        let b = ActionBindings([2: .hotkey(spec)])
        for count in [0, 1, 3, 4, 99] {
            XCTAssertEqual(b[count], .none, "count \(count) should be unbound")
        }
    }

    func testSubscriptSetAndClear() {
        var b = ActionBindings()
        b[1] = .shortcut(name: "Twitter")
        b[2] = .hotkey(spec)
        XCTAssertEqual(b.boundCounts, [1, 2])

        b[1] = .none
        XCTAssertEqual(b.boundCounts, [2], "setting .none must unbind, not store a .none")
        XCTAssertFalse(b.boundCounts.contains(1))
    }

    /// Triple must persist and reload today, so wiring it later is a UI change
    /// rather than a settings migration.
    func testTripleIsRepresentableAndRoundTrips() throws {
        var b = ActionBindings.default
        b[3] = .shortcut(name: "Track My Orders", wasListedWhenBound: true)
        let back = try JSONDecoder().decode(ActionBindings.self,
                                            from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        XCTAssertEqual(back[3].shortcutName, "Track My Orders")
        XCTAssertTrue(back[3].shortcutWasListedWhenBound)
        XCTAssertEqual(ActionBindings.representableCounts, [1, 2, 3])
    }

    func testRoundTripsEveryKindAtOnce() throws {
        let b = ActionBindings([1: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                2: .hotkey(spec),
                                3: .none])
        let back = try JSONDecoder().decode(ActionBindings.self,
                                            from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        XCTAssertEqual(back.boundCounts, [1, 2])
    }

    /// Keyed by the count as a string. A `Dictionary<Int, _>` would encode as a
    /// flat array, which nobody can read or hand-edit in a settings file.
    func testEncodedShapeIsKeyedByCount() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(ActionBindings([2: .none, 1: .none])),
                          as: UTF8.self)
        XCTAssertEqual(json, "{}", "nothing bound encodes as nothing")

        let one = String(decoding: try encoder.encode(ActionBindings([2: .hotkey(spec)])),
                         as: UTF8.self)
        XCTAssertEqual(one, #"{"2":{"hotkey":"Ctrl+Opt+Cmd+;","kind":"hotkey"}}"#)
    }

    func testHotkeySpecsAndShortcutBindingsAreListed() {
        let b = ActionBindings([1: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                2: .hotkey(spec)])
        XCTAssertEqual(b.hotkeySpecs, [spec])
        XCTAssertEqual(b.shortcutBindings.count, 1)
        XCTAssertEqual(b.shortcutBindings.first?.count, 1)
        XCTAssertEqual(b.shortcutBindings.first?.name, "Twitter")
        XCTAssertEqual(b.shortcutBindings.first?.wasListedWhenBound, true)
        XCTAssertTrue(b.isAnythingBound)
        XCTAssertFalse(ActionBindings().isAnythingBound)
    }

    // MARK: migration

    /// Upgrading from the single-action build. The action becomes the DOUBLE
    /// binding and single stays unbound — nobody is handed a single-tap action
    /// they never asked for.
    func testMigratingASingleActionLandsOnDoubleTapOnly() throws {
        let data = try JSONEncoder().encode(TunkAction.shortcut(name: "Twitter"))
        let b = ActionBindings.restored(bindingsData: nil, actionData: data,
                                        legacyHotkeyText: nil)
        XCTAssertEqual(b[2], .shortcut(name: "Twitter"))
        XCTAssertEqual(b[1], .none, "single tap must never be armed by a migration")
        XCTAssertEqual(b.boundCounts, [2])
    }

    /// Upgrading from the hotkey-only build, two versions back. The user keeps
    /// their combination, on double tap.
    func testMigratingALegacyHotkeyStringLandsOnDoubleTapOnly() {
        let b = ActionBindings.restored(bindingsData: nil, actionData: nil,
                                        legacyHotkeyText: "Ctrl+Opt+Cmd+\\")
        XCTAssertEqual(b[2], .hotkey(HotkeySpec(keyCode: 42,
                                                modifiers: [.control, .option, .command])))
        XCTAssertEqual(b[1], .none)
        XCTAssertNotEqual(b, .default, "migrating must not hand back the shipped default")
    }

    func testStoredBindingsWinOverBothLegacyKeys() throws {
        let stored = ActionBindings([1: .hotkey(spec), 2: .shortcut(name: "Twitter")])
        let data = try JSONEncoder().encode(stored)
        let legacyAction = try JSONEncoder().encode(TunkAction.none)
        let b = ActionBindings.restored(bindingsData: data, actionData: legacyAction,
                                        legacyHotkeyText: "Ctrl+Opt+Cmd+;")
        XCTAssertEqual(b, stored)
    }

    func testSingleActionWinsOverTheOlderHotkeyKey() throws {
        let data = try JSONEncoder().encode(TunkAction.none)
        let b = ActionBindings.restored(bindingsData: nil, actionData: data,
                                        legacyHotkeyText: "Ctrl+Opt+Cmd+;")
        XCTAssertEqual(b[2], .none, "the newer key wins, even when it says do nothing")
    }

    func testFreshInstallGetsTheDefault() {
        XCTAssertEqual(ActionBindings.restored(bindingsData: nil, actionData: nil,
                                               legacyHotkeyText: nil),
                       .default)
    }

    /// Unreadable stored data must not lose a readable older key.
    func testCorruptBindingsFallBackThroughEveryOlderShape() {
        let junk = Data([0xFF, 0x00, 0x13])
        let b = ActionBindings.restored(bindingsData: junk, actionData: junk,
                                        legacyHotkeyText: "Ctrl+Cmd+\\")
        XCTAssertEqual(b[2], .hotkey(HotkeySpec(keyCode: 42, modifiers: [.control, .command])))
        XCTAssertEqual(b[1], .none)
    }
}

// MARK: - Test doubles

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
        guard case .finish(let delay, let error) = behaviour else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            completion(ShortcutOutcome(name: name,
                                       completionLatencyNs: Int64(delay * 1_000_000_000),
                                       error: error))
        }
    }
}

/// Stands in for `shortcuts list`. Records how often it was consulted, so a test
/// can prove the stale-name check actually happened.
private final class FakeResolver: ShortcutNameResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _listing: ShortcutsListing
    private var _calls = 0

    init(names: [String] = ["Twitter", "Track My Orders", "Hangs Forever"],
         succeeded: Bool = true) {
        _listing = ShortcutsListing(names: names, succeeded: succeeded)
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func set(names: [String], succeeded: Bool = true) {
        lock.lock(); _listing = ShortcutsListing(names: names, succeeded: succeeded); lock.unlock()
    }

    func listing() -> ShortcutsListing {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _listing
    }
}

private final class StatsSink: @unchecked Sendable {
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

// MARK: - ActionRunner

final class ActionRunnerTests: XCTestCase {
    /// Posts real CGEvents and counts what arrives, so it cannot run while
    /// another process holds secure event input. See `SecureInput`.
    override func setUpWithError() throws { try SecureInput.skipIfHeld() }


    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    private func makeRunner(_ bindings: ActionBindings,
                            poster: RecordingPoster = RecordingPoster(),
                            spawner: ShortcutSpawning = FakeSpawner(),
                            resolver: ShortcutNameResolving = FakeResolver(),
                            trusted: Bool = true,
                            hold: Int64 = 0) -> ActionRunner {
        let emitter = HotkeyEmitter(
            hotkey: .recommendedDefault,
            options: .init(includeDeviceSideFlags: true,
                           keyDownHoldNs: hold,
                           requireAccessibility: true),
            poster: poster,
            permission: AlwaysTrustedPermission(isTrusted: trusted))
        return ActionRunner(bindings: bindings, emitter: emitter,
                            spawner: spawner, resolver: resolver)
    }

    /// Shorthand for the common case: one action on double tap.
    private func makeRunner(double action: TunkAction,
                            poster: RecordingPoster = RecordingPoster(),
                            spawner: ShortcutSpawning = FakeSpawner(),
                            resolver: ShortcutNameResolving = FakeResolver(),
                            trusted: Bool = true,
                            hold: Int64 = 0) -> ActionRunner {
        makeRunner(ActionBindings([2: action]), poster: poster, spawner: spawner,
                   resolver: resolver, trusted: trusted, hold: hold)
    }

    private func trigger(taps: Int) -> Trigger {
        Trigger(tNs: 0, tapOnsets: Array(repeating: Int64(0), count: taps), score: 1)
    }

    /// The detector's hotkey path is asynchronous by design — it hands the pair
    /// to the emitter's post queue so the 796 Hz sensor callback is not held for
    /// the 8 ms key-down. So a test that asserts on posted events has to wait
    /// for them rather than read them straight after `run`.
    private func waitForEvents(_ poster: RecordingPoster, count: Int,
                               timeout: TimeInterval = 10,
                               file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(description: "\(count) events posted")
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if poster.events.count >= count { exp.fulfill(); return }
                usleep(2000)
            }
        }
        wait(for: [exp], timeout: timeout + 1)
        XCTAssertEqual(poster.events.count, count,
                       "expected \(count) posted events", file: file, line: line)
    }

    // MARK: the hotkey path is unchanged

    func testHotkeyPathStillPostsExactlyOneDownThenOneUp() throws {
        let poster = RecordingPoster()
        let runner = makeRunner(double: .hotkey(spec), poster: poster)

        let stats = try runner.run(tapCount: 2)
        waitForEvents(poster, count: 2)

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertEqual(runner.stats.emit.emitCount, 1)
        XCTAssertEqual(runner.stats.emit.keyDownsPosted, 1)
        XCTAssertEqual(runner.stats.emit.keyUpsPosted, 1)
        XCTAssertEqual(runner.stats.emit.unbalancedPairs, 0)
        XCTAssertFalse(runner.stats.hasStuckKey)
        XCTAssertEqual(stats.runCount, 1)
        XCTAssertEqual(stats.lastTapCount, 2)
        XCTAssertNil(stats.lastErrorText)
    }

    func testHundredRunsThroughTheRunnerStayBalanced() throws {
        let poster = RecordingPoster()
        let runner = makeRunner(double: .hotkey(spec), poster: poster)

        for _ in 0..<100 { try runner.run(tapCount: 2) }
        waitForEvents(poster, count: 200)

        let phases = poster.events.map(\.phase)
        XCTAssertEqual(phases.count, 200)
        for i in stride(from: 0, to: phases.count, by: 2) {
            XCTAssertEqual(phases[i], .down)
            XCTAssertEqual(phases[i + 1], .up)
        }
        XCTAssertFalse(runner.stats.hasStuckKey)
        XCTAssertEqual(runner.stats.emit.keyDownsPosted, runner.stats.emit.keyUpsPosted)
    }

    /// The funnel's guarantee has to survive being wrapped twice over.
    func testFailingKeyDownStillReleasesTheKeyThroughTheRunner() {
        let poster = RecordingPoster(failMode: .onPost(.down))
        let runner = makeRunner(double: .hotkey(spec), poster: poster)

        // The waiting path, which is what the Test button uses: it is the only
        // one that can throw, and the funnel it exercises is the same one.
        XCTAssertThrowsError(try runner.run(.hotkey(spec), tapCount: 2, waitForHotkey: true))

        XCTAssertEqual(poster.events.map(\.phase), [.up])
        XCTAssertFalse(runner.stats.hasStuckKey)
        XCTAssertEqual(runner.stats.emit.failureCount, 1)
        XCTAssertNotNil(runner.stats.lastErrorText)
    }

    func testMissingAccessibilitySurfacesTheActionableError() {
        let poster = RecordingPoster()
        let runner = makeRunner(double: .hotkey(spec), poster: poster, trusted: false)

        XCTAssertThrowsError(try runner.run(.hotkey(spec), tapCount: 2,
                                            waitForHotkey: true)) { error in
            guard case EmitError.accessibilityNotTrusted = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(runner.stats.lastErrorText?.contains("System Settings") == true)
    }

    func testPreflightCoversEveryBoundHotkey() {
        let ok = makeRunner(ActionBindings([1: .hotkey(spec), 2: .hotkey(.recommendedDefault)]))
        XCTAssertNoThrow(try ok.preflight())

        let untrusted = makeRunner(ActionBindings([1: .hotkey(spec)]), trusted: false)
        XCTAssertThrowsError(try untrusted.preflight())

        // A shortcut cannot be preflighted without running it, and running a
        // user's shortcut to check it is exactly what Tunk must never do.
        let shortcutOnly = makeRunner(ActionBindings([2: .shortcut(name: "Twitter")]),
                                      trusted: false)
        XCTAssertNoThrow(try shortcutOnly.preflight())
    }

    // MARK: tap counts

    func testEachCountRunsItsOwnAction() throws {
        let poster = RecordingPoster()
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(ActionBindings([1: .shortcut(name: "Twitter"),
                                                2: .hotkey(spec)]),
                                poster: poster, spawner: spawner)

        try runner.run(tapCount: 2)
        waitForEvents(poster, count: 2)
        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertTrue(spawner.names.isEmpty)

        try runner.run(tapCount: 1)
        XCTAssertEqual(spawner.names, ["Twitter"])
        XCTAssertEqual(poster.events.count, 2, "the single-tap row must not post a key")
        XCTAssertEqual(runner.stats.lastTapCount, 1)
    }

    /// The quiet no-op. This is what makes triple safe to leave unwired and
    /// single safe to leave unbound: nothing happens, and nothing complains.
    func testUnboundCountDoesNothingQuietly() throws {
        let poster = RecordingPoster()
        let spawner = FakeSpawner()
        let runner = makeRunner(double: .hotkey(spec), poster: poster, spawner: spawner)

        let single = try runner.run(tapCount: 1)
        let triple = try runner.run(tapCount: 3)

        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(spawner.names.isEmpty)
        XCTAssertNil(single.lastErrorText, "an unbound count is not an error")
        XCTAssertNil(triple.lastErrorText)
        XCTAssertNil(triple.brokenBinding)
        XCTAssertEqual(triple.unboundCount, 2)
        XCTAssertEqual(triple.runCount, 0, "nothing ran, so nothing is counted as a run")
        XCTAssertEqual(triple.lastTapCount, 3)
    }

    func testTriggerTapCountSelectsTheAction() throws {
        let poster = RecordingPoster()
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(ActionBindings([1: .shortcut(name: "Twitter"),
                                                2: .hotkey(spec)]),
                                poster: poster, spawner: spawner)

        try runner.run(for: trigger(taps: 2))
        waitForEvents(poster, count: 2)

        try runner.run(for: trigger(taps: 1))
        XCTAssertEqual(spawner.names, ["Twitter"])

        // Triple is representable but unwired: it must be silent, not an error.
        try runner.run(for: trigger(taps: 3))
        XCTAssertNil(runner.stats.lastErrorText)
        XCTAssertEqual(spawner.names.count, 1)
    }

    // MARK: the shortcut path does not block

    func testShortcutDispatchReturnsWithoutWaiting() throws {
        let spawner = FakeSpawner(.finish(after: 0.5, error: nil))
        let runner = makeRunner(double: .shortcut(name: "Twitter"), spawner: spawner)

        let t0 = EmitClock.nowNanos()
        let stats = try runner.run(tapCount: 2)
        let elapsed = EmitClock.nowNanos() - t0

        XCTAssertLessThan(elapsed, 1_000_000,
                          "dispatch took \(Double(elapsed) / 1_000_000) ms; the budget is ~1 ms "
                          + "and the detector's thread is the caller")
        XCTAssertEqual(spawner.names, ["Twitter"])
        XCTAssertEqual(stats.shortcutRunCount, 1)
        XCTAssertNil(stats.lastCompletionLatencyNs)
        XCTAssertNil(stats.lastErrorText)
        XCTAssertEqual(stats.emit.emitCount, 0, "a shortcut must not post keys")
    }

    /// Same claim, made harder: a spawner that never calls back at all, plus the
    /// name check now standing between the tap and the handoff.
    func testAHungShortcutNeverBlocksTheCaller() throws {
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(double: .shortcut(name: "Hangs Forever"), spawner: spawner)

        let t0 = EmitClock.nowNanos()
        for _ in 0..<20 { try runner.run(tapCount: 2) }
        let elapsed = EmitClock.nowNanos() - t0

        XCTAssertLessThan(elapsed, 20_000_000, "20 hung shortcuts must still cost ~nothing")
        XCTAssertEqual(spawner.names.count, 20)
        XCTAssertEqual(runner.stats.shortcutFailureCount, 0)
    }

    func testDispatchLatencyIsRecordedAndTiny() throws {
        let runner = makeRunner(double: .shortcut(name: "Twitter"),
                                spawner: FakeSpawner(.silent))
        let stats = try runner.run(tapCount: 2)
        let ns = try XCTUnwrap(stats.lastDispatchLatencyNs)
        XCTAssertGreaterThanOrEqual(ns, 0)
        XCTAssertLessThan(ns, 1_000_000)
    }

    /// The hotkey's deliberate key-down hold sits *after* the keystroke is out,
    /// so it is not part of decision-to-handoff.
    func testDispatchLatencyExcludesTheKeyDownHold() throws {
        let runner = makeRunner(double: .hotkey(spec), hold: 20_000_000)
        let t0 = EmitClock.nowNanos()
        let stats = try runner.run(.hotkey(spec), tapCount: 2, waitForHotkey: true)
        let wall = EmitClock.nowNanos() - t0

        XCTAssertGreaterThanOrEqual(wall, 15_000_000, "the key really was held")
        let dispatch = try XCTUnwrap(stats.lastDispatchLatencyNs)
        XCTAssertLessThan(dispatch, 1_000_000,
                          "the hold must not be charged to dispatch latency; got "
                          + "\(Double(dispatch) / 1_000_000) ms against a "
                          + "\(Double(wall) / 1_000_000) ms wall")
        let downAt = try XCTUnwrap(stats.emit.lastKeyDownMachNs)
        XCTAssertGreaterThan(try XCTUnwrap(stats.emit.lastEmitMachNs), downAt)
    }

    // MARK: the stale-name check — the modal-dialog guard

    /// The core of it. A name that no longer resolves must never reach the
    /// Shortcuts machinery, because an unknown name puts a modal dialog on
    /// screen and a tap is easy to trigger by accident.
    func testAStaleNameIsNeverSpawned() throws {
        let spawner = FakeSpawner()
        let resolver = FakeResolver(names: ["Something Else"])
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                spawner: spawner, resolver: resolver)

        let stats = try runner.run(tapCount: 2)

        XCTAssertTrue(spawner.names.isEmpty, "a missing name must never be spawned")
        XCTAssertGreaterThan(resolver.calls, 0, "the check must actually consult the list")
        XCTAssertEqual(stats.staleShortcutCount, 1)
        XCTAssertEqual(stats.shortcutRunCount, 0)

        let broken = try XCTUnwrap(stats.brokenBinding)
        XCTAssertEqual(broken.name, "Twitter")
        XCTAssertEqual(broken.tapCount, 2)
        XCTAssertTrue(broken.text.contains("no longer exists"), broken.text)
        XCTAssertTrue(broken.text.contains("Pick another"), broken.text)
    }

    /// Repeated taps on a stale binding stay silent and cheap. This is the real
    /// failure the check prevents: five accidental taps, five modal dialogs.
    func testRepeatedTapsOnAStaleBindingStaySilent() throws {
        let spawner = FakeSpawner()
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                spawner: spawner, resolver: FakeResolver(names: []))

        for _ in 0..<5 { XCTAssertNoThrow(try runner.run(tapCount: 2)) }

        XCTAssertTrue(spawner.names.isEmpty)
        XCTAssertEqual(runner.stats.staleShortcutCount, 5)
        XCTAssertNotNil(runner.stats.brokenBinding)
    }

    /// The one bit `wasListedWhenBound` buys: two different sentences.
    func testWordingDistinguishesRenamedFromNeverExisted() throws {
        let renamed = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                 resolver: FakeResolver(names: []))
        try renamed.run(tapCount: 2)
        let renamedText = try XCTUnwrap(renamed.stats.brokenBinding?.text)
        XCTAssertTrue(renamedText.contains("no longer exists"), renamedText)
        XCTAssertTrue(renamedText.contains("renamed or deleted"), renamedText)

        let neverThere = makeRunner(double: .shortcut(name: "Typo", wasListedWhenBound: false),
                                    resolver: FakeResolver(names: []))
        try neverThere.run(tapCount: 2)
        let neverText = try XCTUnwrap(neverThere.stats.brokenBinding?.text)
        XCTAssertTrue(neverText.contains("cannot find"), neverText)
        XCTAssertFalse(neverText.contains("no longer exists"), neverText)
    }

    /// A listing that never worked is not evidence of deletion — but it is also
    /// not permission to guess, because guessing wrong is the dialog.
    func testAnUnreadableListingRefusesToDispatch() throws {
        let spawner = FakeSpawner()
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                spawner: spawner,
                                resolver: FakeResolver(names: [], succeeded: false))

        let stats = try runner.run(tapCount: 2)

        XCTAssertTrue(spawner.names.isEmpty)
        let text = try XCTUnwrap(stats.brokenBinding?.text)
        XCTAssertTrue(text.contains("cannot read your Shortcuts"), text)
        XCTAssertTrue(text.contains("Refresh"), text)
    }

    /// A library that really is empty, listed cleanly, still means the bound
    /// name is gone — the opposite reading of the same empty array.
    func testASuccessfulEmptyListingMeansTheNameIsGone() throws {
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                resolver: FakeResolver(names: [], succeeded: true))
        try runner.run(tapCount: 2)
        let text = try XCTUnwrap(runner.stats.brokenBinding?.text)
        XCTAssertTrue(text.contains("no longer exists"), text)
    }

    func testAKnownNameDispatchesNormally() throws {
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                spawner: spawner, resolver: FakeResolver(names: ["Twitter"]))

        let stats = try runner.run(tapCount: 2)

        XCTAssertEqual(spawner.names, ["Twitter"])
        XCTAssertNil(stats.brokenBinding)
        XCTAssertEqual(stats.staleShortcutCount, 0)
    }

    /// Revalidation is the passive path: the panel opening, a wake, a slow
    /// timer. It must find the problem without a tap and without running.
    func testRevalidateFindsAStaleBindingWithoutRunningAnything() {
        let spawner = FakeSpawner()
        let resolver = FakeResolver(names: ["Twitter"])
        let runner = makeRunner(ActionBindings([1: .hotkey(spec),
                                                2: .shortcut(name: "Twitter",
                                                             wasListedWhenBound: true)]),
                                spawner: spawner, resolver: resolver)

        XCTAssertNil(runner.revalidateShortcutBindings(), "nothing wrong yet")

        resolver.set(names: ["Something Else"])
        let broken = runner.revalidateShortcutBindings()

        XCTAssertEqual(broken?.name, "Twitter")
        XCTAssertEqual(broken?.tapCount, 2)
        XCTAssertEqual(runner.stats.brokenBinding?.name, "Twitter")
        XCTAssertTrue(spawner.names.isEmpty, "revalidation must never run a Shortcut")
    }

    /// A row switched to "Run a Shortcut" but not yet pointed at one is
    /// unfinished, not broken. Reporting it would put the menubar into an error
    /// state for a row nobody armed, and would say `cannot find ""`.
    func testRevalidateIgnoresARowWithNoShortcutChosenYet() {
        let runner = makeRunner(ActionBindings([1: .shortcut(name: ""),
                                                2: .shortcut(name: "   ")]),
                                resolver: FakeResolver(names: ["Twitter"]))
        XCTAssertNil(runner.revalidateShortcutBindings())
        XCTAssertNil(runner.stats.brokenBinding)
    }

    func testRevalidateClearsItselfWhenTheNameComesBack() {
        let resolver = FakeResolver(names: [])
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                resolver: resolver)
        XCTAssertNotNil(runner.revalidateShortcutBindings())

        resolver.set(names: ["Twitter"])
        XCTAssertNil(runner.revalidateShortcutBindings())
        XCTAssertNil(runner.stats.brokenBinding)
    }

    /// Reconfiguring is the user answering the complaint. It must not persist
    /// past the change that may have fixed it.
    func testChangingBindingsClearsTheBrokenState() throws {
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                resolver: FakeResolver(names: []))
        try runner.run(tapCount: 2)
        XCTAssertNotNil(runner.stats.brokenBinding)

        runner.bindings = ActionBindings([2: .hotkey(spec)])
        XCTAssertNil(runner.stats.brokenBinding)
        XCTAssertNil(runner.stats.lastErrorText)
    }

    func testBrokenBindingReachesTheOnChangeHook() throws {
        let runner = makeRunner(double: .shortcut(name: "Twitter", wasListedWhenBound: true),
                                resolver: FakeResolver(names: []))
        let sink = StatsSink()
        runner.onChange = { sink.record($0) }

        try runner.run(tapCount: 2)

        XCTAssertTrue(sink.all.contains { $0.brokenBinding?.name == "Twitter" },
                      "the menubar learns about this through onChange and nowhere else")
    }

    // MARK: other shortcut paths

    func testFailingShortcutSurfacesAnErrorWithoutThrowing() throws {
        let spawner = FakeSpawner(.finish(after: 0,
                                          error: .shortcutFailed(name: "Twitter", exitCode: 1,
                                                                 detail: "no such shortcut")))
        let runner = makeRunner(double: .shortcut(name: "Twitter"), spawner: spawner)
        let sink = StatsSink()
        runner.onChange = { sink.record($0) }

        // This is the detector's call. It must not throw.
        XCTAssertNoThrow(try runner.run(tapCount: 2))

        let reported = expectation(description: "failure reported")
        pollUntil(reported) { runner.stats.shortcutFailureCount == 1 }
        wait(for: [reported], timeout: 2)

        let stats = runner.stats
        let text = try XCTUnwrap(stats.lastErrorText)
        XCTAssertTrue(text.contains("Twitter"), "the user must be told which one: \(text)")
        XCTAssertTrue(text.contains("no such shortcut"), "stderr must reach the panel: \(text)")
        XCTAssertNotNil(stats.lastCompletionLatencyNs)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertGreaterThanOrEqual(sink.all.count, 2)
    }

    func testShortcutWithNoNameChosenSpawnsNothingAndExplainsItself() throws {
        let spawner = FakeSpawner()
        let runner = makeRunner(double: .shortcut(name: "  "), spawner: spawner)

        let stats = try runner.run(tapCount: 2)

        XCTAssertTrue(spawner.names.isEmpty, "an empty name must never reach the spawner")
        XCTAssertEqual(stats.shortcutRunCount, 0)
        XCTAssertTrue(stats.lastErrorText?.contains("no Shortcut has been picked") == true)
    }

    func testShortcutNameIsTrimmedBeforeSpawning() throws {
        let spawner = FakeSpawner(.silent)
        let runner = makeRunner(double: .shortcut(name: "  Twitter  "), spawner: spawner,
                                resolver: FakeResolver(names: ["Twitter"]))
        try runner.run(tapCount: 2)
        XCTAssertEqual(spawner.names, ["Twitter"])
    }

    func testNoneRunsCleanlyAndTouchesNothing() throws {
        let poster = RecordingPoster()
        let spawner = FakeSpawner()
        let runner = makeRunner(ActionBindings(), poster: poster, spawner: spawner)

        let stats = try runner.run(.none, tapCount: 2)

        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(spawner.names.isEmpty)
        XCTAssertEqual(stats.emit.emitCount, 0)
        XCTAssertNil(stats.lastErrorText)
    }

    // MARK: threading

    func testConcurrentRunsOfMixedCountsStayConsistent() {
        let poster = RecordingPoster()
        let spawner = FakeSpawner(.finish(after: 0, error: nil))
        let runner = makeRunner(ActionBindings([1: .shortcut(name: "Twitter"),
                                                2: .hotkey(spec)]),
                                poster: poster, spawner: spawner)

        DispatchQueue.concurrentPerform(iterations: 60) { i in
            _ = try? runner.run(tapCount: i.isMultiple(of: 2) ? 2 : 1)
        }

        waitForEvents(poster, count: 60)
        let stats = runner.stats
        XCTAssertEqual(stats.runCount, 60)
        XCTAssertEqual(stats.emit.unbalancedPairs, 0)
        XCTAssertEqual(stats.emit.keyDownsPosted, 30)
        XCTAssertEqual(stats.emit.keyUpsPosted, 30)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertEqual(spawner.names.count, 30)
    }

    // MARK: helper

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

// MARK: - Not blocking the sensor thread, and not interleaving pairs

/// The emitter posts a pair with an 8 ms key-down hold. In production the caller
/// is the 796 Hz HID delivery callback, where a sample arrives every 1.26 ms, so
/// whether that hold runs on the caller's thread decides whether firing corrupts
/// the stream the gesture was detected in.
final class EmitterBlockingTests: XCTestCase {

    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])
    private static let hold: Int64 = 8_000_000

    private func makeEmitter(_ poster: RecordingPoster,
                             hold: Int64 = EmitterBlockingTests.hold) -> HotkeyEmitter {
        HotkeyEmitter(hotkey: spec,
                      options: .init(includeDeviceSideFlags: true,
                                     keyDownHoldNs: hold,
                                     requireAccessibility: true),
                      poster: poster,
                      permission: AlwaysTrustedPermission(),
                      secureInput: StubSecureInput(active: false))
    }

    /// The measurement. `emit` is allowed to block — the Test button wants an
    /// answer — and `emitAsync` is not, because the detector calls it.
    func testAsyncEmitDoesNotBlockTheCallerButSyncEmitDoes() {
        let emitter = makeEmitter(RecordingPoster())

        let syncStart = EmitClock.nowNanos()
        _ = try? emitter.emit()
        let syncCost = EmitClock.nowNanos() - syncStart

        let asyncStart = EmitClock.nowNanos()
        emitter.emitAsync()
        let asyncCost = EmitClock.nowNanos() - asyncStart

        XCTAssertGreaterThan(syncCost, Self.hold / 2,
                             "emit() should still hold the key, on its own caller's thread")
        // One sensor sample period is 1.256 ms. Handing the pair to a queue has
        // to cost a small fraction of that, not a multiple of it.
        XCTAssertLessThan(asyncCost, 500_000,
                          "emitAsync blocked for \(Double(asyncCost) / 1_000_000) ms; the sensor "
                          + "callback has 1.256 ms between samples")
    }

    /// Worst case over many calls, which is what a dropped-sample budget cares
    /// about. A single fast call proves nothing.
    func testAsyncEmitWorstCaseStaysUnderOneSamplePeriod() {
        let emitter = makeEmitter(RecordingPoster())
        var worst: Int64 = 0
        for _ in 0..<200 {
            let t0 = EmitClock.nowNanos()
            emitter.emitAsync()
            worst = max(worst, EmitClock.nowNanos() - t0)
        }
        XCTAssertLessThan(worst, 1_256_000,
                          "worst handoff was \(Double(worst) / 1_000_000) ms, which is longer "
                          + "than the 1.256 ms between accelerometer samples")
    }

    /// Whichever way it is started, the pair must come out whole.
    func testAsyncEmitStillPostsABalancedPair() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster)

        emitter.emitAsync()
        let done = expectation(description: "pair posted")
        pollUntil(done) { poster.events.count == 2 }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertFalse(emitter.stats.hasStuckKey)
        XCTAssertEqual(emitter.stats.unbalancedPairs, 0)
        XCTAssertEqual(emitter.stats.pairsCompleted, 1)
    }

    /// The interleaving the aggregate counters could not see. Fifty concurrent
    /// emissions must produce fifty strict down/up pairs, never a run of downs.
    func testConcurrentEmissionsNeverInterleaveTwoPairs() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster, hold: 0)

        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = try? emitter.emit()
        }

        let phases = poster.events.map(\.phase)
        XCTAssertEqual(phases.count, 100)
        for i in stride(from: 0, to: phases.count, by: 2) {
            XCTAssertEqual(phases[i], .down, "a second key went down before the first came up")
            XCTAssertEqual(phases[i + 1], .up)
        }
        XCTAssertEqual(emitter.stats.pairsCompleted, 50)
        XCTAssertEqual(emitter.stats.unbalancedPairs, 0)
        XCTAssertFalse(emitter.stats.hasStuckKey)
    }

    func testMixedSyncAndAsyncEmissionsStayOrdered() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster, hold: 0)

        DispatchQueue.concurrentPerform(iterations: 40) { i in
            if i.isMultiple(of: 2) { emitter.emitAsync() } else { _ = try? emitter.emit() }
        }
        let done = expectation(description: "all pairs posted")
        pollUntil(done) { poster.events.count == 80 }
        wait(for: [done], timeout: 5)

        let phases = poster.events.map(\.phase)
        for i in stride(from: 0, to: phases.count, by: 2) {
            XCTAssertEqual(phases[i], .down)
            XCTAssertEqual(phases[i + 1], .up)
        }
        XCTAssertEqual(emitter.stats.unbalancedPairs, 0)
    }

    /// Per-emission detection. A failing key-up is the one shape that really
    /// strands a key, and it has to be visible as one bad pair rather than only
    /// as a difference between two totals.
    func testAFailedKeyUpIsCountedAsOneUnbalancedPair() {
        let poster = RecordingPoster(failMode: .onPost(.up))
        let emitter = makeEmitter(poster, hold: 0)

        XCTAssertThrowsError(try emitter.emit())

        XCTAssertEqual(emitter.stats.pairsCompleted, 1)
        XCTAssertEqual(emitter.stats.unbalancedPairs, 1)
        XCTAssertTrue(emitter.stats.hasStuckKey)
    }

    /// A pair that never posted its down is not an unbalanced pair — nothing was
    /// left held. Counting it would cry wolf on every permission failure.
    func testAPairThatNeverStartedIsNotCountedAsUnbalanced() {
        let poster = RecordingPoster(failMode: .onPost(.down))
        let emitter = makeEmitter(poster, hold: 0)

        XCTAssertThrowsError(try emitter.emit())

        XCTAssertEqual(emitter.stats.pairsCompleted, 0)
        XCTAssertEqual(emitter.stats.unbalancedPairs, 0)
        XCTAssertFalse(emitter.stats.hasStuckKey)
        XCTAssertEqual(poster.events.map(\.phase), [.up], "the up still goes out")
    }

    /// `ActionRunner` is what the detector actually calls, so the no-blocking
    /// claim has to hold through it too.
    func testActionRunnerHotkeyPathDoesNotBlockTheDetector() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster)
        let runner = ActionRunner(bindings: ActionBindings([2: .hotkey(spec)]),
                                  emitter: emitter,
                                  spawner: FakeSpawner(.silent),
                                  resolver: FakeResolver())

        var worst: Int64 = 0
        for _ in 0..<50 {
            let t0 = EmitClock.nowNanos()
            try runner.run(tapCount: 2)
            worst = max(worst, EmitClock.nowNanos() - t0)
        }

        XCTAssertLessThan(worst, 1_256_000,
                          "worst run() was \(Double(worst) / 1_000_000) ms against a 1.256 ms "
                          + "sample period")
        let done = expectation(description: "all pairs posted")
        pollUntil(done) { poster.events.count == 100 }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(emitter.stats.unbalancedPairs, 0)
    }

    private func pollUntil(_ exp: XCTestExpectation,
                           timeout: TimeInterval = 10,
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

// MARK: - Dropping the modifiers the pair asserted

/// The pair stamps modifier flags on both halves on purpose, and nothing in the
/// pair ever drops them. Measured against the live window server: after one
/// emission the chord was still reported as held at t+15 s and across process
/// boundaries — it does not decay, it waits for an event that says otherwise.
/// So the emitter posts a keyless `flagsChanged` after the up.
final class ModifierReleaseTests: XCTestCase {

    private let chord = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    private func makeEmitter(_ poster: RecordingPoster,
                             hold: Int64 = 0,
                             trusted: Bool = true) -> HotkeyEmitter {
        HotkeyEmitter(hotkey: chord,
                      options: .init(includeDeviceSideFlags: true,
                                     keyDownHoldNs: hold,
                                     requireAccessibility: true),
                      poster: poster,
                      permission: AlwaysTrustedPermission(isTrusted: trusted),
                      secureInput: StubSecureInput(active: false))
    }

    func testTheModifiersAreReleasedAfterAChord() throws {
        let poster = RecordingPoster()
        try makeEmitter(poster).emit()

        XCTAssertEqual(poster.modifierReleases, 1)
        XCTAssertEqual(poster.events.map(\.phase), [.down, .up],
                       "the release must not count as a third key event")
    }

    /// The release is not part of the pair, so it must not disturb any balance
    /// assertion — including the ones in other suites that predate it.
    func testTheReleaseDoesNotChangeTheEventCount() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster)
        for _ in 0..<20 { try emitter.emit() }

        XCTAssertEqual(poster.events.count, 40)
        XCTAssertEqual(poster.modifierReleases, 20)
        XCTAssertEqual(emitter.stats.unbalancedPairs, 0)
    }

    /// The path that matters most. A failed key-up is exactly when a modifier is
    /// most likely to be left asserted, so the release must still go out.
    func testTheReleaseStillRunsWhenTheKeyUpFails() {
        let poster = RecordingPoster(failMode: .onPost(.up))
        let emitter = makeEmitter(poster)

        XCTAssertThrowsError(try emitter.emit())

        XCTAssertEqual(poster.modifierReleases, 1,
                       "a failed up is the case this exists for")
        XCTAssertTrue(emitter.stats.hasStuckKey, "and it is still reported as unbalanced")
    }

    func testTheReleaseStillRunsWhenTheKeyDownFails() {
        let poster = RecordingPoster(failMode: .onPost(.down))
        let emitter = makeEmitter(poster)

        XCTAssertThrowsError(try emitter.emit())
        XCTAssertEqual(poster.modifierReleases, 1)
    }

    /// Nothing was posted at all, so there is nothing to release.
    func testNothingIsReleasedWhenTheEmissionNeverStarted() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster, trusted: false)

        XCTAssertThrowsError(try emitter.emit())
        XCTAssertEqual(poster.modifierReleases, 0)
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// A shortcut with no modifiers asserts none, so it has none to drop.
    func testAKeyWithNoModifiersPostsNoRelease() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster)
        try emitter.emit(HotkeySpec(keyCode: 41, modifiers: []))

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertEqual(poster.modifierReleases, 0)
    }

    func testTheAsyncPathReleasesToo() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster)
        emitter.emitAsync()

        let done = expectation(description: "released")
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                if poster.modifierReleases == 1 { done.fulfill(); return }
                usleep(2000)
            }
        }
        wait(for: [done], timeout: 6)
        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
    }
}

// MARK: - Secure input

/// `CGEvent.post` returns void and cannot fail. While another process holds
/// secure event input — any password field does — the window server drops the
/// event. Without a check, that is recorded as a successful emission.
final class SecureInputTests: XCTestCase {

    private let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

    private func makeEmitter(_ poster: RecordingPoster, secureInput active: Bool) -> HotkeyEmitter {
        HotkeyEmitter(hotkey: spec,
                      options: .init(includeDeviceSideFlags: true,
                                     keyDownHoldNs: 0,
                                     requireAccessibility: true),
                      poster: poster,
                      permission: AlwaysTrustedPermission(),
                      secureInput: StubSecureInput(active: active))
    }

    func testSecureInputBlocksTheEmissionInsteadOfFakingSuccess() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster, secureInput: true)

        XCTAssertThrowsError(try emitter.emit()) { error in
            guard case EmitError.secureInputActive = error else {
                return XCTFail("wrong error: \(error)")
            }
        }

        XCTAssertTrue(poster.events.isEmpty, "nothing may be posted while it would be dropped")
        XCTAssertEqual(emitter.stats.emitCount, 0,
                       "the count that means 'it fired' must not move when it did not")
        XCTAssertEqual(emitter.stats.failureCount, 1)
        XCTAssertFalse(emitter.stats.hasStuckKey)
    }

    func testSecureInputErrorTellsTheUserWhatToDo() {
        let text = EmitError.secureInputActive.description
        XCTAssertTrue(text.contains("secure input"), text)
        let fix = try? XCTUnwrap(EmitError.secureInputActive.recoverySuggestion)
        XCTAssertTrue(fix?.contains("password field") == true, fix ?? "")
        XCTAssertTrue(fix?.contains("did not send") == true,
                      "it must say nothing was sent, not imply something was")
    }

    func testPreflightCatchesSecureInputBeforeAnyTap() {
        let emitter = makeEmitter(RecordingPoster(), secureInput: true)
        XCTAssertThrowsError(try emitter.preflight())

        let clear = makeEmitter(RecordingPoster(), secureInput: false)
        XCTAssertNoThrow(try clear.preflight())
    }

    func testNormalEmissionIsUnaffectedWhenSecureInputIsOff() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster, secureInput: false)
        try emitter.emit()
        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertEqual(emitter.stats.emitCount, 1)
    }

    /// The async path cannot throw back to the detector, so the failure has to
    /// reach the panel through the runner instead of vanishing.
    func testSecureInputFailureOnTheAsyncPathReachesTheRunner() {
        let emitter = makeEmitter(RecordingPoster(), secureInput: true)
        let runner = ActionRunner(bindings: ActionBindings([2: .hotkey(spec)]),
                                  emitter: emitter,
                                  spawner: FakeSpawner(.silent),
                                  resolver: FakeResolver())

        XCTAssertNoThrow(try runner.run(tapCount: 2))

        let reported = expectation(description: "surfaced")
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(2)
            while Date() < end {
                if runner.stats.lastErrorText?.contains("secure input") == true {
                    reported.fulfill(); return
                }
                usleep(2000)
            }
        }
        wait(for: [reported], timeout: 3)
        XCTAssertEqual(runner.stats.emit.emitCount, 0)
    }
}

// MARK: - Settings migration

final class SettingsMigrationTests: XCTestCase {

    /// The owner's actual persisted values, from the lead's report: a gate below
    /// the safe floor, a join window wider than the confirm window, and a
    /// confirm window from before the default moved to 220 ms.
    private var ownersStoredConfig: DetectorConfig {
        var c = DetectorConfig.default
        c.gateWindowNs = 110_000_000
        c.maxInterTapNs = 400_000_000
        c.confirmWindowNs = 180_000_000
        return c
    }

    func testTheOwnersConfigIsMadeSafeAndCoherent() {
        let result = SettingsMigration.migrate(ownersStoredConfig)

        XCTAssertTrue(result.changed)
        XCTAssertGreaterThanOrEqual(result.config.gateWindowNs,
                                    SettingsMigration.minimumSafeGateNs,
                                    "the gate must end up covering typing")
        XCTAssertLessThanOrEqual(result.config.maxInterTapNs, result.config.confirmWindowNs,
                                 "the invariant must hold afterwards")
        XCTAssertTrue(result.config.isCoherent)
    }

    /// The join window is widened by raising the confirm window rather than by
    /// clamping the spacing down to an old, shorter one.
    func testAWideJoinWindowIsKeptByRaisingTheConfirmWindow() {
        let result = SettingsMigration.migrate(ownersStoredConfig)
        XCTAssertEqual(result.config.confirmWindowNs, DetectorConfig.default.confirmWindowNs)
        XCTAssertEqual(result.config.maxInterTapNs, DetectorConfig.default.confirmWindowNs,
                       "clamped to the new window, not down to the old 180 ms")
    }

    func testEveryChangeIsExplained() throws {
        let notes = SettingsMigration.migrate(ownersStoredConfig).notes
        XCTAssertFalse(notes.isEmpty)
        for note in notes {
            XCTAssertFalse(note.field.isEmpty)
            XCTAssertFalse(note.was.isEmpty, "\(note.field) must say what it was")
            XCTAssertFalse(note.now.isEmpty, "\(note.field) must say what it is now")
            XCTAssertFalse(note.why.isEmpty, "\(note.field) must say why")
        }
        let gate = try XCTUnwrap(notes.first { $0.field == "Gate window" })
        XCTAssertEqual(gate.was, "110 ms")
        XCTAssertEqual(gate.now, "180 ms")
        XCTAssertTrue(gate.why.contains("typing"), gate.why)
    }

    /// These strings go in front of a user. A raw field name like
    /// `maxInterTapNs` leaking into the panel is a defect, not a detail.
    func testNotesAreWrittenForAUserNotForTheSource() {
        for note in SettingsMigration.migrate(ownersStoredConfig).notes {
            XCTAssertFalse(note.field.contains("Ns"),
                           "\"\(note.field)\" is a code identifier, not a label")
            XCTAssertEqual(note.field, note.field.prefix(1).uppercased() + note.field.dropFirst(),
                           "\"\(note.field)\" should read as a label")
            let first = try? XCTUnwrap(note.why.first)
            XCTAssertEqual(String(first ?? " "), String(first ?? " ").uppercased(),
                           "\"\(note.why)\" should start as a sentence")
            XCTAssertTrue(note.why.hasSuffix("."), "\"\(note.why)\" should end as a sentence")
        }
    }

    /// The rule that keeps this from being a reset button.
    func testASafeCoherentConfigIsLeftCompletelyAlone() {
        let mine = {
            var c = DetectorConfig.default
            c.sensitivity = 1.4                     // deliberately chosen
            c.gateWindowNs = 200_000_000            // safe
            c.calibratedThreshold = 0.37            // learned from real taps
            return c
        }()

        let result = SettingsMigration.migrate(mine)

        XCTAssertFalse(result.changed, "nothing was unsafe or incoherent")
        XCTAssertEqual(result.config, mine)
        XCTAssertTrue(result.notes.isEmpty)
    }

    /// Calibration is the user's own measurement of their own hand. A migration
    /// that threw it away would cost them the "learn my tap" step.
    func testCalibrationAndSensitivitySurviveAMigration() {
        var stored = ownersStoredConfig
        stored.calibratedThreshold = 0.42
        stored.sensitivity = 1.25

        let result = SettingsMigration.migrate(stored)

        XCTAssertEqual(result.config.calibratedThreshold, 0.42)
        XCTAssertEqual(result.config.sensitivity, 1.25)
    }

    func testAGateAtTheFloorIsNotTouched() {
        var stored = DetectorConfig.default
        stored.gateWindowNs = SettingsMigration.minimumSafeGateNs
        XCTAssertFalse(SettingsMigration.migrate(stored).changed)
    }

    func testMigrationIsIdempotent() {
        let once = SettingsMigration.migrate(ownersStoredConfig)
        let twice = SettingsMigration.migrate(once.config)
        XCTAssertFalse(twice.changed, "a migrated config must not migrate again")
        XCTAssertEqual(twice.config, once.config)
    }
}

// MARK: - The arming contract the app wiring depends on

/// `Engine` binds actions per tap count and must arm the detector to match. The
/// detector exposes two places a count can be named — `config.armedTapCounts`
/// and `TapDetector.armedTapCounts` — and they do not mean the same thing.
/// These tests pin the difference, because getting it wrong silently disables
/// double tap, which no unit test of `ActionRunner` would catch.
final class DetectorArmingContractTests: XCTestCase {

    private func fires(armed: Set<Int>?, taps: Int) -> Bool {
        var config = DetectorConfig.default
        config.armedTapCounts = [1, 2]
        config.calibratedThreshold = 0.2
        let detector = TapDetector(config: config, armedTapCounts: armed)
        let (stream, _) = SyntheticStream.gesture(count: taps, spacingNs: 150_000_000)
        for sample in stream.samples() where detector.ingest(sample: sample) != nil {
            return true
        }
        return false
    }

    /// What `DetectorFactory` now does: pass the set explicitly.
    func testExplicitArmingFiresEveryArmedCount() {
        XCTAssertTrue(fires(armed: [1, 2], taps: 1), "single tap must fire when armed")
        XCTAssertTrue(fires(armed: [1, 2], taps: 2), "double tap must fire when armed")
    }

    /// This test used to assert the trap: `nil` derived the firing counts from
    /// `config.tapCountToFire`, the *lowest* armed count, so a config armed for
    /// both fired single only and double-tap silently did nothing. It said
    /// "if this ever passes, the detector's nil default changed and
    /// DetectorFactory can stop compensating for it".
    ///
    /// That is exactly what happened: the detector now reads the whole
    /// `config.armedTapCounts`, so `nil` is safe and the factory no longer has
    /// to compensate. Inverted rather than deleted, so the trap stays closed.
    func testLeavingArmingNilHonoursEveryArmedCount() {
        XCTAssertTrue(fires(armed: nil, taps: 1))
        XCTAssertTrue(fires(armed: nil, taps: 2),
                      "with single and double both armed, omitting the override must "
                      + "still fire double — deriving from the lowest count is the bug")
    }

    /// An unarmed count is silent, not an error — the quiet no-op the panel and
    /// `ActionRunner` both rely on.
    func testUnarmedCountFiresNothing() {
        XCTAssertFalse(fires(armed: [2], taps: 1))
        XCTAssertFalse(fires(armed: [1], taps: 2))
    }

    /// `ActionBindings.boundCounts` is what the app feeds into arming, so the
    /// two vocabularies have to line up.
    func testBoundCountsAreUsableAsAnArmingSet() {
        let bindings = ActionBindings([1: .shortcut(name: "Twitter"),
                                       2: .hotkey(.recommendedDefault)])
        let armed = Set(bindings.boundCounts)
        XCTAssertEqual(armed, [1, 2])
        XCTAssertTrue(armed.isSubset(of: Set(DetectorConfig.supportedTapCounts)))

        XCTAssertEqual(Set(ActionBindings.default.boundCounts), [2],
                       "the shipped default must arm double only")
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
        // Ten times the watchdog, and short enough that the run leaves no
        // long-lived orphan behind — the spawner deliberately does not kill it.
        let script = try makeScript("sleep 2\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0.2)

        let outcome = try run(spawner, name: "Waits For You", timeout: 5)
        guard case .shortcutTimedOut(let name, _)? = outcome.error else {
            return XCTFail("wrong error: \(String(describing: outcome.error))")
        }
        XCTAssertEqual(name, "Waits For You")
    }

    func testCompletionIsDeliveredExactlyOnce() throws {
        let script = try makeScript("sleep 0.3\n")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0.1)

        let counter = CallCounter()
        spawner.spawn(shortcut: "Racy") { _ in counter.bump() }
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

    /// The distinction the whole stale-name check rests on: an empty list that
    /// worked is not the same as an empty list that failed.
    func testListingSeparatesEmptyFromBroken() {
        let empty = ShortcutsListing(names: [], succeeded: true)
        XCTAssertFalse(empty.contains("Twitter"))
        XCTAssertTrue(empty.succeeded)

        XCTAssertFalse(ShortcutsListing.unknown.succeeded)
        XCTAssertFalse(ShortcutsListing.unknown.contains("Twitter"))
        XCTAssertNotEqual(empty, .unknown)
    }

    func testListingMembershipTrimsTheQuery() {
        let listing = ShortcutsListing(names: ["Twitter"], succeeded: true)
        XCTAssertTrue(listing.contains("  Twitter  "))
        XCTAssertFalse(listing.contains("twitter"), "names are case sensitive")
    }

    /// Read-only. `shortcuts list` names the operator's Shortcuts; it does not
    /// run any of them. Asserting a count would depend on this machine, so the
    /// test asserts what is promised: it answers, it does not throw, the cache
    /// is stable, and a present CLI produces a successful listing.
    func testListingIsSafeCachedAndNeverThrows() {
        ShortcutsCatalog.invalidate()
        let first = ShortcutsCatalog.listing()
        let cached = ShortcutsCatalog.listing()
        XCTAssertEqual(first, cached, "second call must come from the cache")

        let refreshed = ShortcutsCatalog.refreshListing()
        XCTAssertEqual(refreshed, first, "the library did not change during this test")

        if ShortcutsCatalog.isCLIAvailable {
            XCTAssertTrue(first.succeeded, "the CLI is present, so listing must work")
        } else {
            XCTAssertFalse(first.succeeded)
            XCTAssertTrue(first.names.isEmpty)
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
