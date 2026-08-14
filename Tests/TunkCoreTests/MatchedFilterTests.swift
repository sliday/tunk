import XCTest
@testable import TunkCore

/// The ring-projected matched filter front end, and the two knobs in front of it.
///
/// Both knobs ship OFF and, on the measurements in `notes/BAR_ASSESSMENT.md`,
/// both should stay off: neither beat the envelope on `data/raw`. What these
/// tests hold is the part that matters anyway — that OFF is not merely close to
/// the old behaviour but bit-identical to it, that the knobs cannot be written
/// into a meaningless state, and that when they are on they do what their
/// documentation says.
///
/// Signals here are SYNTHETIC.
final class MatchedFilterTests: XCTestCase {

    // MARK: - Off is off

    func testBothKnobsShipOff() {
        XCTAssertEqual(DetectorConfig.default.matchedFilterWeight, 0, accuracy: 0,
                       "the matched-filter blend must ship disabled")
        XCTAssertEqual(DetectorConfig.default.matchedFilterAdmitG, 0, accuracy: 0,
                       "the matched-filter onset path must ship disabled")
    }

    /// With the knobs off the envelope has to equal a chain that never had a
    /// matched filter in it. Not "within a tolerance" — the same Double.
    ///
    /// The reference below is the whole shipped chain rewritten from its
    /// documentation: per-axis 20 Hz one pole, vector magnitude, quadrature pair
    /// with the previous sample, 3-sample sliding max. If the new stage ever
    /// leaks into the default path this diverges on the first tap.
    func testOffReproducesTheEnvelopeBitForBit() {
        let tuning = DSPTuning.default
        var chain = SignalChain(tuning: tuning)
        var hpX = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        var hpY = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        var hpZ = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        var previousSquared = 0.0
        var peak = SlidingMax(length: tuning.envelopePeakSamples)

        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        var compared = 0
        for s in stream.samples() {
            let mine = chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                     holdNoiseFloor: false)
            let ax = hpX.process(Double(s.x))
            let ay = hpY.process(Double(s.y))
            let az = hpZ.process(Double(s.z))
            let squared = ax * ax + ay * ay + az * az
            let pair = (squared + previousSquared).squareRoot()
            previousSquared = squared
            let reference = peak.process(pair)
            XCTAssertEqual(mine.bitPattern, reference.bitPattern,
                           "envelope diverged from the pre-matched-filter chain")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 1000)
    }

    /// The filter is not merely unused when off, it is not evaluated, so the
    /// per-sample cost of the shipped build is unchanged.
    func testTheFilterIsNotEvaluatedWhileOff() {
        var chain = SignalChain(tuning: .default)
        for _ in 0..<200 {
            _ = chain.process(x: 0.3, y: -0.2, z: -0.9, holdNoiseFloor: false)
        }
        XCTAssertFalse(chain.evaluateMatchedFilter)
        XCTAssertEqual(chain.strikeScore, 0, accuracy: 0)
        XCTAssertEqual(chain.envelopeDelaySamples, 0, accuracy: 0)
    }

    /// Same statement one level up: a detector on defaults and a detector told
    /// explicitly to keep both knobs at zero produce the same triggers and the
    /// same onsets, timestamp for timestamp.
    func testDefaultAndExplicitlyOffAgreeOnEveryOnset() {
        var explicitlyOff = DetectorConfig.default
        explicitlyOff.matchedFilterWeight = 0
        explicitlyOff.matchedFilterAdmitG = 0

        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        let samples = stream.samples()
        let a = TapDetector.replay(samples: samples, inputs: [])
        let b = TapDetector.replay(samples: samples, inputs: [], config: explicitlyOff)
        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.onsets, b.onsets)
        XCTAssertEqual(a.triggers.count, 1, "the fixture should fire one double-tap")
    }

    // MARK: - The template itself

    func testTemplateIsUnitNormAndItsDelayIsKnown() {
        let f = MatchedStrikeFilter.default
        let norm = f.taps.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-6,
                       "a correlation against a non-unit template silently rescales the bar")
        XCTAssertEqual(f.taps.count, 20)
        XCTAssertEqual(f.peakIndex, 16)
        XCTAssertEqual(f.delaySamples, 3,
                       "the front end's group delay is what the onset timestamps are corrected by")
    }

    /// The template is the strike shape with the ring shape projected out, so it
    /// must have negative taps. A template that stayed non-negative would be an
    /// energy detector wearing a matched filter's name, and energy is the thing
    /// already measured shut.
    func testTemplateHasBothSigns() {
        let taps = MatchedStrikeFilter.default.taps
        XCTAssertTrue(taps.contains { $0 < -0.1 })
        XCTAssertTrue(taps.contains { $0 > 0.1 })
    }

    /// Negative correlation is "this is not a strike", not "this is a strike
    /// arriving upside down". Reporting its magnitude would make a signal that
    /// looks like a pure ring score as high as one that looks like a strike.
    func testNegativeCorrelationReportsZero() {
        var f = MatchedStrikeFilter.default
        var last = 0.0
        // Drive it with the template inverted: the correlation is as negative as
        // it can get.
        for tap in MatchedStrikeFilter.default.taps { last = f.process(-tap) }
        XCTAssertEqual(last, 0, accuracy: 0)
    }

    // MARK: - Coherence and persistence

    func testAnOutOfRangeWeightIsClamped() {
        var c = DetectorConfig.default
        c.matchedFilterWeight = 4
        XCTAssertEqual(c.madeCoherent().matchedFilterWeight, 1, accuracy: 0)
        XCTAssertFalse(c.isCoherent)
        XCTAssertTrue(c.coherenceIssues.contains { $0.field == "matchedFilterWeight" })

        c.matchedFilterWeight = -0.5
        XCTAssertEqual(c.madeCoherent().matchedFilterWeight, 0, accuracy: 0)

        c.matchedFilterWeight = .nan
        XCTAssertEqual(c.madeCoherent().matchedFilterWeight, 0, accuracy: 0)

        c.matchedFilterWeight = 0.5
        XCTAssertTrue(c.isCoherent)
    }

    func testTheDetectorRunsTheClampedWeightNotTheWrittenOne() {
        var c = DetectorConfig.default
        c.matchedFilterWeight = 9
        let d = TapDetector(config: c)
        XCTAssertEqual(d.effectiveConfig.matchedFilterWeight, 1, accuracy: 0)
    }

    func testBothKnobsSurviveASettingsRoundTrip() throws {
        var c = DetectorConfig.default
        c.matchedFilterWeight = 0.25
        c.matchedFilterAdmitG = 0.07
        let back = try JSONDecoder().decode(DetectorConfig.self,
                                            from: JSONEncoder().encode(c))
        XCTAssertEqual(back.matchedFilterWeight, 0.25, accuracy: 1e-12)
        XCTAssertEqual(back.matchedFilterAdmitG, 0.07, accuracy: 1e-12)
    }

    /// A settings file written before this round existed has neither key. It must
    /// load with the front end off, not fail and not reset the rest.
    func testASettingsFileFromBeforeThisRoundLoadsWithTheFrontEndOff() throws {
        let json = Data(#"{"sensitivity":1,"defaultThreshold":0.032,"tapCountToFire":2}"#.utf8)
        let c = try JSONDecoder().decode(DetectorConfig.self, from: json)
        XCTAssertEqual(c.matchedFilterWeight, 0, accuracy: 0)
        XCTAssertEqual(c.matchedFilterAdmitG, 0, accuracy: 0)
        XCTAssertEqual(c.defaultThreshold, 0.032, accuracy: 1e-12)
    }

    // MARK: - On, it does what it claims

    /// Switching the blend on must not push the trigger later. The filter cannot
    /// respond until the strike is inside its window, so the detector subtracts
    /// that known, constant lag from every onset timestamp — a correction that
    /// points backwards into samples already ingested, never forwards.
    func testTurningTheBlendOnDoesNotSpendLatency() {
        let (stream, onsets) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        let samples = stream.samples()
        var on = DetectorConfig.default
        on.matchedFilterWeight = 1

        let base = TapDetector.replay(samples: samples, inputs: [])
        let mixed = TapDetector.replay(samples: samples, inputs: [], config: on)
        guard let b = base.triggers.first, let m = mixed.triggers.first else {
            return XCTFail("both configurations should fire on this fixture")
        }
        let lastOnset = onsets[1]
        XCTAssertLessThanOrEqual(m.tNs - lastOnset, b.tNs - lastOnset + 2_000_000,
                                 "the matched filter must not add more than a sample or two of latency")
    }

    /// The onset path speaks while the envelope path is deaf. Two strikes where
    /// the second lands on the first one's tail: with the knob off the detector
    /// sees one onset, with it on it sees two.
    func testTheOnsetPathCanSpeakWhileTheEnvelopeIsStillDisarmed() {
        // A long ring-down, so the envelope never falls back under the release
        // level between the strikes. This is the lap failure in miniature.
        let first = SyntheticStream.leadInNs
        let second = first + 160_000_000
        var stream = SyntheticStream(
            durationNs: second + 1_000_000_000,
            taps: [SyntheticStream.Tap(tNs: first,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 14),
                                       ringHz: 35, decaySeconds: 0.13),
                   SyntheticStream.Tap(tNs: second,
                                       amplitude: SyntheticStream.amplitude(timesThreshold: 4),
                                       ringHz: 35, decaySeconds: 0.13)])
        stream.noiseAmplitude = 0.001
        let samples = stream.samples()

        let deaf = TapDetector.replay(samples: samples, inputs: [])
        XCTAssertEqual(deaf.onsets.count, 1,
                       "the fixture is only interesting if the envelope really is deaf to the second strike")

        var on = DetectorConfig.default
        on.matchedFilterAdmitG = 0.02
        let hearing = TapDetector.replay(samples: samples, inputs: [], config: on)

        XCTAssertGreaterThan(hearing.onsets.count, deaf.onsets.count,
                             "the matched-filter path exists to declare an onset the envelope cannot")
    }

    /// It cannot double-count one strike: the onset debounce still bounds it.
    func testTheOnsetPathObeysTheDebounce() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        var on = DetectorConfig.default
        on.matchedFilterAdmitG = 0.005      // absurdly low: admit almost anything
        let out = TapDetector.replay(samples: stream.samples(), inputs: [], config: on)
        let times = out.onsets.map(\.tNs).sorted()
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, DSPTuning.default.onsetDebounceNs,
                                        "two onsets closer than the debounce describe one strike twice")
        }
    }

    // MARK: - Cost

    /// A menubar app has to idle cheaply, so the front end's per-sample cost is
    /// a shipping constraint and not a footnote. Reported, and bounded loosely
    /// enough that a slow CI machine does not fail the suite.
    func testPerSampleCostIsReported() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        let samples = stream.samples()

        func time(_ weight: Double, _ admit: Double) -> Double {
            var chain = SignalChain(tuning: .default)
            chain.matchedFilterWeight = weight
            chain.evaluateMatchedFilter = weight > 0 || admit > 0
            var sink = 0.0
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 {
                for s in samples {
                    sink += chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                          holdNoiseFloor: false)
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            XCTAssertGreaterThan(sink, 0)
            return elapsed / Double(samples.count * 20) * 1e6
        }

        let off = time(0, 0)
        let on = time(1, 0)
        print(String(format: "SignalChain cost: %.3f us/sample off, %.3f us/sample with the "
                             + "matched filter (%.0f Hz stream => %.2f%% of one core)",
                     off, on, DSPTuning.default.sampleRateHz,
                     on * DSPTuning.default.sampleRateHz / 1e6 * 100))
        XCTAssertLessThan(on, 20.0, "a 20-tap correlation per sample should be well under 20 us")
    }
}
