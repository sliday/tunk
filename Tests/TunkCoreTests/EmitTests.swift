import ApplicationServices
import CoreGraphics
import XCTest
@testable import TunkEmit

// Emission tests. Two layers:
//
//   1. API-level balance, with an injected `RecordingPoster`. Always runs, needs
//      no permission, and covers the error paths a real tap cannot produce on
//      demand (event creation failing, the post itself failing).
//   2. A real CGEventTap watching the HID tap location. Needs Accessibility
//      permission, which the xctest host does not have by default, so it
//      `XCTSkip`s with an explicit message rather than passing vacuously.
//
// If you see the tap test skipped, layer 1 is what proved the invariant.

final class HotkeySpecTests: XCTestCase {

    func testDescriptionUsesAppleModifierOrder() {
        let spec = HotkeySpec(keyCode: 41, modifiers: [.command, .control, .option])
        XCTAssertEqual(spec.description, "Ctrl+Opt+Cmd+;")
        XCTAssertEqual(spec.symbolicDescription, "\u{2303}\u{2325}\u{2318};")
    }

    func testParsesWordForm() throws {
        let spec = try HotkeySpec(parsing: "Ctrl+Opt+Cmd+;")
        XCTAssertEqual(spec.keyCode, 41)
        XCTAssertEqual(spec.modifiers, [.control, .option, .command])
    }

    func testParsesGlyphForm() throws {
        let spec = try HotkeySpec(parsing: "\u{2303}\u{2325}\u{2318};")
        XCTAssertEqual(spec, HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command]))
    }

    func testParsingIsCaseAndSpellingTolerant() throws {
        let variants = [
            "control+option+command+semicolon",
            "CTRL + ALT + META + ;",
            "ctrl-opt-cmd-;",
            "  Ctrl+Opt+Cmd+;  ",
        ]
        for v in variants {
            XCTAssertEqual(try HotkeySpec(parsing: v),
                           HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command]),
                           "failed on \"\(v)\"")
        }
    }

    func testParsesPunctuationKeysThatLookLikeSeparators() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "Ctrl+Cmd+-").keyCode, 27)   // minus
        XCTAssertEqual(try HotkeySpec(parsing: "Ctrl+Cmd++").keyCode, 24)   // equal
        XCTAssertEqual(try HotkeySpec(parsing: "Cmd+\\").keyCode, 42)
    }

    func testRejectsBareModifierAndGarbage() {
        for bad in ["", "Cmd", "Cmd+", "\u{2318}", "Ctrl+Opt+Cmd+Nope"] {
            XCTAssertThrowsError(try HotkeySpec(parsing: bad), "should reject \"\(bad)\"") { error in
                guard case EmitError.invalidHotkey = error else {
                    return XCTFail("wrong error for \"\(bad)\": \(error)")
                }
            }
        }
    }

    func testEveryKnownKeyCodeRoundTrips() throws {
        for code in KeyCodes.knownCodes {
            let spec = HotkeySpec(keyCode: code, modifiers: [.control, .shift, .option, .command, .function])
            let text = spec.description
            XCTAssertEqual(try HotkeySpec(parsing: text), spec, "round trip failed for \(text)")
        }
    }

    func testUnnamedKeyCodeRoundTripsThroughEscape() throws {
        let spec = HotkeySpec(keyCode: 200, modifiers: [.command])
        XCTAssertEqual(spec.description, "Cmd+#200")
        XCTAssertEqual(try HotkeySpec(parsing: spec.description), spec)
    }

    func testCodableIsTheSameStringAUserTypes() throws {
        let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])
        let json = try JSONEncoder().encode(["hotkey": spec])
        XCTAssertEqual(String(data: json, encoding: .utf8), #"{"hotkey":"Ctrl+Opt+Cmd+;"}"#)

        let back = try JSONDecoder().decode([String: HotkeySpec].self, from: json)
        XCTAssertEqual(back["hotkey"], spec)
    }

    func testDecodingGarbageThrowsDecodingError() {
        let json = Data(#"{"hotkey":"Ctrl+Opt+Cmd+Nope"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([String: HotkeySpec].self, from: json))
    }

    func testEventFlagsCoverBothHalvesOfTheModifierSet() {
        let spec = HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command])

        let independent = spec.eventFlags(includeDeviceSide: false)
        XCTAssertTrue(independent.contains(.maskControl))
        XCTAssertTrue(independent.contains(.maskAlternate))
        XCTAssertTrue(independent.contains(.maskCommand))
        XCTAssertFalse(independent.contains(.maskShift))
        XCTAssertEqual(independent.rawValue & 0xFF, 0, "no device bits when asked for none")

        let hardwareLike = spec.eventFlags(includeDeviceSide: true)
        XCTAssertEqual(hardwareLike.rawValue & 0x0000_0001, 0x0000_0001) // left control
        XCTAssertEqual(hardwareLike.rawValue & 0x0000_0008, 0x0000_0008) // left command
        XCTAssertEqual(hardwareLike.rawValue & 0x0000_0020, 0x0000_0020) // left option
        XCTAssertEqual(hardwareLike.rawValue & 0x0000_0002, 0)           // no shift bit
    }

    func testSuggestedDefaultsAreDistinctAndMultiModifier() {
        let specs = HotkeySpec.suggested.map(\.spec)
        XCTAssertEqual(Set(specs).count, specs.count, "suggestions must not repeat")
        for s in specs {
            XCTAssertGreaterThanOrEqual(s.modifiers.rawValue.nonzeroBitCount, 3,
                                        "\(s) is not rare enough to ship as a default")
            XCTAssertEqual(try? HotkeySpec(parsing: s.description), s)
        }
        XCTAssertEqual(HotkeySpec.recommendedDefault.description, "Ctrl+Opt+Cmd+;")
    }

    /// Measured: a Carbon hot key on F16 never fires for a synthesised event,
    /// with any modifier set or event source state, while punctuation keys do.
    /// So every default must be a single printable key the user can also press
    /// while recording the shortcut in VoiceInk.
    func testSuggestedDefaultsAvoidTheFunctionRow() {
        for s in HotkeySpec.suggested {
            let name = KeyCodes.name(for: s.spec.keyCode)
            XCTAssertEqual(name.count, 1,
                           "\(name) is not a plain printable key; F-row keys do not reach "
                           + "Carbon hot key listeners when synthesised")
        }
    }
}

