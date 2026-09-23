import XCTest
@testable import TunkCore
@testable import TunkEmit

/// Regression tests for defects found in the September 2026 code review.
/// Each test names the defect it pins, so a failure says what came back.
final class ReviewFixesTests: XCTestCase {

    private var debounceNs: Int64 { DSPTuning.default.onsetDebounceNs }

    // MARK: - madeCoherent

    /// A confirm window under the debounce left the minimum clamped below the
    /// floor that same pass had just enforced. The result failed its own
    /// isCoherent, and no double tap could ever join.
    func testAConfirmWindowUnderTheDebounceResolvesToACoherentBand() {
        var c = DetectorConfig.default
        c.confirmWindowNs = 50_000_000
        let r = c.madeCoherent()
        XCTAssertTrue(r.isCoherent, "\(r.coherenceIssues)")
        XCTAssertGreaterThanOrEqual(r.minInterTapNs, debounceNs)
        XCTAssertLessThanOrEqual(r.minInterTapNs, r.maxInterTapNs)
        XCTAssertLessThanOrEqual(r.maxInterTapNs, r.confirmWindowNs)
    }

    func testAMaximumUnderTheDebounceResolvesToACoherentBand() {
        var c = DetectorConfig.default
        c.maxInterTapNs = 50_000_000
        let r = c.madeCoherent()
        XCTAssertTrue(r.isCoherent, "\(r.coherenceIssues)")
        XCTAssertGreaterThanOrEqual(r.minInterTapNs, debounceNs)
        XCTAssertLessThanOrEqual(r.minInterTapNs, r.maxInterTapNs)
    }

    /// The doc comment promises idempotence. The bug lived in the ordering
    /// between clamps, so sweep a grid rather than trust one value.
    func testMadeCoherentIsIdempotentAcrossShortWindows() {
        for confirmMs in stride(from: 0, through: 300, by: 10) {
            for maxMs in stride(from: 0, through: 300, by: 25) {
                var c = DetectorConfig.default
                c.confirmWindowNs = Int64(confirmMs) * 1_000_000
                c.maxInterTapNs = Int64(maxMs) * 1_000_000
                let once = c.madeCoherent()
                XCTAssertTrue(once.isCoherent,
                              "confirm \(confirmMs) ms, max \(maxMs) ms: \(once.coherenceIssues)")
                XCTAssertEqual(once.madeCoherent(), once,
                               "not idempotent at confirm \(confirmMs) ms, max \(maxMs) ms")
            }
        }
    }

    func testTheShippedDefaultsAreUntouched() {
        let d = DetectorConfig.default
        XCTAssertTrue(d.isCoherent, "\(d.coherenceIssues)")
        XCTAssertEqual(d.madeCoherent(), d)
    }

    // MARK: - Onset ceiling

    /// At 0.7 g a raised sensitivity can put the threshold at or above the
    /// ceiling. Every onset is then discarded as too large, the detector goes
    /// deaf, and no coherence issue said so.
    func testAThresholdAtOrAboveTheCeilingIsReportedAndLifted() {
        var c = DetectorConfig.default
        c.sensitivity = 25                        // 0.032 g x 25 = 0.8 g, over 0.7 g
        XCTAssertGreaterThanOrEqual(c.effectiveThreshold, c.onsetCeilingG ?? .infinity)
        XCTAssertFalse(c.isCoherent, "a deaf config must be reported, not accepted silently")
        let r = c.madeCoherent()
        XCTAssertTrue(r.isCoherent, "\(r.coherenceIssues)")
        XCTAssertGreaterThan(r.onsetCeilingG ?? 0, r.effectiveThreshold)
    }

    func testANonPositiveCeilingFallsBackToTheDefault() {
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            var c = DetectorConfig.default
            c.onsetCeilingG = bad
            XCTAssertEqual(c.madeCoherent().onsetCeilingG, DetectorConfig.default.onsetCeilingG,
                           "ceiling \(bad)")
        }
    }

    /// End to end through the real detector, which applies madeCoherent in its
    /// initialiser. Before the fix this fired nothing: a 3 g double tap crosses
    /// the raised threshold and was then discarded as over the 0.7 g ceiling.
    func testARaisedSensitivityNoLongerDeafensTheDetector() {
        var c = DetectorConfig.default
        c.sensitivity = 25
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000, amplitude: 3.0)
        let result = TapDetector.replay(samples: stream.samples(), inputs: [], config: c)
        XCTAssertEqual(result.triggers.count, 1,
                       "a strong double tap was discarded as too large")
    }

    // MARK: - Binding decode

    private func decodeBindings(_ json: String) throws -> ActionBindings {
        try JSONDecoder().decode(ActionBindings.self, from: Data(json.utf8))
    }

    /// One undecodable entry threw for the whole set, and `restored` fell back
    /// to the default hotkey, silently dropping every binding that did decode.
    func testOneUndecodableEntryKeepsTheOthers() throws {
        let json = #"{"1":{"kind":"shortcut","name":"Lights"},"2":{"kind":"not-a-kind-yet"}}"#
        let b = try decodeBindings(json)
        guard case .shortcut = b[1] else { return XCTFail("the good binding was dropped: \(b[1])") }
        guard case .none = b[2] else { return XCTFail("the bad entry should read as unbound") }
    }

    /// Nothing decodes: still throw, so `restored` falls back to the legacy
    /// keys or the default instead of leaving every count unbound.
    func testEveryEntryUndecodableStillThrows() {
        XCTAssertThrowsError(try decodeBindings(#"{"1":{"kind":"x"},"2":{"kind":"y"}}"#))
    }

    func testRestoredKeepsTheGoodBindingFromAPartlyBadBlob() {
        let json = #"{"1":{"kind":"shortcut","name":"Lights"},"2":{"kind":"not-a-kind-yet"}}"#
        let b = ActionBindings.restored(bindingsData: Data(json.utf8),
                                        actionData: nil, legacyHotkeyText: nil)
        guard case .shortcut = b[1] else { return XCTFail("restored discarded the good binding") }
    }

    // MARK: - Hotkey glyphs

    /// The panel prints Fn as the globe glyph. Pasting that back failed with
    /// "unknown key", although every other modifier's glyph parsed.
    func testTheFnGlyphParsesBack() throws {
        let spec = try HotkeySpec(parsing: "Fn+A")
        XCTAssertEqual(try HotkeySpec(parsing: spec.symbolicDescription), spec)
    }
}
