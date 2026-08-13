import XCTest
@testable import TunkCore

/// Regression tests for a bug the lead introduced and a critic measured: the
/// detector resolved its firing counts through `tapCountToFire`, which is
/// `armedTapCounts.min()`. Binding single AND double therefore armed single
/// only, and double-tap stopped firing with no error anywhere.
///
/// Signals here are SYNTHETIC.
final class ArmedCountsTests: XCTestCase {

    /// Feeds a SYNTHETIC gesture built by the shared fixture, which includes the
    /// 1.5 s quiet lead-in the high pass and the adaptive noise floor need
    /// before the first tap. Hand-rolling a stream without that lead-in makes
    /// every tap land while the detector is still settling and nothing fires.
    private func feedGesture(_ detector: TapDetector,
                             count: Int,
                             spacingMs: Double) -> [Trigger] {
        let (stream, _) = SyntheticStream.gesture(count: count,
                                                  spacingNs: Int64(spacingMs * 1e6))
        var triggers: [Trigger] = []
        for s in stream.samples() {
            if let trigger = detector.ingest(sample: s) { triggers.append(trigger) }
        }
        return triggers
    }

    private func config(armed: Set<Int>) -> DetectorConfig {
        var c = DetectorConfig.default
        c.armedTapCounts = armed
        return c
    }

    /// The blocker itself.
    func testDoubleStillFiresWhenSingleIsAlsoArmed() {
        let d = TapDetector(config: config(armed: [1, 2]))
        XCTAssertEqual(d.effectiveArmedTapCounts, [1, 2],
                       "arming single and double must arm both, not just the lowest")
    }

    func testTripleIsReachableWhenArmed() {
        let d = TapDetector(config: config(armed: [2, 3]))
        XCTAssertEqual(d.effectiveArmedTapCounts, [2, 3])
    }

    /// Nothing bound must fire nothing. Previously the empty set fell through
    /// `tapCountToFire`'s `?? 2` default and silently armed double.
    func testNothingArmedFiresNothing() {
        let d = TapDetector(config: config(armed: []))
        XCTAssertTrue(d.effectiveArmedTapCounts.isEmpty,
                      "an empty armed set must not fall back to a default count")
        let triggers = feedGesture(d, count: 2, spacingMs: 150)
        XCTAssertTrue(triggers.isEmpty, "fired \(triggers.count) time(s) with nothing armed")
    }

    /// An unsupported entry must be dropped, not collapse the whole set. The
    /// old clamp turned {0, 2} into {1}: double disarmed, single armed — the
    /// count that fires on every mug and every footfall.
    func testUnsupportedCountIsDroppedWithoutDisarmingTheRest() {
        let coherent = config(armed: [0, 2]).madeCoherent()
        XCTAssertEqual(coherent.armedTapCounts, [2],
                       "a stray 0 must not disarm double and arm single")

        let high = config(armed: [2, 4]).madeCoherent()
        XCTAssertEqual(high.armedTapCounts, [2])
    }

    func testClampReportsWhatItChanged() {
        let issues = config(armed: [0, 2]).coherenceIssues
        XCTAssertTrue(issues.contains { $0.field == "armedTapCounts" },
                      "silently changing what is armed is exactly what must not happen")
    }

    /// `tapCountToFire` still reads and writes, for the call sites that use it.
    func testLegacyAccessorRoundTrips() {
        var c = DetectorConfig.default
        c.tapCountToFire = 3
        XCTAssertEqual(c.armedTapCounts, [3])
        XCTAssertEqual(c.tapCountToFire, 3)
    }

    /// A double-tap fires when double is armed, and does not when only single is.
    func testArmingSelectsWhichGestureFires() {
        let onlySingle = TapDetector(config: config(armed: [1]))
        XCTAssertEqual(onlySingle.effectiveArmedTapCounts, [1])

        let onlyDouble = TapDetector(config: config(armed: [2]))
        let triggers = feedGesture(onlyDouble, count: 2, spacingMs: 150)
        XCTAssertEqual(triggers.count, 1, "a clean double tap should fire exactly once")
        XCTAssertEqual(triggers.first?.tapCount, 2)
    }
}
