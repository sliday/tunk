import XCTest
@testable import TunkCore

/// Timing side of "learn my tap". Every interval here is a real measured one
/// from `data/`, so a change that looks fine against invented numbers still has
/// to survive the distributions this operator actually produces.
final class CalibrationTimingTests: XCTestCase {

    // Measured inter-tap intervals, ms, from the labelled tap decks.
    private let deskMs: [Int64] = [173, 168, 181, 176, 190, 172, 199, 185, 178, 183]
    private let lapMs: [Int64] = [156, 210, 240, 175, 259, 191, 168, 300, 220, 597]

    private func ns(_ ms: [Int64]) -> [Int64] { ms.map { $0 * 1_000_000 } }

    func testFitAimsAboveTheNinetiethPercentile() throws {
        let fit = try XCTUnwrap(TapCalibration.fitInterTap(intervalsNs: ns(deskMs)))
        // The window has to sit above p90, or one gesture in ten falls outside
        // the very window fitted to it.
        XCTAssertGreaterThan(fit.window, fit.p90)
        XCTAssertLessThan(fit.p10, fit.p90)
        XCTAssertFalse(fit.clamped, "a desk gesture fits inside the latency budget")
    }

    func testSlowGestureIsClampedAndSaysSo() throws {
        let fit = try XCTUnwrap(TapCalibration.fitInterTap(intervalsNs: ns(lapMs)))
        XCTAssertTrue(fit.clamped, "lap p90 x 1.15 exceeds the latency-safe window")
        XCTAssertEqual(fit.window, TapCalibration.latencySafeWindowNs)
    }

    /// The clamp is a budget, not a physical limit. A user who would rather wait
    /// than be missed can have the wider window — but only by asking.
    func testOptingOutOfTheLatencyBudgetWidensTheWindow() throws {
        let safe = try XCTUnwrap(TapCalibration.fitInterTap(intervalsNs: ns(lapMs)))
        let wide = try XCTUnwrap(TapCalibration.fitInterTap(
            intervalsNs: ns(lapMs), allowExceedingLatencyBudget: true))
        XCTAssertGreaterThan(wide.window, safe.window)
        XCTAssertLessThanOrEqual(wide.window, TapCalibration.maxWindowNs)
    }

    func testTooFewIntervalsRefusesToFit() {
        XCTAssertNil(TapCalibration.fitInterTap(intervalsNs: ns([170, 180])))
        XCTAssertNil(TapCalibration.fitInterTap(intervalsNs: []))
    }

    func testWindowNeverFallsBelowTheMinimum() throws {
        let fit = try XCTUnwrap(TapCalibration.fitInterTap(intervalsNs: ns([20, 25, 22, 30])))
        XCTAssertEqual(fit.window, 100_000_000)
    }

    // MARK: - grouping

    func testGroupingSplitsOnThePauseBetweenGestures() {
        // Two double-taps, 2 s apart.
        let times: [Int64] = [0, 180, 2_000, 2_170].map { $0 * 1_000_000 }
        let g = TapCalibration.gestures(onsetTimesNs: times,
                                        strengths: [0.09, 0.07, 0.10, 0.08])
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].intervalNs, 180_000_000)
        XCTAssertEqual(g[1].intervalNs, 170_000_000)
        XCTAssertEqual(g.flatMap(\.strengths).count, 4)
    }

    /// A run of three is ambiguous — a fumble, or a damped case ringing loudly
    /// enough to publish a second lobe. Its strengths still count; its timing
    /// must not, or the artifact gets baked into the user's window.
    func testRunOfThreeContributesStrengthButNoTiming() {
        let times: [Int64] = [0, 180, 340].map { $0 * 1_000_000 }
        let g = TapCalibration.gestures(onsetTimesNs: times, strengths: [0.09, 0.07, 0.05])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].intervalNs, 0, "no interval learned from an ambiguous run")
        XCTAssertEqual(g[0].strengths.count, 3)
        // And a zero interval must not reach the fit as a real measurement.
        XCTAssertNil(TapCalibration.fitInterTap(intervalsNs: g.map(\.intervalNs)))
    }

    func testSingleTapRunYieldsNoInterval() {
        let g = TapCalibration.gestures(onsetTimesNs: [0], strengths: [0.09])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].intervalNs, 0)
    }

    func testMismatchedInputIsRefusedRatherThanTrusted() {
        XCTAssertTrue(TapCalibration.gestures(onsetTimesNs: [0, 1], strengths: [0.1]).isEmpty)
    }

    // MARK: - commit

    /// The window and the confirm window are the same quantity seen twice, and
    /// `madeCoherent()` clamps `maxInterTapNs` to `confirmWindowNs`. Writing one
    /// without the other would be silently undone.
    func testApplyMovesBothHalvesOfTheWindow() throws {
        let gestures = ns(deskMs).map { (strengths: [0.09], intervalNs: $0) }
        let result = try XCTUnwrap(TapCalibration.calibrate(gestures: gestures))
        let window = try XCTUnwrap(result.interTapNs)

        var base = DetectorConfig.default
        base.maxInterTapNs = 150_000_000
        base.confirmWindowNs = 150_000_000
        let tuned = TapCalibration.apply(result, to: base).madeCoherent()

        XCTAssertEqual(tuned.maxInterTapNs, window)
        XCTAssertEqual(tuned.confirmWindowNs, window)
        XCTAssertEqual(tuned.calibratedInterTapNs, window)
        XCTAssertGreaterThanOrEqual(tuned.maxInterTapNs, tuned.minInterTapNs)
    }

    /// Calibrating from loose strengths must not invent a window out of nothing.
    func testStrengthOnlyCalibrationLeavesTimingAlone() throws {
        let result = try XCTUnwrap(TapCalibration.calibrate(tapStrengths: [0.09, 0.08, 0.10]))
        XCTAssertNil(result.interTapNs)

        let base = DetectorConfig.default
        let tuned = TapCalibration.apply(result, to: base)
        XCTAssertEqual(tuned.maxInterTapNs, base.maxInterTapNs)
        XCTAssertEqual(tuned.confirmWindowNs, base.confirmWindowNs)
        XCTAssertNil(tuned.calibratedInterTapNs)
    }

    /// The learned window is the latency. If a calibration could push it past
    /// the PRD's bar without the user asking, the bar would be decided by
    /// whoever taps slowest.
    func testDefaultFitCannotBreachTheLatencyBar() throws {
        let slow = ns([400, 450, 500, 550, 600])
        let fit = try XCTUnwrap(TapCalibration.fitInterTap(intervalsNs: slow))
        XCTAssertLessThanOrEqual(fit.window, 250_000_000)
        XCTAssertTrue(fit.clamped)
    }
}
