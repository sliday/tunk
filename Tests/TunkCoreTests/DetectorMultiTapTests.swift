import XCTest
@testable import TunkCore

/// Multi-tap grouping: the trigger-storm bug, and single / double / triple as
/// separately bindable gestures.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). There is still
/// no recorded dataset. These prove the state machine's logic — what chains,
/// what fires, what refuses to — not any real-world rate. The thump streams in
/// particular are an idealised, perfectly periodic stand-in for bass through a
/// desk or footfall on a timber floor; a real one is neither that regular nor
/// that clean.
final class DetectorMultiTapTests: XCTestCase {

    private static let single: Set<Int> = [1]
    private static let double: Set<Int> = [2]
    private static let doubleAndTriple: Set<Int> = [2, 3]
    private static let allCounts: Set<Int> = [1, 2, 3]

    private func run(_ stream: SyntheticStream,
                     inputs: [InputEvent] = [],
                     config: DetectorConfig = .default,
                     armed: Set<Int>? = nil)
        -> (triggers: [Trigger], onsets: [OnsetEvent], groups: [TapGroupEvent])
    {
        TapDetector.replayGroups(samples: stream.samples(), inputs: inputs,
                                 config: config, armedTapCounts: armed)
    }

    /// SYNTHETIC periodic disturbance: a 0.5 g thump every `spacingNs` for
    /// `durationNs`, on a quiet machine, with no input events to gate it.
    ///
    /// This fixture is known to reproduce the bug it tests for. Replayed
    /// through the pre-fix detector (git e234f0f, `maxInterTapNs` 400 ms against
    /// a 180 ms confirm window) it produced 48 triggers at 250 ms spacing and 60
    /// at 200 ms — the critic's numbers to the trigger.
    private func thumpStream(spacingNs: Int64,
                             durationNs: Int64,
                             amplitude: Double = 0.5) -> (stream: SyntheticStream, count: Int) {
        let count = Int(durationNs / spacingNs)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + durationNs + 1_000_000_000)
        for i in 0..<count {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * spacingNs,
                                     amplitude: amplitude))
        }
        return (stream, count)
    }

    // MARK: - The trigger storm

    func testPeriodicThumpsAt250msFireNothing() {
        let (stream, count) = thumpStream(spacingNs: 250_000_000, durationNs: 60_000_000_000)
        XCTAssertEqual(count, 240)
        let result = run(stream, armed: Self.double)

        XCTAssertEqual(result.triggers.count, 0,
                       "60 s of thumps at double-tap cadence must fire nothing; this measured 48")
        XCTAssertEqual(result.onsets.count, count,
                       "every thump is still seen — the fix is in the grouping, not the threshold")
    }

    func testPeriodicThumpsAt200msFireNothing() {
        let (stream, count) = thumpStream(spacingNs: 200_000_000, durationNs: 60_000_000_000)
        XCTAssertEqual(count, 300)
        let result = run(stream, armed: Self.double)

        XCTAssertEqual(result.triggers.count, 0, "this measured 60")
        XCTAssertEqual(result.onsets.count, count)
    }

    func testPeriodicThumpsInsideTheChainWindowBecomeOneLongGroup() {
        // 150 ms is a legal inter-tap spacing, so these do chain. The group grows
        // past any bindable count and dies unfired, which is the mechanism that
        // makes the two tests above come out at zero.
        let (stream, count) = thumpStream(spacingNs: 150_000_000, durationNs: 30_000_000_000)
        let result = run(stream, armed: Self.allCounts)

        XCTAssertEqual(result.triggers.count, 0,
                       "a stream of knocks is not a gesture, at any count")
        XCTAssertEqual(result.groups.count, 1, "they all chained into one group")
        XCTAssertEqual(result.groups.first?.tapCount, count)
        XCTAssertEqual(result.groups.first?.fired, false)
    }

    func testPeriodicThumpsWithNothingArmedStillReachTheMonitor() {
        let (stream, count) = thumpStream(spacingNs: 250_000_000, durationNs: 10_000_000_000)
        let result = run(stream, armed: [])

        XCTAssertEqual(result.triggers.count, 0)
        XCTAssertEqual(result.onsets.count, count)
        XCTAssertEqual(result.groups.count, count, "each thump closed its own group")
        XCTAssertTrue(result.groups.allSatisfy { $0.tapCount == 1 && !$0.fired })
    }

    /// The owner asked for single tap; this is the price, stated in a number
    /// rather than a warning. Same SYNTHETIC 60 s stream, same detector, single
    /// armed instead of double.
    func testSingleTapArmedOnTheSameStreamMisfiresRepeatedly() {
        let (stream, _) = thumpStream(spacingNs: 250_000_000, durationNs: 60_000_000_000)
        let withDouble = run(stream, armed: Self.double).triggers.count
        let withSingle = run(stream, armed: Self.single).triggers.count

        XCTAssertEqual(withDouble, 0)
        // 60 in 60 s: one thump fires, its 600 ms refractory swallows the next
        // two, the fourth fires. Exactly one per second.
        XCTAssertEqual(withSingle, 60,
                       "single tap fires once per refractory period on a rhythmic disturbance")
        XCTAssertTrue(run(stream, armed: Self.single).triggers.allSatisfy { $0.tapCount == 1 })
    }

    // MARK: - The invariant

    func testIncoherentConfigIsClampedRatherThanRun() {
        var config = DetectorConfig.default
        config.maxInterTapNs = 400_000_000      // longer than the 180 ms confirm window
        config.confirmWindowNs = 180_000_000

        let issues = config.coherenceIssues
        XCTAssertFalse(config.isCoherent)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.field, "maxInterTapNs")
        XCTAssertEqual(config.madeCoherent().maxInterTapNs, 180_000_000)
        XCTAssertTrue(config.madeCoherent().isCoherent, "clamping is idempotent")

        let detector = TapDetector(config: config)
        XCTAssertEqual(detector.effectiveConfig.maxInterTapNs, 180_000_000)
        XCTAssertEqual(detector.config.maxInterTapNs, 400_000_000, "what the user typed is kept")
    }

    func testTheOldIncoherentConfigCannotStormAnyMore() {
        // The literal failing configuration, handed straight to the detector.
        var config = DetectorConfig.default
        config.maxInterTapNs = 400_000_000
        config.confirmWindowNs = 180_000_000

        for spacing in [200_000_000, 250_000_000] as [Int64] {
            let (stream, _) = thumpStream(spacingNs: spacing, durationNs: 60_000_000_000)
            XCTAssertEqual(run(stream, config: config, armed: Self.double).triggers.count, 0,
                           "\(spacing / 1_000_000) ms spacing")
        }
    }

    /// The storm sweep at the SHIPPED window, not the one it was found at.
    ///
    /// `testTheOldIncoherentConfigCannotStormAnyMore` pins `confirmWindowNs` at
    /// 180 ms, which is what shipped when the storm was found. It is 220 ms now,
    /// and notes/OPEN_ITEMS has carried "the 0-triggers result does not carry
    /// automatically" ever since. This is that result, measured.
    ///
    /// A periodic thump train is the easy case: with `maxInterTapNs ==
    /// confirmWindowNs`, every thump inside the window chains into one
    /// over-long group, which reaches its confirm deadline with a count nothing
    /// is armed for and fires nothing. Spacings are swept either side of the
    /// window so the chaining boundary itself is covered.
    func testAPeriodicTrainCannotStormAtTheShippedWindow() {
        let config = DetectorConfig.default
        XCTAssertEqual(config.confirmWindowNs, 220_000_000, "this test is about the shipped window")

        for spacingMs in [120, 160, 200, 210, 220, 230, 260, 300, 400] {
            let spacing = Int64(spacingMs) * 1_000_000
            let (stream, _) = thumpStream(spacingNs: spacing, durationNs: 60_000_000_000)
            let fired = run(stream, config: config, armed: Self.double).triggers.count
            XCTAssertEqual(fired, 0, "\(spacingMs) ms periodic train fired \(fired) times "
                           + "in 60 s at the shipped 220 ms window")
        }
    }

    func testConfigCannotBeSetIncoherentlyThroughTheSetter() {
        let detector = TapDetector()
        detector.config.maxInterTapNs = 900_000_000
        XCTAssertEqual(detector.effectiveConfig.maxInterTapNs,
                       DetectorConfig.default.confirmWindowNs)

        detector.config.confirmWindowNs = 300_000_000
        detector.config.maxInterTapNs = 250_000_000
        XCTAssertEqual(detector.effectiveConfig.maxInterTapNs, 250_000_000,
                       "a wider confirm window buys a wider join window")
    }

    func testCoherenceClampsTheOtherWaysToWriteNonsense() {
        let base = DetectorConfig.default.madeCoherent()
        var config = base
        config.minInterTapNs = 500_000_000
        config.maxInterTapNs = 100_000_000
        XCTAssertEqual(config.madeCoherent().minInterTapNs, 100_000_000)

        config = base
        config.gateWindowNs = -5
        config.refractoryNs = 99_000_000_000
        let fixed = config.madeCoherent()
        XCTAssertEqual(fixed.gateWindowNs, 0)
        XCTAssertEqual(fixed.refractoryNs, DetectorConfig.maxWindowNs)
        XCTAssertEqual(config.coherenceIssues.count, 2)

        // An unsupported count is DROPPED, not clamped into range. Clamping
        // used to rewrite the whole armed set through the single-value
        // `tapCountToFire` setter, so {0, 2} became {1}: double disarmed and
        // single armed — the count that fires on every mug and every footfall.
        // Arming a count the user never asked for is worse than arming nothing,
        // and the change is reported in `coherenceIssues` either way.
        config = base
        config.armedTapCounts = [9]
        XCTAssertEqual(config.madeCoherent().armedTapCounts, [])
        XCTAssertTrue(config.coherenceIssues.contains { $0.field == "armedTapCounts" })

        config = base
        config.armedTapCounts = [0]
        XCTAssertEqual(config.madeCoherent().armedTapCounts, [])

        config = base
        config.armedTapCounts = [0, 2, 9]
        XCTAssertEqual(config.madeCoherent().armedTapCounts, [2],
                       "valid counts must survive alongside an invalid one")

        config = base
        config.sensitivity = 0
        XCTAssertEqual(config.madeCoherent().sensitivity, 1.0)
        config.sensitivity = .nan
        XCTAssertEqual(config.madeCoherent().sensitivity, 1.0)
        config = base
        config.calibratedThreshold = -1
        XCTAssertNil(config.madeCoherent().calibratedThreshold)
    }

    func testTheShippedDefaultIsAtWorstOneClampAway() {
        // `DetectorConfig.default` lives in the frozen Types.swift and still
        // says maxInterTapNs = 400 ms against a 180 ms confirm window, so the
        // detector clamps it on the way in. Requested from the lead: write
        // 180_000_000 there, so the stored config and the running one agree.
        // This test passes either way; it only fails if the default drifts into
        // some *other* kind of nonsense.
        let issues = DetectorConfig.default.coherenceIssues
        XCTAssertEqual(issues.map(\.field).filter { $0 != "maxInterTapNs" }, [])
        XCTAssertTrue(DetectorConfig.default.madeCoherent().isCoherent)
        XCTAssertEqual(TapDetector().effectiveConfig.maxInterTapNs,
                       DetectorConfig.default.confirmWindowNs)
    }

    // MARK: - Counts

    func testCleanDoubleFiresOneConfirmWindowAfterItsSecondOnset() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let result = run(stream, armed: Self.doubleAndTriple)

        XCTAssertEqual(result.triggers.count, 1)
        guard let trigger = result.triggers.first else { return }
        XCTAssertEqual(trigger.tapCount, 2)

        let latency = trigger.tNs - trigger.tapOnsets[1]
        XCTAssertGreaterThanOrEqual(latency, DetectorConfig.default.confirmWindowNs)
        XCTAssertLessThan(latency, DetectorConfig.default.confirmWindowNs + 5_000_000,
                          "within one sample period of the confirm window")
    }

    func testCleanTripleFiresAsATripleAndNotAsADouble() {
        let (stream, _) = SyntheticStream.gesture(count: 3, spacingNs: 150_000_000)
        let result = run(stream, armed: Self.doubleAndTriple)

        XCTAssertEqual(result.triggers.count, 1, "one gesture, one trigger")
        XCTAssertEqual(result.triggers.first?.tapCount, 3)
        XCTAssertEqual(result.triggers.first?.tapOnsets.count, 3)

        let latency = (result.triggers.first?.tNs ?? 0) - (result.triggers.first?.tapOnsets.last ?? 0)
        XCTAssertLessThan(latency, DetectorConfig.default.confirmWindowNs + 5_000_000,
                          "latency is measured from the last onset, so triple feels like double")
    }

    func testAddingTripleDoesNotChangeHowDoubleFires() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let doubleOnly = run(stream, armed: Self.double).triggers
        let withTriple = run(stream, armed: Self.doubleAndTriple).triggers

        XCTAssertEqual(doubleOnly, withTriple,
                       "same trigger, same instant, whether or not triple is bound")
        XCTAssertEqual(doubleOnly.count, 1)
    }

    func testTripleWithOnlyDoubleArmedFiresNothing() {
        let (stream, _) = SyntheticStream.gesture(count: 3, spacingNs: 150_000_000)
        let result = run(stream, armed: Self.double)

        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.tapCount, 3, "but the monitor can still show it")
        XCTAssertEqual(result.groups.first?.fired, false)
    }

    func testFourTapsFireNothingEvenWithEveryCountArmed() {
        let (stream, _) = SyntheticStream.gesture(count: 4, spacingNs: 150_000_000)
        let result = run(stream, armed: Self.allCounts)

        XCTAssertTrue(result.triggers.isEmpty, "four is not a gesture we can name")
        XCTAssertEqual(result.groups.first?.tapCount, 4)
        XCTAssertEqual(result.groups.first?.fired, false)
    }

    func testFiveAndSixTapsFireNothing() {
        for count in 5...6 {
            let (stream, _) = SyntheticStream.gesture(count: count, spacingNs: 150_000_000)
            let result = run(stream, armed: Self.allCounts)
            XCTAssertTrue(result.triggers.isEmpty, "\(count) taps")
            XCTAssertEqual(result.groups.first?.tapCount, count,
                           "the count is reported truthfully past the retention limit")
        }
    }

    func testSingleFiresOnlyWhenSingleIsArmed() {
        let (stream, _) = SyntheticStream.gesture(count: 1, spacingNs: 150_000_000,
                                                  tailNs: 2_000_000_000)

        XCTAssertTrue(run(stream, armed: Self.double).triggers.isEmpty,
                      "a stray tap does nothing while only double is bound")

        let armed = run(stream, armed: Self.single)
        XCTAssertEqual(armed.triggers.count, 1)
        XCTAssertEqual(armed.triggers.first?.tapCount, 1)
        let latency = (armed.triggers.first?.tNs ?? 0) - (armed.triggers.first?.tapOnsets[0] ?? 0)
        XCTAssertGreaterThanOrEqual(latency, DetectorConfig.default.confirmWindowNs)
    }

    func testSingleArmedDoesNotStealADouble() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let result = run(stream, armed: Self.allCounts)

        XCTAssertEqual(result.triggers.count, 1, "one gesture, not two singles")
        XCTAssertEqual(result.triggers.first?.tapCount, 2)
    }

    func testArmedCountsDefaultToTapCountToFire() {
        let (stream, _) = SyntheticStream.gesture(count: 1, spacingNs: 150_000_000,
                                                  tailNs: 2_000_000_000)
        var config = DetectorConfig.default
        XCTAssertEqual(TapDetector(config: config).effectiveArmedTapCounts, [2])
        XCTAssertTrue(run(stream, config: config).triggers.isEmpty)

        config.tapCountToFire = 1
        XCTAssertEqual(TapDetector(config: config).effectiveArmedTapCounts, [1])
        XCTAssertEqual(run(stream, config: config).triggers.count, 1,
                       "the owner asked for single to be bindable; this is how the frozen "
                       + "DetectorConfig can say so today")
    }

    func testUnsupportedArmedCountsAreIgnored() {
        let detector = TapDetector(armedTapCounts: [0, 2, 4, 7])
        XCTAssertEqual(detector.effectiveArmedTapCounts, [2])

        let (stream, _) = SyntheticStream.gesture(count: 4, spacingNs: 150_000_000)
        XCTAssertTrue(run(stream, armed: [4]).triggers.isEmpty)
    }

    func testGateStillKillsAGestureAtEveryCount() {
        for count in 1...3 {
            let (stream, onsets) = SyntheticStream.gesture(count: count, spacingNs: 150_000_000)
            let inputs = onsets.map { InputEvent(tNs: $0 - 40_000_000, kind: .keyDown, code: 4) }
            let result = run(stream, inputs: inputs, armed: Self.allCounts)
            XCTAssertTrue(result.triggers.isEmpty, "\(count)-tap gesture under the gate")
            XCTAssertEqual(result.onsets.count, count, "still shown to the monitor")
        }
    }

    // MARK: - Purity

    func testIdenticalInputTwiceGivesIdenticalOutput() {
        let (stream, count) = thumpStream(spacingNs: 220_000_000, durationNs: 20_000_000_000)
        let samples = stream.samples()
        let inputs = [InputEvent(tNs: SyntheticStream.leadInNs + 5_000_000_000, kind: .keyDown, code: 7)]

        let a = TapDetector.replayGroups(samples: samples, inputs: inputs,
                                         armedTapCounts: Self.allCounts)
        let b = TapDetector.replayGroups(samples: samples, inputs: inputs,
                                         armedTapCounts: Self.allCounts)

        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.onsets, b.onsets)
        XCTAssertEqual(a.groups, b.groups)
        XCTAssertEqual(a.onsets.count, count)
    }

    func testTripleIsIndependentOfWallClockPacing() {
        // Same samples, same t_ns, fed at wildly different real speeds and with
        // scrambled arrival stamps. Anything reading a clock diverges here.
        let (stream, _) = SyntheticStream.gesture(count: 3, spacingNs: 150_000_000)
        let samples = stream.samples()

        let fast = TapDetector(armedTapCounts: Self.allCounts)
        var fastTriggers: [Trigger] = []
        for s in samples { if let t = fast.ingest(sample: s) { fastTriggers.append(t) } }

        let slow = TapDetector(armedTapCounts: Self.allCounts)
        var slowTriggers: [Trigger] = []
        for (i, s) in samples.enumerated() {
            var jittered = s
            jittered.arrivalNs = s.tNs + Int64(i % 5) * 70_000_000 - 9_000_000
            if i % 400 == 0 { Thread.sleep(forTimeInterval: 0.01) }
            if let t = slow.ingest(sample: jittered) { slowTriggers.append(t) }
        }

        XCTAssertEqual(fastTriggers, slowTriggers)
        XCTAssertEqual(fastTriggers.count, 1)
        XCTAssertEqual(fastTriggers.first?.tapCount, 3)
    }

    func testGroupLogDrainsAndIsCapped() {
        let (stream, count) = thumpStream(spacingNs: 250_000_000, durationNs: 10_000_000_000)
        let detector = TapDetector(armedTapCounts: [])
        for s in stream.samples() { _ = detector.ingest(sample: s) }

        let drained = detector.drainGroups()
        XCTAssertEqual(drained.count, min(count, DSPTuning.default.groupLogCapacity))
        XCTAssertTrue(detector.drainGroups().isEmpty)
    }

    func testResetDropsAnInFlightGroup() {
        var stream = SyntheticStream(durationNs: 3_000_000_000)
        let base = SyntheticStream.leadInNs
        stream.taps = [.init(tNs: base, amplitude: 0.9),
                       .init(tNs: base + 150_000_000, amplitude: 0.9)]
        let samples = stream.samples()
        let detector = TapDetector(armedTapCounts: Self.allCounts)

        var triggers: [Trigger] = []
        for s in samples {
            if s.tNs > base + 160_000_000 && s.tNs < base + 200_000_000 { detector.reset() }
            if let t = detector.ingest(sample: s) { triggers.append(t) }
        }
        XCTAssertTrue(triggers.isEmpty, "the group was dropped mid-confirm")
        XCTAssertTrue(detector.drainGroups().isEmpty)
    }
}