final class HotkeyEmitterBalanceTests: XCTestCase {

    private func makeEmitter(poster: RecordingPoster,
                             trusted: Bool = true,
                             hold: Int64 = 0) -> HotkeyEmitter {
        HotkeyEmitter(hotkey: HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command]),
                      options: .init(includeDeviceSideFlags: true,
                                     keyDownHoldNs: hold,
                                     requireAccessibility: true),
                      poster: poster,
                      permission: AlwaysTrustedPermission(isTrusted: trusted))
    }

    func testEmitPostsExactlyOneDownThenOneUp() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster)

        let stats = try emitter.emit()

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertEqual(stats.emitCount, 1)
        XCTAssertEqual(stats.keyDownsPosted, 1)
        XCTAssertEqual(stats.keyUpsPosted, 1)
        XCTAssertFalse(stats.hasStuckKey)
    }

    func testFlagsAreIdenticalOnDownAndUp() throws {
        let poster = RecordingPoster()
        let spec = HotkeySpec(keyCode: 39, modifiers: [.control, .option, .shift, .command])
        let emitter = makeEmitter(poster: poster)

        try emitter.emit(spec)

        let events = poster.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].flagsRaw, events[1].flagsRaw)
        XCTAssertEqual(events[0].flagsRaw, spec.eventFlags(includeDeviceSide: true).rawValue)
        XCTAssertEqual(events[0].keyCode, events[1].keyCode)
        XCTAssertEqual(events[0].keyCode, 39)
    }

    func testHundredEmissionsStayBalanced() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster)

        for _ in 0..<100 { try emitter.emit() }

        let phases = poster.events.map(\.phase)
        XCTAssertEqual(phases.count, 200)
        for i in stride(from: 0, to: phases.count, by: 2) {
            XCTAssertEqual(phases[i], .down)
            XCTAssertEqual(phases[i + 1], .up)
        }
        XCTAssertFalse(emitter.stats.hasStuckKey)
        XCTAssertEqual(emitter.stats.emitCount, 100)
    }

    func testConcurrentEmissionsNeverStrandAKeyDown() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster)

        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = try? emitter.emit()
        }

        let stats = emitter.stats
        XCTAssertEqual(stats.keyDownsPosted, 50)
        XCTAssertEqual(stats.keyUpsPosted, 50)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertEqual(poster.events.filter { $0.phase == .down }.count,
                       poster.events.filter { $0.phase == .up }.count)
    }

    // The point of the funnel: a failure anywhere still leaves no key held.

    func testKeyUpStillGoesOutWhenTheKeyDownPostFails() {
        let poster = RecordingPoster(failMode: .onPost(.down))
        let emitter = makeEmitter(poster: poster)

        XCTAssertThrowsError(try emitter.emit())

        XCTAssertEqual(poster.events.map(\.phase), [.up], "the up must go out even so")
        let stats = emitter.stats
        XCTAssertEqual(stats.keyDownsPosted, 0)
        XCTAssertEqual(stats.keyUpsPosted, 1)
        XCTAssertFalse(stats.hasStuckKey)
        XCTAssertEqual(stats.emitCount, 0)
        XCTAssertEqual(stats.failureCount, 1)
    }

    func testFailingKeyUpIsReportedAndCountedAsStuck() {
        let poster = RecordingPoster(failMode: .onPost(.up))
        let emitter = makeEmitter(poster: poster)

        XCTAssertThrowsError(try emitter.emit())

        // This is the one shape that would strand a key. It cannot be recovered
        // from below CoreGraphics, so it must at least be visible.
        XCTAssertTrue(emitter.stats.hasStuckKey)
        XCTAssertNotNil(emitter.stats.lastErrorText)
    }

    func testUnbuildableKeyEventPostsNothingAtAll() {
        let poster = RecordingPoster(failMode: .onValidate(.up))
        let emitter = makeEmitter(poster: poster)

        XCTAssertThrowsError(try emitter.emit()) { error in
            guard case EmitError.eventCreationFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(poster.events.isEmpty, "validation runs before anything is posted")
        XCTAssertFalse(emitter.stats.hasStuckKey)
    }

    func testMissingAccessibilityThrowsActionableErrorAndPostsNothing() {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster, trusted: false)

        XCTAssertThrowsError(try emitter.emit()) { error in
            guard case EmitError.accessibilityNotTrusted = error else {
                return XCTFail("wrong error: \(error)")
            }
            let e = error as! EmitError
            XCTAssertTrue(e.description.contains("Accessibility"))
            XCTAssertTrue(e.recoverySuggestion?.contains("System Settings") == true)
        }
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(emitter.stats.failureCount, 1)
        XCTAssertNotNil(emitter.stats.lastErrorText)
        XCTAssertTrue(emitter.stats.lastErrorText?.contains("System Settings") == true)
    }

    func testPreflightSurfacesPermissionBeforeAnyTap() {
        let emitter = makeEmitter(poster: RecordingPoster(), trusted: false)
        XCTAssertThrowsError(try emitter.preflight())

        let ok = makeEmitter(poster: RecordingPoster(), trusted: true)
        XCTAssertNoThrow(try ok.preflight())
    }

    func testStatsDriveTheFiredNSecondsAgoReadout() throws {
        let emitter = makeEmitter(poster: RecordingPoster())
        XCTAssertNil(emitter.stats.secondsSinceLastEmit())
        XCTAssertEqual(emitter.stats.emitCount, 0)

        let before = EmitClock.nowNanos()
        try emitter.emit()
        let after = EmitClock.nowNanos()

        let stats = emitter.stats
        XCTAssertEqual(stats.emitCount, 1)
        XCTAssertEqual(stats.lastEmitted, emitter.hotkey)
        let mach = try XCTUnwrap(stats.lastEmitMachNs)
        XCTAssertGreaterThanOrEqual(mach, before)
        XCTAssertLessThanOrEqual(mach, after)

        let age = try XCTUnwrap(stats.secondsSinceLastEmit())
        XCTAssertGreaterThanOrEqual(age, 0)
        XCTAssertLessThan(age, 5)

        emitter.resetStats()
        XCTAssertEqual(emitter.stats.emitCount, 0)
        XCTAssertNil(emitter.stats.lastEmitDate)
    }

    func testOnEmitHookFiresForSuccessAndFailure() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster)
        let box = StatsBox()
        emitter.onEmit = { box.record($0) }

        try emitter.emit()
        XCTAssertEqual(box.snapshots.count, 1)
        XCTAssertEqual(box.snapshots.last?.emitCount, 1)

        poster.failMode = .onPost(.down)
        XCTAssertThrowsError(try emitter.emit())
        XCTAssertEqual(box.snapshots.count, 2)
        XCTAssertEqual(box.snapshots.last?.failureCount, 1)
    }

    func testKeyDownHoldSitsBetweenTheTwoEvents() throws {
        let poster = RecordingPoster()
        let emitter = makeEmitter(poster: poster, hold: 20_000_000)

        let t0 = EmitClock.nowNanos()
        try emitter.emit()
        let elapsed = EmitClock.nowNanos() - t0

        XCTAssertEqual(poster.events.map(\.phase), [.down, .up])
        XCTAssertGreaterThanOrEqual(elapsed, 15_000_000, "the key should be held, not flicked")
        XCTAssertLessThan(elapsed, 250_000_000, "the hold must not eat the latency budget")
    }
}

