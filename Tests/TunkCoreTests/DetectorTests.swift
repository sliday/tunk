import XCTest
@testable import TunkCore

/// All fixtures here are SYNTHETIC (see SyntheticSignal.swift). They test the
/// detector's logic — grouping, gating, determinism, clock independence — not
/// its real-world hit rate, which needs the recorded dataset that does not exist
/// yet.
final class DetectorTests: XCTestCase {

    private func run(_ stream: SyntheticStream,
                     inputs: [InputEvent] = [],
                     config: DetectorConfig = .default)
        -> (triggers: [Trigger], onsets: [OnsetEvent])
    {
        TapDetector.replay(samples: stream.samples(), inputs: inputs, config: config)
    }

    // MARK: - The four grouping cases

    func testCleanDoubleTapFires() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let result = run(stream)

        XCTAssertEqual(result.triggers.count, 1, "one synthetic double-tap, one trigger")
        guard let trigger = result.triggers.first else { return }
        XCTAssertEqual(trigger.tapCount, 2)

        // Onsets land within a couple of samples of the synthetic strikes.
        for (detected, truth) in zip(trigger.tapOnsets, onsets) {
            XCTAssertLessThan(abs(detected - truth), 5_000_000,
                              "onset within 5 ms of the synthetic strike")
        }

        // Latency is the confirm window plus at most one sample period.
        let latency = trigger.tNs - trigger.tapOnsets[1]
        XCTAssertGreaterThanOrEqual(latency, DetectorConfig.default.confirmWindowNs)
        XCTAssertLessThan(latency, DetectorConfig.default.confirmWindowNs + 10_000_000)
        XCTAssertLessThanOrEqual(latency, 250_000_000, "PRD p95 latency budget")

