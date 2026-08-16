import XCTest
@testable import TunkCore

/// The panel names any tuning that is not the shipped one. The logic lives in
/// TunkApp, which no test can import, so the truth table it depends on is pinned
/// here against the presets themselves.
///
/// The case that matters most is the negative one: a false alarm on the shipped
/// default would teach an owner to ignore the line, and then it protects nobody.
final class ExperimentBannerTests: XCTestCase {

    func testTheShippedDefaultDiffersFromNeitherPresetByAccident() {
        let d = DSPTuning.default
        XCTAssertEqual(d.resonatorHz, 0)
        XCTAssertFalse(d.pairRescueEnabled)
    }

    func testEachPresetDiffersFromTheDefaultInExactlyItsOwnWay() {
        let d = DSPTuning.default

        let r = DSPTuning.resonatorFrontEnd
        XCTAssertNotEqual(r.resonatorHz, d.resonatorHz, "the resonator must be nameable")
        XCTAssertEqual(r.pairRescueEnabled, d.pairRescueEnabled,
                       "the resonator must not silently enable lap pairing")

        let p = DSPTuning.lapPairingExperiment
        XCTAssertNotEqual(p.pairRescueEnabled, d.pairRescueEnabled, "pairing must be nameable")
        XCTAssertEqual(p.resonatorHz, d.resonatorHz,
                       "lap pairing must not silently enable the resonator")
    }

    /// Composing both switches has to leave both differences visible, or the
    /// banner names one experiment while two are running.
    func testBothTogetherRemainSeparatelyVisible() {
        var both = DSPTuning.lapPairingExperiment
        let r = DSPTuning.resonatorFrontEnd
        both.resonatorHz = r.resonatorHz
        both.resonatorQ = r.resonatorQ
        both.minThresholdG = r.minThresholdG

        XCTAssertNotEqual(both.resonatorHz, DSPTuning.default.resonatorHz)
        XCTAssertTrue(both.pairRescueEnabled)
    }
}
