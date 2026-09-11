import XCTest
@testable import TunkCore

/// Learning the join window must leave a band the user's own cadence fits in.
/// A hand-raised `minInterTapNs` above the learned window used to survive
/// `apply()`, and `madeCoherent()` then clamped min == max, so the gesture the
/// user had just calibrated could no longer group.
final class AuditCalibrationJoinBandTests: XCTestCase {

    private func ns(_ ms: Int64) -> Int64 { ms * 1_000_000 }

    func testCalibratedWindowUnderAHandSetMinimumStillDetectsTheCalibratedGesture() throws {
        // The panel slider allows a minimum up to 200 ms.
        var config = DetectorConfig.default
        config.minInterTapNs = ns(200)

        // Ten calibration gestures at the user's real cadence, 150 ms.
        let gestures = (0..<10).map { _ in (strengths: [0.09, 0.09], intervalNs: ns(150)) }
        let result = try XCTUnwrap(TapCalibration.calibrate(gestures: gestures))
        let window = try XCTUnwrap(result.interTapNs)
        XCTAssertFalse(result.interTapClamped)
        XCTAssertLessThan(window, ns(200), "the learned window sits under the hand-set minimum")

        let applied = TapCalibration.apply(result, to: config)
        XCTAssertLessThanOrEqual(applied.minInterTapNs, applied.maxInterTapNs,
                                 "apply() must hand back a band, not min > max")
        XCTAssertTrue(applied.coherenceIssues.filter { $0.field == "minInterTapNs" }.isEmpty,
                      "no minInterTapNs clamp should be needed: \(applied.coherenceIssues)")
        XCTAssertGreaterThanOrEqual(applied.minInterTapNs, DSPTuning.default.onsetDebounceNs,
                                    "the lowered minimum stays reachable above the onset debounce")

        let inForce = applied.madeCoherent()
        XCTAssertLessThan(inForce.minInterTapNs, inForce.maxInterTapNs,
                          "band collapsed to [\(inForce.minInterTapNs), \(inForce.maxInterTapNs)]")

        // The gesture that was just calibrated has to fire with the applied config.
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: ns(150), amplitude: 0.09)
        let replay = TapDetector.replay(samples: stream.samples(), inputs: [], config: applied)
        let spacing = replay.onsets.count == 2 ? replay.onsets[1].tNs - replay.onsets[0].tNs : -1
        XCTAssertEqual(replay.triggers.count, 1,
                       "calibrated 150 ms double-tap (detected spacing \(spacing) ns) "
                     + "must fire under min \(inForce.minInterTapNs) max \(inForce.maxInterTapNs)")
    }

    /// A hand-set minimum that already sits under the user's cadence is theirs
    /// to keep; apply() only lowers it when the observed band does not fit.
    func testApplyLeavesAMinimumThatAlreadyFitsAlone() throws {
        var config = DetectorConfig.default
        config.minInterTapNs = ns(110)
        let gestures = (0..<10).map { _ in (strengths: [0.09, 0.09], intervalNs: ns(150)) }
        let result = try XCTUnwrap(TapCalibration.calibrate(gestures: gestures))
        let applied = TapCalibration.apply(result, to: config)
        XCTAssertEqual(applied.minInterTapNs, ns(110))
    }
}