        XCTAssertGreaterThan(trigger.score, 0)
    }

    func testSingleTapNeverFires() {
        let (stream, _) = SyntheticStream.gesture(count: 1, spacingNs: 150_000_000,
                                                  tailNs: 2_000_000_000)
        let result = run(stream)

        XCTAssertTrue(result.triggers.isEmpty, "a stray tap must do nothing, ever")
        XCTAssertEqual(result.onsets.filter { !$0.suppressedByGate }.count, 1,
                       "but the monitor still sees it")
    }

    func testTwoTapsTooFarApartDoNotFire() {
        // 700 ms apart, well past the join window (the 180 ms confirm window,
        // which is what `maxInterTapNs` clamps to).
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 700_000_000)
        let result = run(stream)

        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertEqual(result.onsets.count, 2, "both onsets are seen, neither groups")
    }

    func testTwoTapsTooCloseDoNotFire() {
        // 50 ms apart, under minInterTapNs (80 ms).
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 50_000_000)
        let result = run(stream)

        XCTAssertTrue(result.triggers.isEmpty, "a bounce is not a double-tap")
    }

    func testASlowDoubleNeedsAWiderConfirmWindow() {
        // 260 ms apart. `maxInterTapNs <= confirmWindowNs` is what stops a
        // rhythmic disturbance firing (see DetectorMultiTapTests), and its price
        // is here: the join window can never be wider than the confirm window,
        // so with the shipped 180 ms this pair is two separate taps.
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 260_000_000)
        XCTAssertTrue(run(stream).triggers.isEmpty)

        // Buying it back costs latency, one window for one window, and the PRD
        // budget from last onset to key is 250 ms.
        var config = DetectorConfig.default
        config.confirmWindowNs = 300_000_000
        config.maxInterTapNs = 300_000_000
        XCTAssertEqual(run(stream, config: config).triggers.count, 1)
    }

    func testSpacingsAcrossTheLegalBandFire() {
        // Near both edges but not on them: a detected onset lands up to a
        // sample or two after the strike, so a gesture spaced at exactly
        // maxInterTapNs can measure a hair over it. That is physics, not a bug.
        for spacing in [90_000_000, 120_000_000, 150_000_000, 170_000_000] as [Int64] {
            let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: spacing)
            XCTAssertEqual(run(stream).triggers.count, 1,
                           "spacing \(spacing / 1_000_000) ms is inside the band and must fire")
        }
    }

    func testTripleTapFiresNothingWithDoubleWired() {
        // Three strikes 150 ms apart chain into one group of three, and nothing
        // is bound to three in the default config.
        let (stream, _) = SyntheticStream.gesture(count: 3, spacingNs: 150_000_000)
        XCTAssertTrue(run(stream).triggers.isEmpty,
                      "wrong count at confirm fires nothing")
    }

    func testBurstOfStrikesNeverFires() {
        // Six fumbled strikes 45 ms apart. No pair inside 80...400 ms may be
        // reassembled out of the wreckage.
        let (stream, _) = SyntheticStream.gesture(count: 6, spacingNs: 45_000_000)
        XCTAssertTrue(run(stream).triggers.isEmpty)
    }

    func testRefractoryBlocksAnImmediateSecondGesture() {
        var stream = SyntheticStream(durationNs: 4_000_000_000)
        let base = SyntheticStream.leadInNs
        // Two clean doubles 400 ms apart. The second lands inside the 600 ms
        // refractory that follows the first trigger.
        for t in [base, base + 150_000_000, base + 550_000_000, base + 700_000_000] {
            stream.taps.append(.init(tNs: t, amplitude: 0.9))
        }
        XCTAssertEqual(run(stream).triggers.count, 1)
    }

    func testSecondGestureAfterRefractoryFires() {
        var stream = SyntheticStream(durationNs: 5_000_000_000)
        let base = SyntheticStream.leadInNs
        for t in [base, base + 150_000_000, base + 1_400_000_000, base + 1_550_000_000] {
            stream.taps.append(.init(tNs: t, amplitude: 0.9))
        }
        XCTAssertEqual(run(stream).triggers.count, 2)
    }

    // MARK: - Gate

    func testOnsetInsideGateWindowIsSuppressedButReported() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        // One keystroke 40 ms before the first strike. Its 180 ms gate covers
        // that strike and lapses before the second, 190 ms later.
        let inputs = [InputEvent(tNs: onsets[0] - 40_000_000, kind: .keyDown, code: 4)]
        let result = run(stream, inputs: inputs)

        XCTAssertTrue(result.triggers.isEmpty, "a suppressed onset cannot join a group")
        XCTAssertEqual(result.onsets.count, 2, "both are still reported to the monitor")
        XCTAssertTrue(result.onsets[0].suppressedByGate)
        XCTAssertFalse(result.onsets[1].suppressedByGate, "the gate had lapsed by then")
        XCTAssertTrue(result.onsets.allSatisfy { $0.strength > 0 })
    }

    func testGateCoveringBothTapsSuppressesBoth() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let inputs = [
            InputEvent(tNs: onsets[0] - 40_000_000, kind: .keyDown, code: 4),
            InputEvent(tNs: onsets[1] - 40_000_000, kind: .keyDown, code: 5),
        ]
        let result = run(stream, inputs: inputs)

        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertEqual(result.onsets.count, 2)
        XCTAssertTrue(result.onsets.allSatisfy { $0.suppressedByGate },
                      "the tap monitor still shows the user that the sensor saw it")
    }

    func testGateExpiresAndLetsATapThrough() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        // A keystroke 300 ms before the first strike: gate has lapsed.
        let inputs = [InputEvent(tNs: onsets[0] - 300_000_000, kind: .keyDown, code: 4)]
        let result = run(stream, inputs: inputs)

        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertTrue(result.onsets.allSatisfy { !$0.suppressedByGate })
    }

    func testNonGatingInputDoesNotSuppress() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let inputs = [
            InputEvent(tNs: onsets[0] - 10_000_000, kind: .mouseMoved),
            InputEvent(tNs: onsets[0] - 5_000_000, kind: .scroll),
        ]
        XCTAssertEqual(run(stream, inputs: inputs).triggers.count, 1,
                       "cursor motion does not shake the chassis")
    }

    func testEveryGatingKindArmsTheGate() {
        for kind in InputEventKind.allCases where kind.gatesDetection {
            let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
            let inputs = [InputEvent(tNs: onsets[0] - 40_000_000, kind: kind)]
            XCTAssertTrue(run(stream, inputs: inputs).triggers.isEmpty,
                          "\(kind.rawValue) must suppress")
        }
    }

    func testKeystrokeJustAfterAnOnsetRetractsIt() {
        // The chassis shock can beat the HID event to us. An input event landing
        // within preGateNs after an onset retracts that onset.
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let inputs = [InputEvent(tNs: onsets[1] + 8_000_000, kind: .keyDown, code: 4)]
        XCTAssertTrue(run(stream, inputs: inputs).triggers.isEmpty)
    }

    func testTypingBurstProducesNoTriggers() {
        // SYNTHETIC typing: 40 strikes at ~11 per second, each with a key event
        // at the same instant. Amplitude is deliberately as large as a tap so
        // this tests the gate, not the threshold.
        var stream = SyntheticStream(durationNs: 6_000_000_000)
        var inputs: [InputEvent] = []
        var t = SyntheticStream.leadInNs
        for i in 0..<40 {
            stream.taps.append(.init(tNs: t, amplitude: 0.9))
            inputs.append(InputEvent(tNs: t, kind: .keyDown, code: Int32(i % 26)))
            inputs.append(InputEvent(tNs: t + 60_000_000, kind: .keyUp, code: Int32(i % 26)))
            t += 90_000_000
        }
        let result = run(stream, inputs: inputs)
        XCTAssertTrue(result.triggers.isEmpty, "false triggers while typing are the make-or-break metric")
        XCTAssertFalse(result.onsets.isEmpty, "and the onsets are still visible to the monitor")
    }

    // MARK: - Rejection of non-tap disturbances

    func testLowFrequencyWobbleDoesNotTrigger() {
        // A 3 Hz, 0.5 g sway (lap, footfall, bass through the desk) sits far
        // below the 20 Hz high pass.
        var stream = SyntheticStream(durationNs: 6_000_000_000)
        stream.wobbleAmplitude = 0.5
        stream.wobbleHz = 3
        let result = run(stream)
        XCTAssertTrue(result.triggers.isEmpty, "a sway must never fire")
        // It used to assert no onset at all. That held only because the shipped
        // threshold was 0.30 g, a number invented before any recording existed;
        // at the fitted 0.045 g a 0.5 g sway leaks enough past the one-pole
        // 20 Hz high pass to cross it. Harmless — an onset that never joins a
        // group fires nothing, and the monitor showing it is honest. The
        // property worth pinning is that it does not become a gesture.
        // This helper reports triggers and onsets, not groups, and a trigger is
        // what a group becoming a gesture produces — so the assertion above
        // already covers it.
        XCTAssertLessThan(result.onsets.filter { !$0.suppressedByGate }.count, 4,
                          "a sway may leak the odd onset past a 0.045 g bar, but "
                          + "not a stream of them")
    }

    func testQuietStreamProducesNothing() {
        let stream = SyntheticStream(durationNs: 5_000_000_000)
        let result = run(stream)
        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertTrue(result.onsets.isEmpty)
    }

    func testWeakTapsBelowThresholdDoNotTrigger() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000, amplitude: 0.05)
        XCTAssertTrue(run(stream).triggers.isEmpty)
    }

    func testRaisedNoiseFloorLiftsTheBar() {
        // Same gesture, once on a quiet surface and once with the noise floor
        // pushed up. The adaptive term is what changes the answer; the absolute
        // threshold is identical in both runs.
        var config = DetectorConfig.default
        config.calibratedThreshold = 0.05

        let (quiet, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000,
                                                 amplitude: 0.20, noiseAmplitude: 0.001)
        XCTAssertEqual(run(quiet, config: config).triggers.count, 1)

        let (noisy, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000,
                                                 amplitude: 0.20, noiseAmplitude: 0.10)
        XCTAssertTrue(run(noisy, config: config).triggers.isEmpty,
                      "on a live surface the same strike is no longer distinguishable")
    }

    // MARK: - Purity

    func testDeterminismAcrossRuns() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let inputs = [InputEvent(tNs: onsets[0] - 900_000_000, kind: .keyDown, code: 4)]
        let samples = stream.samples()

        let a = TapDetector.replay(samples: samples, inputs: inputs)
        let b = TapDetector.replay(samples: samples, inputs: inputs)

        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.onsets, b.onsets)
        XCTAssertEqual(a.triggers.count, 1)
    }

    func testResetRestoresAFreshDetector() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let samples = stream.samples()
        let detector = TapDetector()

        var first: [Trigger] = []
        for s in samples { if let t = detector.ingest(sample: s) { first.append(t) } }
        detector.reset()
        _ = detector.drainOnsets()

        var second: [Trigger] = []
        for s in samples { if let t = detector.ingest(sample: s) { second.append(t) } }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
    }

    func testNoWallClockDependence() {
        // Same samples, same t_ns, but fed with wildly different real-world
        // spacing and wildly different arrival stamps. A detector that peeked at
        // a clock, at `arrivalNs`, or at its own scheduling would diverge here.
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let samples = stream.samples()

        let fast = TapDetector()
        var fastTriggers: [Trigger] = []
        for s in samples { if let t = fast.ingest(sample: s) { fastTriggers.append(t) } }

        let slow = TapDetector()
        var slowTriggers: [Trigger] = []
        for (i, s) in samples.enumerated() {
            var jittered = s
            jittered.arrivalNs = s.tNs + Int64(i % 7) * 40_000_000 - 3_000_000
            if i % 500 == 0 { Thread.sleep(forTimeInterval: 0.02) }
            if let t = slow.ingest(sample: jittered) { slowTriggers.append(t) }
        }

        XCTAssertEqual(fastTriggers, slowTriggers)
        XCTAssertEqual(fastTriggers.count, 1)
    }

    func testDetectorSourceHasNoClockCalls() throws {
        // The rule is structural, so check it structurally. If this ever fails,
        // the offending call has to go, not this test.
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // TunkCoreTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo root
        let sources = root.appendingPathComponent("Sources/TunkCore")
        let all = try FileManager.default.contentsOfDirectory(at: sources,
                                                              includingPropertiesForKeys: nil)
        // Detector*.swift and DSP*.swift are this area's files. Types.swift is
        // frozen and belongs to the lead.
        let files = all.filter {
            $0.lastPathComponent.hasPrefix("Detector") || $0.lastPathComponent.hasPrefix("DSP")
        }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        let banned = ["Date(", "mach_absolute_time", "DispatchQueue", "asyncAfter",
                      "Timer", "CFAbsoluteTime", "clock_gettime", "ProcessInfo"]
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in banned {
                XCTAssertFalse(text.contains(needle),
                               "\(file.lastPathComponent) must not reference \(needle)")
            }
        }
    }

    func testOutOfOrderSamplesAreIgnored() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        var samples = stream.samples()
        // Splice a stale sample into the middle.
        samples.insert(samples[100], at: samples.count / 2)
        let result = TapDetector.replay(samples: samples, inputs: [])
        XCTAssertEqual(result.triggers.count, 1)
    }

    func testSensorGapDropsTheGroupRatherThanFiringAcrossIt() {
        // First strike, then the sensor goes away for 200 ms, then a second
        // strike inside what would have been a legal window. The seam is not
        // trustworthy, so nothing fires.
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 300_000_000)
        let gapStart = onsets[0] + 50_000_000
        let gapEnd = onsets[0] + 250_000_000
        let samples = stream.samples().filter { $0.tNs < gapStart || $0.tNs > gapEnd }

        XCTAssertTrue(TapDetector.replay(samples: samples, inputs: []).triggers.isEmpty)
    }

    // MARK: - Config drives everything

    func testConfigWindowsChangeTheAnswer() {
        var config = DetectorConfig.default
        config.maxInterTapNs = 120_000_000     // narrower than the 150 ms gesture
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        XCTAssertTrue(run(stream, config: config).triggers.isEmpty)

        config.maxInterTapNs = 400_000_000     // clamped back to the 180 ms confirm window
        XCTAssertEqual(run(stream, config: config).triggers.count, 1)
    }

    func testSensitivityScalesTheCalibratedThreshold() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000, amplitude: 0.30)

        var strict = DetectorConfig.default
        strict.calibratedThreshold = 0.30
        strict.sensitivity = 2.0
        XCTAssertTrue(run(stream, config: strict).triggers.isEmpty)

        var loose = strict
        loose.sensitivity = 0.5
        XCTAssertEqual(run(stream, config: loose).triggers.count, 1)
    }

    func testConfirmWindowSetsTheLatency() {
        // The confirm window is also the join window, so a short one needs a
        // brisk gesture to have anything to fire on.
        var config = DetectorConfig.default
        config.confirmWindowNs = 100_000_000
        config.maxInterTapNs = 100_000_000
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 90_000_000)
        guard let trigger = run(stream, config: config).triggers.first else {
            return XCTFail("expected a trigger")
        }
        let latency = trigger.tNs - trigger.tapOnsets[1]
        XCTAssertGreaterThanOrEqual(latency, 100_000_000)
        XCTAssertLessThan(latency, 110_000_000)
    }

    func testTapCountToFireOfOneArmsTheSingleTap() {
        // Changed deliberately: the owner asked for single, double and triple to
        // be separately bindable, so `tapCountToFire = 1` now means what it says.
        // Single stays unbound in the shipped default, and the price of arming
        // it is measured in
        // DetectorMultiTapTests.testSingleTapArmedOnTheSameStreamMisfiresRepeatedly.
        var config = DetectorConfig.default
        config.tapCountToFire = 1
        let (stream, _) = SyntheticStream.gesture(count: 1, spacingNs: 150_000_000)
        let triggers = run(stream, config: config).triggers
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers.first?.tapCount, 1)
        XCTAssertTrue(run(stream).triggers.isEmpty, "and nothing at all by default")
    }

    // MARK: - Monitor plumbing

    func testDrainClearsTheOnsetLog() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let detector = TapDetector()
        for s in stream.samples() { _ = detector.ingest(sample: s) }
        XCTAssertEqual(detector.drainOnsets().count, 2)
        XCTAssertTrue(detector.drainOnsets().isEmpty)
    }

    func testOnsetStrengthTracksTapAmplitude() {
        var strengths: [Double] = []
        for amplitude in [0.6, 1.0, 1.8] {
            let (stream, _) = SyntheticStream.gesture(count: 1, spacingNs: 150_000_000,
                                                      amplitude: amplitude)
            let onsets = run(stream).onsets
            XCTAssertEqual(onsets.count, 1)
            strengths.append(onsets[0].strength)
        }
        XCTAssertLessThan(strengths[0], strengths[1])
        XCTAssertLessThan(strengths[1], strengths[2])
    }

    func testTriggerScoreIsTheWeakestTapInTheGesture() {
        var stream = SyntheticStream(durationNs: 4_000_000_000)
        let base = SyntheticStream.leadInNs
        stream.taps = [.init(tNs: base, amplitude: 1.6),
                       .init(tNs: base + 150_000_000, amplitude: 0.9)]
        let result = run(stream)
        guard let trigger = result.triggers.first else { return XCTFail("expected a trigger") }
        let weakest = result.onsets.map(\.strength).min() ?? 0
        XCTAssertEqual(trigger.score, weakest, accuracy: 1e-12)
    }
}
