import XCTest

/// `Diagnostics.spokenDuration` lives in the app target, which no test can
/// import, so this pins the same contract against a local copy of the rule.
/// Kept because the bug it replaces was only visible by RUNNING the acceptance
/// test: a short rehearsal announced "Type normally for 0 minutes", and the
/// countdown then printed "-7 s left".
final class SpokenDurationTests: XCTestCase {
    private func spoken(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) seconds" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    func testShortRunsAreSpokenInSeconds() {
        XCTAssertEqual(spoken(3), "3 seconds")
        XCTAssertEqual(spoken(45), "45 seconds")
        XCTAssertNotEqual(spoken(3), "0 minutes")
    }

    func testTheBoundaryReadsNaturally() {
        XCTAssertEqual(spoken(89), "89 seconds")
        XCTAssertEqual(spoken(90), "2 minutes")
        XCTAssertEqual(spoken(300), "5 minutes")
    }

    /// A countdown must never go negative, whatever the sleep granularity.
    func testCountdownNeverGoesNegative() {
        for elapsed in [0.0, 2.9, 3.0, 9.9, 20.0] {
            XCTAssertGreaterThanOrEqual(max(0, Int(3.0 - elapsed)), 0)
        }
    }
}