/// Sendable box so the `onEmit` closure can record without a data race.
private final class StatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [EmitStats] = []
    var snapshots: [EmitStats] {
        lock.lock(); defer { lock.unlock() }
        return _snapshots
    }
    func record(_ s: EmitStats) {
        lock.lock(); _snapshots.append(s); lock.unlock()
    }
}

// MARK: - Live event-tap proof

/// Collector shared with the CGEventTap C callback.
private final class TapCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)] = []

    func append(_ type: CGEventType, _ event: CGEvent) {
        lock.lock()
        events.append((type, event.getIntegerValueField(.keyboardEventKeycode), event.flags))
        lock.unlock()
    }

    var snapshot: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// A listen-only CGEventTap at the HID location that records only the events
/// Tunk posted (matched by `eventSourceUserData`), so the operator typing during
/// the test run cannot pollute the result.
private final class EventTapProbe {
    let collector = TapCollector()
    private let tap: CFMachPort
    private let source: CFRunLoopSource

    init?() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.eventSourceUserData) == CGEventPoster.userDataTag {
                Unmanaged<TapCollector>.fromOpaque(refcon).takeUnretainedValue().append(type, event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(collector).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else { return nil }

        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Let the tap drain. The tap callback runs on this run loop.
    func settle(_ seconds: CFTimeInterval = 0.4) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }

    func phases(forKeyCode code: Int64) -> [CGEventType] {
        collector.snapshot.filter { $0.keyCode == code }.map(\.type)
    }

    func stop() {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
}

final class HotkeyEmitterLiveTapTests: XCTestCase {

    /// F16: absent from this machine's keyboard, and measured not to reach
    /// Carbon hot key listeners when synthesised, so running these tests cannot
    /// type anything or trip anyone's shortcut. That same measurement is why
    /// F13–F20 must never be offered as a Tunk default.
    private let probeKey: UInt16 = 106

    private func makeProbe() throws -> EventTapProbe {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("""
                          Accessibility is not granted to the xctest host, so CGEventPost is a \
                          silent no-op and CGEventTap cannot be created. Balance is then proven \
                          only at the API level, by HotkeyEmitterBalanceTests. Grant \
                          Accessibility to the process running swift test to get the real proof.
                          """)
        }
        guard let probe = EventTapProbe() else {
            throw XCTSkip("CGEvent.tapCreate returned nil despite AXIsProcessTrusted; cannot observe.")
        }
        return probe
    }

    /// The real proof: post through CoreGraphics, watch the HID tap, assert the
    /// observed sequence is exactly down then up with matching flags, and that
    /// no modifier is left asserted in the session afterwards.
    func testPostedPairIsBalancedAndLeavesNoModifierAsserted() throws {
        let probe = try makeProbe()
        defer { probe.stop() }

        let spec = HotkeySpec(keyCode: probeKey, modifiers: [.control, .option, .shift, .command])
        let emitter = HotkeyEmitter(hotkey: spec)
        try emitter.emit()
        probe.settle()

        let seen = probe.collector.snapshot.filter { $0.keyCode == Int64(probeKey) }
        XCTAssertEqual(seen.map(\.type), [.keyDown, .keyUp], "observed sequence must be down then up")
        XCTAssertEqual(seen.first?.flags.rawValue, seen.last?.flags.rawValue,
                       "the up must carry the same modifiers as the down")

        // Compare modifier bits only. The WindowServer stamps a private bit
        // (0x2000_0000, measured on macOS 26.5.2) onto events it has processed,
        // so an exact rawValue comparison against what we posted would fail.
        let observed = CGEventFlags(rawValue: (seen.first?.flags.rawValue ?? 0) & Self.modifierBitMask)
        XCTAssertEqual(observed.rawValue,
                       spec.eventFlags(includeDeviceSide: true).rawValue & Self.modifierBitMask)

        // Nothing left held. The combined session state momentarily reports our
        // flags while the WindowServer is still chewing on the pair (measured:
        // asserted at t+0, clear by t+50 ms), so poll rather than sample once.
        let residual = try waitForModifiersToClear(deadline: 2.0)
        XCTAssertEqual(residual, 0,
                       "modifiers still asserted 2 s after emit: 0x\(String(residual, radix: 16)) "
                       + "(a real stuck modifier, unless you are holding keys while the tests run)")
        XCTAssertFalse(emitter.stats.hasStuckKey)
    }

    /// Device-independent modifier bits plus the left/right device bits. Masks
    /// off everything the WindowServer adds on its own.
    private static let modifierBitMask: UInt64 = 0x00FF_00FF

    /// Polls `flagsState` until every modifier is clear. Returns the residual
    /// modifier bits, 0 on success.
    private func waitForModifiersToClear(deadline seconds: CFTimeInterval) throws -> UInt64 {
        let interesting: UInt64 = CGEventFlags.maskControl.rawValue
                                | CGEventFlags.maskAlternate.rawValue
                                | CGEventFlags.maskShift.rawValue
                                | CGEventFlags.maskCommand.rawValue
                                | CGEventFlags.maskSecondaryFn.rawValue
        let end = Date().addingTimeInterval(seconds)
        var residual: UInt64 = 0
        repeat {
            // Never query .privateState here: it deadlocks inside SkyLight
            // (CGSEventSourceShutdown re-locks its own mutex) on macOS 26.5.2.
            residual = CGEventSource.flagsState(.combinedSessionState).rawValue & interesting
            if residual == 0 { return 0 }
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        } while Date() < end
        return residual
    }

    /// Control for the test above. If the tap could not see an imbalance, the
    /// balance assertion would prove nothing. So: post a bare key-down, confirm
    /// the tap reports exactly one down and no up, then close it out.
    func testTapWouldCatchAnUnbalancedPair() throws {
        let probe = try makeProbe()
        defer { probe.stop() }

        let poster = CGEventPoster()
        let down = EmittedKeyEvent(phase: .down, keyCode: probeKey, flagsRaw: 0)
        let up = EmittedKeyEvent(phase: .up, keyCode: probeKey, flagsRaw: 0)
        // Safety net: this test is the one place that deliberately posts an
        // unmatched down, so it gets a belt-and-braces up on every exit path.
        defer { try? poster.post(up) }

        try poster.post(down)
        probe.settle(0.3)
        XCTAssertEqual(probe.phases(forKeyCode: Int64(probeKey)), [.keyDown],
                       "the tap must be able to see a lone key-down, or the balance test is vacuous")

        try poster.post(up)
        probe.settle(0.3)
        XCTAssertEqual(probe.phases(forKeyCode: Int64(probeKey)), [.keyDown, .keyUp])
    }
}
