import XCTest
@testable import TunkCore

/// The two within-gesture pair tests: do the onsets of one gesture look like one
/// hand doing one thing twice?
///
/// **They ship off, and the measurement says leave them off.** Graded on
/// `data/raw` at the resonator operating point, the six lap false triggers are
/// as strength-matched and as direction-matched as the 73 real lap detections;
/// see `notes/PAIR_COHERENCE.md` for the distributions and the sweeps. What is
/// tested here is only that the machinery does what it claims when it is armed,
/// and that it changes nothing at all when it is not.
///
/// Signals here are SYNTHETIC.
final class PairCoherenceTests: XCTestCase {

    private static let intervalNs: Int64 = 1_256_000

    /// Two SYNTHETIC strikes, each a damped ring, with per-strike amplitude and
    /// per-strike lateral sign.
    ///
    /// Spacing is an exact whole number of samples so both strikes are sampled
    /// at identical phase. That matters: with an arbitrary spacing the lateral
    /// direction at the peak sample lands wherever the ring happens to be, which
    /// is a real effect (it is half of why the direction statistic scatters on
    /// recorded taps) but it would make this test a coin toss.
    private func stream(amplitudes: [Double],
                        lateralSigns: [Double],
                        spacingSamples: Int = 143,
                        lateralNoise: Bool = true) -> [AccelSample] {
        let leadIn = 1500
        let tail = 800
        let count = leadIn + spacingSamples * (amplitudes.count - 1) + tail
        var noise = SyntheticNoise(seed: 0xBEEF)
        var out: [AccelSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = Int64(i) * Self.intervalNs
            var x = 0.004, y = -0.003
            var z = -0.9796 + noise.next(0.002)
            if lateralNoise {
                x += noise.next(0.002)
                y += noise.next(0.002)
            }
            for (k, amp) in amplitudes.enumerated() {
                let at = leadIn + k * spacingSamples
                guard i >= at else { continue }
                let dt = Double(i - at) / 796.3
                guard dt < 0.032 else { continue }
                let ring = exp(-dt / 0.004) * sin(2 * Double.pi * 180 * dt)
                z += amp * ring
                x += amp * 0.35 * ring * lateralSigns[k]
                y += amp * 0.25 * ring * lateralSigns[k]
            }
            out.append(AccelSample(tNs: t, arrivalNs: t, x: Float(x), y: Float(y), z: Float(z)))
        }
        return out
    }

    private func triggers(_ config: DetectorConfig, _ samples: [AccelSample]) -> [Trigger] {
        let detector = TapDetector(config: config)
        var out: [Trigger] = []
        for s in samples { if let t = detector.ingest(sample: s) { out.append(t) } }
        return out
    }

    private func amplitude(timesThreshold multiple: Double) -> Double {
        SyntheticStream.amplitude(timesThreshold: multiple)
    }

    // MARK: - Off is off

    func testBothPairTestsShipDisabled() {
        XCTAssertEqual(DetectorConfig.default.pairStrengthMinRatio, 0)
        XCTAssertNil(DetectorConfig.default.pairDirectionMinCosine)
    }

    /// A config with them off encodes without mentioning them, so a settings
    /// file and a harness report written by this build are byte-identical to
    /// ones written before the fields existed.
    func testDisabledPairTestsAreAbsentFromEncodedConfig() throws {
        let data = try JSONEncoder().encode(DetectorConfig.default)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("pairStrengthMinRatio"))
        XCTAssertFalse(json.contains("pairDirectionMinCosine"))

        let decoded = try JSONDecoder().decode(DetectorConfig.self, from: data)
        XCTAssertEqual(decoded, DetectorConfig.default)
    }

    func testEnabledPairTestsRoundTrip() throws {
        var config = DetectorConfig.default
        config.pairStrengthMinRatio = 0.7
        config.pairDirectionMinCosine = 0.5
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(DetectorConfig.self, from: data), config)
    }

    /// A mismatched pair that the shipped detector fires on still fires on it.
    /// This is the regression that matters: the pair tests must be invisible.
    func testAMismatchedPairStillFiresWithTheTestsOff() {
        let samples = stream(amplitudes: [amplitude(timesThreshold: 2.4),
                                          amplitude(timesThreshold: 1.4)],
                             lateralSigns: [1, -1])
        XCTAssertEqual(triggers(.default, samples).count, 1)
    }

    // MARK: - On does what it says

    func testStrengthRatioRejectsAMismatchedPair() {
        let samples = stream(amplitudes: [amplitude(timesThreshold: 2.4),
                                          amplitude(timesThreshold: 1.4)],
                             lateralSigns: [1, 1])
        var config = DetectorConfig.default
        XCTAssertEqual(triggers(config, samples).count, 1)
        config.pairStrengthMinRatio = 0.8
        XCTAssertEqual(triggers(config, samples).count, 0)
    }

    func testStrengthRatioAdmitsAMatchedPair() {
        let amp = amplitude(timesThreshold: 1.6)
        let samples = stream(amplitudes: [amp, amp], lateralSigns: [1, 1])
        var config = DetectorConfig.default
        config.pairStrengthMinRatio = 0.8
        XCTAssertEqual(triggers(config, samples).count, 1)
    }

    func testDirectionTestRejectsAPairThatPushedOppositeWays() {
        let amp = amplitude(timesThreshold: 1.6)
        let matched = stream(amplitudes: [amp, amp], lateralSigns: [1, 1])
        let opposed = stream(amplitudes: [amp, amp], lateralSigns: [1, -1])
        var config = DetectorConfig.default
        config.pairDirectionMinCosine = 0.5
        XCTAssertEqual(triggers(config, matched).count, 1)
        XCTAssertEqual(triggers(config, opposed).count, 0)
    }

    /// A strike with no lateral energy cannot answer the direction question, and
    /// is not made to. Silence there means "no evidence", not "reject" — the
    /// alternative would turn a strike straight down onto the deck, which is
    /// what the gesture is supposed to be, into a rejection.
    func testAStrikeWithoutLateralEnergyIsNotRejected() {
        let amp = amplitude(timesThreshold: 1.6)
        let samples = stream(amplitudes: [amp, amp], lateralSigns: [0, 0],
                             lateralNoise: false)
        var config = DetectorConfig.default
        config.pairDirectionMinCosine = 0.99
        XCTAssertEqual(triggers(config, samples).count, 1)
    }

    // MARK: - Config coherence

    func testARatioAboveOneIsClampedRatherThanSilentlyDisarmingEverything() {
        var config = DetectorConfig.default
        config.pairStrengthMinRatio = 1.5
        let fixed = config.madeCoherent()
        XCTAssertEqual(fixed.pairStrengthMinRatio, 1.0)
        XCTAssertEqual(config.coherenceIssues.map(\.field), ["pairStrengthMinRatio"])
    }

    func testANegativeRatioIsTreatedAsOff() {
        var config = DetectorConfig.default
        config.pairStrengthMinRatio = -0.2
        XCTAssertEqual(config.madeCoherent().pairStrengthMinRatio, 0)
    }

    func testACosineOutsideItsRangeIsClamped() {
        var high = DetectorConfig.default
        high.pairDirectionMinCosine = 2
        XCTAssertEqual(high.madeCoherent().pairDirectionMinCosine, 1)
        XCTAssertEqual(high.coherenceIssues.map(\.field), ["pairDirectionMinCosine"])

        var low = DetectorConfig.default
        low.pairDirectionMinCosine = -2
        // -1 already admits every pair, so anything below it is "off".
        XCTAssertNil(low.madeCoherent().pairDirectionMinCosine)
    }
}
