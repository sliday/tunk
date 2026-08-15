import XCTest
@testable import TunkCore
import TunkFormat

/// The admission rule at a narrow-band front end.
///
/// Two separate claims live here. The first is that the new adaptive term on the
/// re-arm line, `DSPTuning.releaseFloorMultiple`, is OFF in the shipped tuning
/// and byte-identical to the old fixed line when it is off — the same safety
/// argument the resonator stage itself carries. The second is that when it is on
/// it does what it says: the re-arm line follows the surface, and it is capped at
/// the admission line so hysteresis always has width.
///
/// The measured verdict on the mechanism is in `DSPTuning.resonatorAdmission`,
/// and it is a partial one: on `data/raw`, releaseFraction 0.48 with a 120 ms
/// debounce holds lap detection at 73/80 and takes the lap false triggers from
/// 6 to 4. The adaptive term below was swept over the same corpus and LOST —
/// every setting from 6 upward saturates at 100/123 detected with 2 false
/// triggers, which is strictly worse than the fixed pair. It stays in the code
/// off, because the negative is only readable if the knob exists.
final class AdmissionRederivationTests: XCTestCase {

    // MARK: - Off by default, and inert when off

    func testShippedTuningHasNoAdaptiveReleaseTerm() {
        XCTAssertEqual(DSPTuning.default.releaseFloorMultiple, 0,
                       "the adaptive re-arm term ships OFF; every graded number assumes it")
    }

    /// A detector with the term explicitly zeroed must fire the same triggers at
    /// the same instants as the shipped one. If this diverges, every number ever
    /// measured on the shipped chain is invalid.
    func testZeroMultipleReproducesTheShippedTriggersExactly() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        var explicitlyOff = DSPTuning.default
        explicitlyOff.releaseFloorMultiple = 0
        let shipped = TapDetector(config: .default)
        let off = TapDetector(config: .default, tuning: explicitlyOff)

        var a: [Trigger] = [], b: [Trigger] = []
        for s in samples {
            if let t = shipped.ingest(sample: s) { a.append(t) }
            if let t = off.ingest(sample: s) { b.append(t) }
        }
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a, b)
    }

    // MARK: - What the term does when it is on

    /// The point of the term: on a quiet surface the floor is far below
    /// `releaseFraction * threshold`, so the line does not move and an ordinary
    /// double tap fires exactly as before.
    func testAQuietSurfaceIsUnaffectedByTheAdaptiveTerm() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        var withTerm = DSPTuning.default
        withTerm.releaseFloorMultiple = 4
        let plain = TapDetector(config: .default)
        let adaptive = TapDetector(config: .default, tuning: withTerm)

        var a: [Trigger] = [], b: [Trigger] = []
        for s in samples {
            if let t = plain.ingest(sample: s) { a.append(t) }
            if let t = adaptive.ingest(sample: s) { b.append(t) }
        }
        XCTAssertEqual(a.count, 1, "the fixture has to fire, or this test proves nothing")
        XCTAssertEqual(a, b, "a floor 4x under the fixed line must not move the line")
    }

    /// The cap, which is not cosmetic. A release line at or above the admission
    /// line means the detector re-arms while still over the bar and declares one
    /// onset per debounce period forever. With an absurd multiple the detector
    /// must stay finite: it may fire nothing, it may fire something, but it must
    /// not produce an onset per debounce period across a quiet stretch.
    func testAnAbsurdMultipleCannotFreeRunTheDetector() {
        var runaway = DSPTuning.default
        runaway.releaseFloorMultiple = 10_000
        let stream = SyntheticStream(durationNs: 5_000_000_000, taps: [])
        let detector = TapDetector(config: .default, tuning: runaway)
        for s in stream.samples() { _ = detector.ingest(sample: s) }
        let onsets = detector.drainOnsets()
        let debouncePeriods = 5_000_000_000 / DSPTuning.default.onsetDebounceNs
        XCTAssertLessThan(onsets.count, Int(debouncePeriods),
                          "a capped release line must not re-arm into the threshold on quiet noise")
    }

    // MARK: - The re-derived operating point

    /// `resonatorAdmission()` is the measured operating point, and the numbers in
    /// it are the ones the report cites. Pinning them here means a later edit to
    /// the factory cannot silently change what the round claimed.
    func testTheRederivedOperatingPointIsTheOneThatWasMeasured() {
        let t = DSPTuning.resonatorAdmission()
        XCTAssertEqual(t.resonatorHz, 40)
        XCTAssertEqual(t.resonatorQ, 2)
        XCTAssertEqual(t.minThresholdG, 0.002)
        XCTAssertEqual(t.releaseFraction, 0.48)
        XCTAssertEqual(t.onsetDebounceNs, 120_000_000)
        XCTAssertEqual(t.releaseFloorMultiple, 0,
                       "the adaptive term lost its sweep and must not be on in the shipped point")
    }

    /// It is a FRONT END, not a config: nothing about it may leak into the
    /// shipped tuning that the desk and soft numbers were measured on.
    func testTheRederivedPointLeavesTheShippedTuningAlone() {
        _ = DSPTuning.resonatorAdmission()
        XCTAssertEqual(DSPTuning.default.resonatorHz, 0)
        XCTAssertEqual(DSPTuning.default.releaseFraction, 0.4)
        XCTAssertEqual(DSPTuning.default.onsetDebounceNs, 100_000_000)
        XCTAssertEqual(DSPTuning.default.minThresholdG, 0.02)
    }

    /// The debounce eats the bottom of the legal join window, and it charged for
    /// it. `minInterTapNs` is 100 ms and this debounce is 120 ms, so gestures
    /// with both strikes inside 120 ms cannot reach a count of two at all.
    ///
    /// That is not hypothetical: on `data/raw` it cost 13e15a group 3, whose
    /// labelled strikes are 22.957 s and 23.081 s, 124 ms apart. The re-arm dip
    /// falls inside the debounce and the second strike merges into the first, so
    /// a gesture that the shipped debounce detects is missed here. The same
    /// change recovers 13e15a group 12, where the shorter debounce paired the
    /// first strike with a ring lobe 117 ms later and fired a false trigger at an
    /// instant no label covers; at 120 ms it pairs with the real second strike
    /// 214 ms later and matches the label. One gesture out, one gesture in, lap
    /// detection unchanged at 73/80.
    func testTheDebounceEatsTheBottomOfTheLegalJoinWindow() {
        let t = DSPTuning.resonatorAdmission()
        XCTAssertGreaterThan(t.onsetDebounceNs, DetectorConfig.default.minInterTapNs,
                             "if this stops being true, the cost documented above is stale")
        XCTAssertLessThan(t.onsetDebounceNs, DetectorConfig.default.maxInterTapNs,
                          "a debounce past maxInterTap would make every gesture unfireable")
        // 124 ms is the gesture it cost. Anything at or above that is a bigger
        // bite out of the window than the one that was measured and graded.
        XCTAssertLessThanOrEqual(t.onsetDebounceNs, 124_000_000)
    }
}
