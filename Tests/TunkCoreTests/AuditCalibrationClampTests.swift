import XCTest
@testable import TunkCore

/// Audit finding detector-absoluclamp: a non-finite noise floor must not
/// bypass the absolute clamp in `TapCalibration.calibrate(tapStrengths:)`.
/// Swift's `max(nan, x)` returns nan, so before the fix a NaN floor let the
/// threshold drop under `minThresholdG` and an infinite floor produced an
/// infinite threshold.
final class AuditCalibrationClampTests: XCTestCase {

    func testNaNNoiseFloorStillAppliesTheAbsoluteClamp() throws {
        let tuning = DSPTuning.default
        let result = try XCTUnwrap(TapCalibration.calibrate(tapStrengths: [0.001, 0.001],
                                                            noiseFloor: .nan,
                                                            tuning: tuning))
        XCTAssertTrue(result.threshold.isFinite, "threshold \(result.threshold)")
        XCTAssertGreaterThanOrEqual(result.threshold, tuning.minThresholdG,
                                    "threshold \(result.threshold) is under minThresholdG \(tuning.minThresholdG)")
        XCTAssertTrue(result.noiseLimited, "a 0.001 g tap set is clamped by the 0.02 g floor")
        XCTAssertEqual(result.noiseFloor, 0, "a NaN floor is stored as unknown (0)")
    }

    func testInfiniteNoiseFloorDoesNotProduceAnInfiniteThreshold() throws {
        let tuning = DSPTuning.default
        let result = try XCTUnwrap(TapCalibration.calibrate(tapStrengths: [0.05, 0.06],
                                                            noiseFloor: .infinity,
                                                            tuning: tuning))
        XCTAssertTrue(result.threshold.isFinite, "threshold \(result.threshold)")
        XCTAssertGreaterThanOrEqual(result.threshold, tuning.minThresholdG)
        XCTAssertEqual(result.noiseFloor, 0, "an infinite floor is stored as unknown (0)")
        XCTAssertTrue(result.margin.isFinite)
    }

    func testFiniteNoiseFloorIsUnchangedByTheSanitiser() throws {
        let tuning = DSPTuning.default
        let result = try XCTUnwrap(TapCalibration.calibrate(tapStrengths: [0.05, 0.06],
                                                            noiseFloor: 0.01,
                                                            tuning: tuning))
        XCTAssertEqual(result.noiseFloor, 0.01)
        XCTAssertEqual(result.threshold, max(tuning.noiseSnrMultiple * 0.01, tuning.minThresholdG),
                       accuracy: 1e-12)
    }
}
