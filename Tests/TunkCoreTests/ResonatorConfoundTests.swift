import XCTest
@testable import TunkCore

/// Does the resonator front end reject aperiodic knocks better than the shipped
/// chain? Measured, because the 24.2-per-60-s finding in notes/OPEN_ITEMS
/// predates the resonator and nobody had checked.
///
/// It does not — and the first attempt said it did, by a factor of infinity.
/// Scaling knock amplitude with the SHARED helper made every knock sub-threshold
/// for the resonator, whose chain gain is 0.0789 against the default's 0.68. The
/// control that caught it is kept below: at the amplitude under test, each front
/// end must still detect a real double-tap, or the comparison is measuring the
/// threshold rather than the filter.
final class ResonatorConfoundTests: XCTestCase {

    private func jitterTrain(seed: UInt64, amplitude: Double) -> SyntheticStream {
        var rng = SyntheticNoise(seed: seed)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 61_000_000_000)
        stream.seed = seed &+ 99
        var t = SyntheticStream.leadInNs
        while t < SyntheticStream.leadInNs + 60_000_000_000 {
            stream.taps.append(.init(tNs: t, amplitude: amplitude))
            t += 100_000_000 + Int64((rng.next(1.0) + 1) / 2 * 300_000_000)
        }
        return stream
    }

    private func fires(_ stream: SyntheticStream, _ tuning: DSPTuning, _ config: DetectorConfig) -> Int {
        let d = TapDetector(config: config, tuning: tuning, armedTapCounts: [2])
        var n = 0
        for s in stream.samples() where d.ingest(sample: s) != nil { n += 1 }
        return n
    }

    func testTheResonatorDoesNotRejectAperiodicKnocks() {
        var resTune = DSPTuning.default
        resTune.resonatorHz = 40; resTune.resonatorQ = 2; resTune.minThresholdG = 0.002
        var resCfg = DetectorConfig.default
        resCfg.defaultThreshold = 0.011

        for (tuning, config) in [(DSPTuning.default, DetectorConfig.default), (resTune, resCfg)] {
            let amp = SyntheticStream.amplitude(timesThreshold: 1.6, tuning: tuning,
                                                threshold: config.defaultThreshold)
            // The control. Without it the next assertion passes for the wrong reason.
            var gesture = SyntheticStream(durationNs: SyntheticStream.leadInNs + 3_000_000_000)
            gesture.taps.append(.init(tNs: SyntheticStream.leadInNs, amplitude: amp))
            gesture.taps.append(.init(tNs: SyntheticStream.leadInNs + 160_000_000, amplitude: amp))
            XCTAssertEqual(fires(gesture, tuning, config), 1,
                           "the amplitude under test must be detectable by this front end, "
                           + "or the knock count below measures the threshold and not the filter")

            let counts = (UInt64(1)...UInt64(5)).map { fires(jitterTrain(seed: $0, amplitude: amp), tuning, config) }
            let mean = Double(counts.reduce(0, +)) / 5.0
            XCTAssertGreaterThan(mean, 15, "aperiodic knocks still fire on both front ends: \(counts)")
        }
    }
}
