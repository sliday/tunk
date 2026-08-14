import XCTest
@testable import TunkCore

/// The ring-to-strike ratio reported by calibration.
///
/// It earns its place because it is the only property measured that tracks lap
/// detection. Across four lap sessions the tap amplitude (0.032-0.036 g), the
/// noise floor and the decay time were effectively identical, and SNR ran
/// BACKWARDS — the session that detected 100 % had the lowest. The ring did not:
/// 0.30, 0.38 and 0.42 gave 95 %, 90 % and 100 %; 0.61 gave 80 %.
final class RingToStrikeTests: XCTestCase {

    private func gestures(_ n: Int) -> [(strengths: [Double], intervalNs: Int64)] {
        (0..<n).map { _ in (strengths: [0.09, 0.08], intervalNs: 180_000_000) }
    }

    func testReportsTheMedianRatio() throws {
        let result = try XCTUnwrap(TapCalibration.calibrate(
            gestures: gestures(5), ringRatios: [0.30, 0.35, 0.40, 0.45, 0.50]))
        let ratio = try XCTUnwrap(result.ringToStrike)
        XCTAssertEqual(ratio, 0.40, accuracy: 0.001, "median, not mean: one loud "
                       + "gesture must not condemn a surface")
    }

    /// The line sits between the measured populations rather than on one of
    /// them: 0.42 detected everything, 0.61 lost a fifth.
    func testTheWarningLineSeparatesTheMeasuredSessions() {
        XCTAssertGreaterThan(TapCalibration.noisyRingRatio, 0.42)
        XCTAssertLessThan(TapCalibration.noisyRingRatio, 0.61)
    }

    func testNoRatioWhenNothingWasMeasured() throws {
        let result = try XCTUnwrap(TapCalibration.calibrate(gestures: gestures(5)))
        XCTAssertNil(result.ringToStrike)
    }

    /// A ratio cannot be negative or infinite, and a zero-peak onset must not
    /// produce one by dividing through.
    func testRubbishIsDropped() throws {
        let result = try XCTUnwrap(TapCalibration.calibrate(
            gestures: gestures(5), ringRatios: [0.4, -1, .infinity, .nan, 0]))
        XCTAssertEqual(try XCTUnwrap(result.ringToStrike), 0.4, accuracy: 0.001)
    }

    /// Measuring the ring must not disturb the threshold, which is derived from
    /// strengths alone.
    func testRingDoesNotMoveTheThreshold() throws {
        let without = try XCTUnwrap(TapCalibration.calibrate(gestures: gestures(5)))
        let with = try XCTUnwrap(TapCalibration.calibrate(
            gestures: gestures(5), ringRatios: [0.9, 0.9, 0.9]))
        XCTAssertEqual(without.threshold, with.threshold, accuracy: 1e-12)
        XCTAssertEqual(without.interTapNs, with.interTapNs)
    }
}
