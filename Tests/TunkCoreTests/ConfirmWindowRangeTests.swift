import XCTest
@testable import TunkCore

/// The settings slider for the confirm window used to reach 100 ms, where the
/// app cannot detect a double-tap at all — `madeCoherent()` clamps
/// `maxInterTapNs` down to the confirm window, so lowering one narrows both.
///
/// This pins the measurement the new minimum is chosen from, so the slider
/// cannot quietly grow a broken range again.
final class ConfirmWindowRangeTests: XCTestCase {

    /// Spacings this project has measured on itself: desk 168-199 ms,
    /// soft 149-371 ms, lap 91-597 ms. A representative spread.
    private let spacings: [Int64] = [150, 160, 170, 180, 190, 200, 210, 230].map { $0 * 1_000_000 }

    private func detected(confirmMs: Int64) -> Int {
        var config = DetectorConfig.default
        config.confirmWindowNs = confirmMs * 1_000_000
        config.maxInterTapNs = 700_000_000          // let coherence clamp it down
        var hits = 0
        for spacing in spacings {
            var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 3_000_000_000)
            let amp = SyntheticStream.amplitude(timesThreshold: 2.0)
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs, amplitude: amp))
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + spacing, amplitude: amp))
            let d = TapDetector(config: config, armedTapCounts: [2])
            for s in stream.samples() where d.ingest(sample: s) != nil { hits += 1 }
        }
        return hits
    }

    func testTheSliderMinimumCanActuallyDetectSomething() {
        XCTAssertEqual(detected(confirmMs: 140), 0,
                       "140 ms detects nothing — this is why the range no longer reaches it")
        XCTAssertGreaterThan(detected(confirmMs: 160), 0,
                             "the shipped slider minimum must detect at least something")
        // 7 of 8, not 8: the 230 ms spacing is outside the shipped 220 ms join
        // window and is SUPPOSED to miss. Written as 8 first, which was the test
        // being wrong rather than the detector.
        XCTAssertEqual(detected(confirmMs: 220), spacings.count - 1,
                       "the shipped default catches every gesture inside its window")
        XCTAssertGreaterThan(detected(confirmMs: 240), detected(confirmMs: 220),
                             "widening the window admits the 230 ms gesture")
    }
}
