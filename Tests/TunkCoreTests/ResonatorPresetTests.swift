import XCTest
@testable import TunkCore

/// The resonator is a preset, not the default. A critic ruled it should ship on;
/// acting on that ruling is the owner's call, and this suite is what catches the
/// default moving by accident in the meantime.
final class ResonatorPresetTests: XCTestCase {

    func testTheShippedDefaultStillHasNoResonator() {
        XCTAssertEqual(DSPTuning.default.resonatorHz, 0,
                       "the shipped front end must stay unfiltered until the owner says otherwise")
        XCTAssertEqual(DSPTuning.default.minThresholdG, DSPTuning.default.minThresholdG)
        XCTAssertNotEqual(DSPTuning.default.resonatorHz, DSPTuning.resonatorFrontEnd.resonatorHz)
    }

    /// The preset has to match the operating point the critic graded, to the
    /// digit. A drift here would mean the switch offers something nobody scored.
    func testThePresetIsTheGradedOperatingPoint() {
        let r = DSPTuning.resonatorFrontEnd
        XCTAssertEqual(r.resonatorHz, 40)
        XCTAssertEqual(r.resonatorQ, 2)
        XCTAssertEqual(r.minThresholdG, 0.002)
    }

    /// Everything outside the front end must be untouched, or the switch is
    /// carrying changes that were never graded with it.
    func testThePresetChangesNothingElse() {
        let r = DSPTuning.resonatorFrontEnd
        let d = DSPTuning.default
        XCTAssertEqual(r.sampleRateHz, d.sampleRateHz)
        XCTAssertEqual(r.highPassHz, d.highPassHz)
        XCTAssertEqual(r.onsetDebounceNs, d.onsetDebounceNs)
        XCTAssertEqual(r.releaseFraction, d.releaseFraction)
        XCTAssertEqual(r.preGateNs, d.preGateNs)
        XCTAssertEqual(r.noiseSnrMultiple, d.noiseSnrMultiple)
        XCTAssertFalse(r.pairRescueEnabled, "the two switches are independent")
    }
}
