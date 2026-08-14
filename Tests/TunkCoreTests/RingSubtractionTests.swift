import XCTest
@testable import TunkCore

/// The front-end ring subtractor: `r[n] = (h[n] - a * h[n-P]) / (1 + |a|)` on
/// each high-passed axis, ahead of the magnitude.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). These tests
/// prove the knob's contract — off is off, on is bounded, both are causal and
/// deterministic — not its detection rate. What it is worth on real recordings
/// is in `notes/BAR_ASSESSMENT.md`, measured with `tunk-score` on `data/raw`.
final class RingSubtractionTests: XCTestCase {

    private func replay(_ samples: [AccelSample], _ config: DetectorConfig)
        -> (triggers: [Trigger], onsets: [OnsetEvent])
    {
        TapDetector.replay(samples: samples, inputs: [], config: config, armedTapCounts: [2])
    }

    /// A stream with two SYNTHETIC gestures and a stretch of quiet.
    ///
    /// The taps are loud on purpose. The subtractor halves a 180 Hz synthetic
    /// ring — the delayed sample it cancels against is pre-tap quiet, so the
    /// residual is just the normalisation — and a fixture sitting 1.6x over the
    /// threshold would go silent the moment the knob came on, which would make
    /// every "on" test below vacuously true.
    private func fixture() -> [AccelSample] {
        var stream = SyntheticStream(durationNs: 4_000_000_000, taps: [
            .init(tNs: 1_500_000_000, amplitude: SyntheticStream.amplitude(timesThreshold: 3.2)),
            .init(tNs: 1_680_000_000, amplitude: SyntheticStream.amplitude(timesThreshold: 3.2)),
            .init(tNs: 3_000_000_000, amplitude: SyntheticStream.amplitude(timesThreshold: 4.0)),
            .init(tNs: 3_190_000_000, amplitude: SyntheticStream.amplitude(timesThreshold: 4.0)),
        ])
        stream.noiseAmplitude = 0.002
        return stream.samples()
    }

    // MARK: - Off is off

    func testShippedDefaultLeavesTheRingSubtractorOff() {
        XCTAssertEqual(DetectorConfig.default.ringCombDelaySamples, 0)
    }

    /// The whole claim behind the knob: with the delay at zero the detector is
    /// the one that shipped, down to every onset strength. A front-end change
    /// that quietly moved the envelope by a hair would move the threshold
    /// crossings on real recordings and there would be no way to attribute it.
    func testDelayZeroReproducesTheDetectorThatShipped() {
        let samples = fixture()
        let shipped = replay(samples, .default)

        var withKnob = DetectorConfig.default
        withKnob.ringCombDelaySamples = 0
        withKnob.ringCombCoefficient = 0.8
        let same = replay(samples, withKnob)

        XCTAssertEqual(shipped.triggers, same.triggers)
        XCTAssertEqual(shipped.onsets, same.onsets)
        XCTAssertFalse(shipped.triggers.isEmpty, "fixture must produce triggers or it proves nothing")

        // The coefficient alone must not do anything either. It is only read
        // while the delay is non-zero.
        var coefficientOnly = DetectorConfig.default
        coefficientOnly.ringCombCoefficient = 0.25
        XCTAssertEqual(replay(samples, coefficientOnly).onsets, shipped.onsets)
    }

    /// A settings file written by this build, with the knob off, is the exact
    /// text an older build wrote. Same for every harness report, which is how
    /// "off reproduces baseline" is checked rather than asserted.
    func testTheKnobIsAbsentFromEncodedSettingsWhileItIsOff() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let off = try encoder.encode(DetectorConfig.default)
        let text = String(decoding: off, as: UTF8.self)
        XCTAssertFalse(text.contains("ringComb"), text)

