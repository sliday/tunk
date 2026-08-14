import XCTest
@testable import TunkCore

/// SYNTHETIC fixtures again (see SyntheticSignal.swift). These pin the
/// calibration rule and the loop the settings panel runs: ten taps in, one
/// threshold out, and that threshold then drives the same detector.
final class CalibrationTests: XCTestCase {

    func testPercentileInterpolates() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        XCTAssertEqual(TapCalibration.percentile(values, 0), 1.0)
        XCTAssertEqual(TapCalibration.percentile(values, 1), 5.0)
        XCTAssertEqual(TapCalibration.percentile(values, 0.5), 3.0)
        XCTAssertEqual(TapCalibration.percentile(values, 0.25), 2.0, accuracy: 1e-12)
        XCTAssertEqual(TapCalibration.percentile([], 0.5), 0)
        XCTAssertEqual(TapCalibration.percentile([7.0], 0.9), 7.0)
    }

    func testThresholdSitsUnderTheWeakestTap() {
        // Ten plausible tap strengths in g, one of them a dud.
        let strengths = [0.62, 0.71, 0.55, 0.80, 0.66, 0.74, 0.31, 0.69, 0.77, 0.58]
        guard let result = TapCalibration.calibrate(tapStrengths: strengths, noiseFloor: 0.01) else {
            return XCTFail("expected a calibration")
        }

        XCTAssertEqual(result.sampleCount, 10)
        XCTAssertLessThan(result.threshold, result.weakestStrength,
                          "the reach term keeps even the dud above the bar")
        XCTAssertGreaterThan(result.threshold, 0)
        XCTAssertFalse(result.noiseLimited)
        XCTAssertGreaterThan(result.margin, 1.0)
        // The dud drags the low percentile down without owning it outright.
        XCTAssertGreaterThan(result.lowPercentileStrength, strengths.min()!)
        XCTAssertLessThan(result.lowPercentileStrength, result.medianStrength)
    }

    func testOneGrazeDoesNotOwnTheThreshold() {
        let good = Array(repeating: 0.70, count: 9)
        let withGraze = good + [0.05]
        let a = TapCalibration.calibrate(tapStrengths: good)!
        let b = TapCalibration.calibrate(tapStrengths: withGraze)!

        XCTAssertEqual(a.threshold, 0.6 * 0.70, accuracy: 1e-12, "p20 governs a clean set")
        // The graze pulls the bar down, but the distribution floor catches it
        // long before noise. A minimum-based rule would have landed at 0.04.
        XCTAssertLessThan(b.threshold, a.threshold)
        XCTAssertEqual(b.threshold, 0.35 * 0.70, accuracy: 1e-12)
        XCTAssertLessThan(b.margin, 1.0, "and the UI can see that tap was not covered")
    }

    func testNoiseFloorClampsTheThreshold() {
        // Soft taps on a surface that is already shaking. The floor, not the
        // taps, decides, and the result says so.
        let result = TapCalibration.calibrate(tapStrengths: Array(repeating: 0.10, count: 10),
                                              noiseFloor: 0.09)!
        XCTAssertTrue(result.noiseLimited)
        XCTAssertEqual(result.threshold, 4.0 * 0.09, accuracy: 1e-12,
                       "the adaptive floor is noiseSnrMultiple x noise")
        XCTAssertLessThan(result.margin, TapCalibration.comfortableMargin,
                          "and the UI should warn: the taps do not clear the room")
    }

    func testAbsoluteFloorAlwaysApplies() {
        let result = TapCalibration.calibrate(tapStrengths: Array(repeating: 0.001, count: 10),
                                              noiseFloor: 0)!
        XCTAssertEqual(result.threshold, DSPTuning.default.minThresholdG, accuracy: 1e-12)
        XCTAssertTrue(result.noiseLimited)
    }

    func testGarbageInput() {
        XCTAssertNil(TapCalibration.calibrate(tapStrengths: []))
        XCTAssertNil(TapCalibration.calibrate(tapStrengths: [0, -1, .nan, .infinity]))
    }

    func testApplyTouchesOnlyTheCalibratedThreshold() {
        let result = TapCalibration.calibrate(tapStrengths: [0.5, 0.6, 0.7])!
        let before = DetectorConfig.default
        let after = TapCalibration.apply(result, to: before)

        XCTAssertEqual(after.calibratedThreshold, result.threshold)
        var expected = after
        expected.calibratedThreshold = before.calibratedThreshold
        XCTAssertEqual(expected, before, "nothing else in the config moved")
        XCTAssertEqual(after.effectiveThreshold, result.threshold,
                       "sensitivity 1.0 means the calibrated value is used as measured")
    }

    // MARK: - The whole loop

    func testCalibrateFromRecordedOnsetsThenDetectWithIt() {
        // Step 1: the settings panel drops the threshold to a floor and asks for
        // ten taps. SYNTHETIC taps, deliberately uneven, one second apart so no
        // pair can group.
        var learning = DetectorConfig.default
        learning.calibratedThreshold = 0.05

        let amplitudes = [0.9, 1.1, 0.8, 1.0, 0.7, 1.2, 0.85, 0.95, 1.05, 0.75]
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs
                                     + Int64(amplitudes.count) * 1_000_000_000)
        for (i, amplitude) in amplitudes.enumerated() {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * 1_000_000_000,
                                     amplitude: amplitude))
        }

        let learned = TapDetector.replay(samples: stream.samples(), inputs: [], config: learning)
        XCTAssertTrue(learned.triggers.isEmpty, "calibration taps are singles; nothing fires")
        XCTAssertEqual(learned.onsets.count, amplitudes.count, "one onset per tap")

        // Step 2: derive the threshold from what the detector actually measured.
        guard let result = TapCalibration.calibrate(tapStrengths: learned.onsets.map(\.strength),
                                                    noiseFloor: 0.004) else {
            return XCTFail("expected a calibration")
        }
        XCTAssertFalse(result.noiseLimited)
        XCTAssertGreaterThan(result.margin, TapCalibration.comfortableMargin)

        let tuned = TapCalibration.apply(result, to: DetectorConfig.default)

        // Step 3: the tuned config detects a tap of the same strength ...
        let (normal, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000, amplitude: 0.9)
        XCTAssertEqual(TapDetector.replay(samples: normal.samples(), inputs: [],
                                          config: tuned).triggers.count, 1)

        // ... and ignores one a third as hard.
        let (feeble, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000, amplitude: 0.3)
        XCTAssertTrue(TapDetector.replay(samples: feeble.samples(), inputs: [],
                                         config: tuned).triggers.isEmpty)
    }

    func testCalibrationOnASoftSurfaceLowersTheBar() {
        // Amplitudes here used to be 0.30 g, chosen when the shipped default was
        // also 0.30 g so that a "weak" tap sat right on the bar. The default is
        // now 0.045 g, fitted to 40 real onsets, and 0.30 g is a firm tap rather
        // than a weak one — the fixture's premise inverted. Rescaled so "weak"
        // is genuinely below the shipped bar. Measured mapping through the
        // is genuinely below the shipped bar, stated as a multiple of it so the
        // fixture keeps meaning the same thing when the bar moves. 0.8x is under
        // the threshold, and still above DSPTuning's 0.02 g hard floor, so
        // calibration can reach down to it. Real desk taps measured 0.046 to
        // 0.133 g of envelope.
        let (weak, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000, amplitude: SyntheticStream.amplitude(timesThreshold: 0.8))
        XCTAssertTrue(TapDetector.replay(samples: weak.samples(), inputs: []).triggers.isEmpty,
                      "uncalibrated default is too high for this coupling")

        var learning = DetectorConfig.default
        learning.calibratedThreshold = 0.0205
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 10_000_000_000)
        for i in 0..<10 {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * 1_000_000_000,
                                     amplitude: SyntheticStream.amplitude(timesThreshold: 0.8)))
        }
        let learned = TapDetector.replay(samples: stream.samples(), inputs: [], config: learning)
        XCTAssertEqual(learned.onsets.count, 10)

        let result = TapCalibration.calibrate(tapStrengths: learned.onsets.map(\.strength),
                                              noiseFloor: 0.0005)!
        let tuned = TapCalibration.apply(result, to: DetectorConfig.default)
        XCTAssertLessThan(tuned.effectiveThreshold, DetectorConfig.default.effectiveThreshold)
        XCTAssertEqual(TapDetector.replay(samples: weak.samples(), inputs: [],
                                          config: tuned).triggers.count, 1)
    }
}