        var on = DetectorConfig.default
        on.ringCombDelaySamples = 10
        let onText = String(decoding: try encoder.encode(on), as: UTF8.self)
        XCTAssertTrue(onText.contains("ringCombDelaySamples"), onText)
        XCTAssertTrue(onText.contains("ringCombCoefficient"), onText)
    }

    func testASettingsFileWrittenBeforeTheKnobExistedLoadsWithItOff() throws {
        let legacy = #"{"sensitivity":1,"defaultThreshold":0.032,"tapCountToFire":2}"#
        let decoded = try JSONDecoder().decode(DetectorConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.ringCombDelaySamples, 0)
        XCTAssertEqual(decoded.ringCombCoefficient, DetectorConfig.default.ringCombCoefficient)
    }

    func testARoundTripKeepsTheKnob() throws {
        var on = DetectorConfig.default
        on.ringCombDelaySamples = 10
        on.ringCombCoefficient = 1.0
        let back = try JSONDecoder().decode(DetectorConfig.self, from: try JSONEncoder().encode(on))
        XCTAssertEqual(back.ringCombDelaySamples, 10)
        XCTAssertEqual(back.ringCombCoefficient, 1.0)
    }

    // MARK: - On does something, and something bounded

    func testTurningItOnChangesTheEnvelope() {
        var on = DetectorConfig.default
        on.ringCombDelaySamples = 10
        on.ringCombCoefficient = 1.0
        let samples = fixture()
        XCTAssertNotEqual(replay(samples, on).onsets, replay(samples, .default).onsets)
    }

    /// The null the filter is built around. With `a = 1` a component whose
    /// period is exactly the delay cancels itself completely, which is the only
    /// part of "subtract the ring" that is exact rather than approximate.
    func testAComponentAtTheCombPeriodCancels() {
        let delay = 10
        let periodNs = Double(delay) * Double(SyntheticStream.intervalNs)
        var samples: [AccelSample] = []
        var t: Int64 = 0
        while t <= 2_000_000_000 {
            let phase = 2 * Double.pi * Double(t) / periodNs
            samples.append(AccelSample(tNs: t, arrivalNs: t,
                                       x: Float(0.004 + 0.5 * sin(phase)),
                                       y: -0.003,
                                       z: Float(-0.9796 + 0.5 * sin(phase))))
            t += SyntheticStream.intervalNs
        }

        var chainOff = SignalChain(tuning: .default)
        var chainOn = SignalChain(tuning: .default)
        var lastOff = 0.0, lastOn = 0.0
        for s in samples {
            lastOff = chainOff.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                       holdNoiseFloor: true)
            lastOn = chainOn.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                     holdNoiseFloor: true,
                                     combDelaySamples: delay, combCoefficient: 1.0)
        }
        XCTAssertGreaterThan(lastOff, 0.3, "the fixture must be loud without the comb")
        XCTAssertLessThan(lastOn, lastOff / 100, "a component at the comb period must cancel")
    }

    /// A subtraction that feeds back more than it removes turns quiet into
    /// onsets, so the residual is normalised by the filter's largest possible
    /// gain and can never exceed what went in.
    func testTheResidualNeverExceedsTheSignalItCameFrom() {
        let samples = fixture()
        for delay in [1, 5, 10, 21, 64] {
            for coefficient in [-1.0, -0.5, 0.5, 0.8, 1.0] {
                var chainOff = SignalChain(tuning: .default)
                var chainOn = SignalChain(tuning: .default)
                var peakOff = 0.0, peakOn = 0.0
                for s in samples {
                    peakOff = max(peakOff, chainOff.process(x: Double(s.x), y: Double(s.y),
                                                            z: Double(s.z), holdNoiseFloor: true))
                    peakOn = max(peakOn, chainOn.process(x: Double(s.x), y: Double(s.y),
                                                         z: Double(s.z), holdNoiseFloor: true,
                                                         combDelaySamples: delay,
                                                         combCoefficient: coefficient))
                }
                XCTAssertLessThanOrEqual(peakOn, peakOff + 1e-12,
                                         "delay \(delay), coefficient \(coefficient) amplified")
            }
        }
    }

    /// Quiet must stay quiet at every value the sweep can reach. The knob's
    /// stated risk is that subtraction goes unstable and manufactures onsets
    /// out of sensor hash.
    func testNoValueOfTheKnobManufacturesOnsetsOutOfQuiet() {
        var stream = SyntheticStream(durationNs: 6_000_000_000, taps: [])
        stream.noiseAmplitude = 0.002
        stream.wobbleAmplitude = 0.01
        let quiet = stream.samples()

        for delay in [1, 2, 5, 10, 12, 21, 32, 64] {
            for coefficient in [0.4, 0.6, 0.8, 1.0] {
                var config = DetectorConfig.default
                config.ringCombDelaySamples = delay
                config.ringCombCoefficient = coefficient
                let out = replay(quiet, config)
                XCTAssertTrue(out.triggers.isEmpty,
                              "delay \(delay), coefficient \(coefficient) fired on quiet")
                XCTAssertTrue(out.onsets.isEmpty,
                              "delay \(delay), coefficient \(coefficient) found "
                              + "\(out.onsets.count) onsets in quiet")
            }
        }
    }

    // MARK: - Still causal, still deterministic

    func testTheSubtractorIsDeterministic() {
        var config = DetectorConfig.default
        config.ringCombDelaySamples = 10
        config.ringCombCoefficient = 1.0
        let samples = fixture()
        XCTAssertEqual(replay(samples, config).onsets, replay(samples, config).onsets)
    }

    /// Causality, stated as a test rather than a comment: what the detector has
    /// already emitted cannot change when later samples arrive. Truncating the
    /// stream must truncate the output, not rewrite it.
    func testLaterSamplesCannotChangeWhatWasAlreadyEmitted() {
        var config = DetectorConfig.default
        config.ringCombDelaySamples = 10
        config.ringCombCoefficient = 1.0
        let samples = fixture()
        let full = replay(samples, config)
        let half = replay(Array(samples.prefix(samples.count * 2 / 3)), config)
        XCTAssertFalse(half.onsets.isEmpty)
        XCTAssertEqual(Array(full.onsets.prefix(half.onsets.count)), half.onsets)
    }

    /// The chain drops its delay line with everything else, so a sensor dropout
    /// cannot leave the subtractor cancelling against samples from before the
    /// seam.
    func testResetClearsTheDelayLine() {
        var chain = SignalChain(tuning: .default)
        for _ in 0..<200 {
            _ = chain.process(x: 0.5, y: -0.5, z: -0.5, holdNoiseFloor: true,
                              combDelaySamples: 10, combCoefficient: 1.0)
        }
        chain.reset()

        var fresh = SignalChain(tuning: .default)
        for _ in 0..<50 {
            let a = chain.process(x: 0.004, y: -0.003, z: -0.9796, holdNoiseFloor: true,
                                  combDelaySamples: 10, combCoefficient: 1.0)
            let b = fresh.process(x: 0.004, y: -0.003, z: -0.9796, holdNoiseFloor: true,
                                  combDelaySamples: 10, combCoefficient: 1.0)
            XCTAssertEqual(a, b)
        }
    }

    // MARK: - Coherence

    func testAnOverlongDelayIsClampedToTheDelayLine() {
        var config = DetectorConfig.default
        config.ringCombDelaySamples = 5_000
        XCTAssertEqual(config.madeCoherent().ringCombDelaySamples,
                       SignalChain.maxRingCombDelaySamples)
        XCTAssertEqual(config.coherenceIssues.map(\.field), ["ringCombDelaySamples"])

        config.ringCombDelaySamples = -3
        XCTAssertEqual(config.madeCoherent().ringCombDelaySamples, 0)
    }

    func testARunawayCoefficientIsClamped() {
        var config = DetectorConfig.default
        config.ringCombDelaySamples = 10
        config.ringCombCoefficient = 4.0
        XCTAssertEqual(config.madeCoherent().ringCombCoefficient, 1.0)

        config.ringCombCoefficient = .nan
        XCTAssertEqual(config.madeCoherent().ringCombCoefficient,
                       DetectorConfig.default.ringCombCoefficient)
        XCTAssertTrue(config.madeCoherent().madeCoherent().isCoherent)
    }

    func testTheShippedConfigIsStillCoherent() {
        XCTAssertTrue(DetectorConfig.default.isCoherent)
    }
}
