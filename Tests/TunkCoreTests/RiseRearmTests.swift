import XCTest
@testable import TunkCore
import TunkFormat

/// `DetectorConfig.rearmRiseFraction`: re-arm on a rise off the local valley
/// instead of on a return to baseline.
///
/// The knob ships at zero and these tests hold it there. Two of them prove the
/// mechanism does what it claims on a ringing surface, one proves the 100 ms
/// debounce still swallows the second lobe of a single strike with the knob on,
/// and one proves that with the knob off the detector produces the same triggers
/// on recorded data as it did before the knob existed.
///
/// The synthetic fixtures are SYNTHETIC (see SyntheticSignal.swift). The
/// recorded one is not.
final class RiseRearmTests: XCTestCase {

    // MARK: - Off is off

    func testTheKnobShipsOff() {
        XCTAssertEqual(DetectorConfig.default.rearmRiseFraction, 0)
        XCTAssertEqual(DetectorConfig.default.madeCoherent().rearmRiseFraction, 0)
    }

    /// A settings file written before this field existed must still load, and
    /// must load with the rise path off rather than silently switched on.
    func testAConfigFileWithoutTheFieldLoadsOff() throws {
        let json = Data(#"{"sensitivity":1.0,"defaultThreshold":0.032}"#.utf8)
        let cfg = try JSONDecoder().decode(DetectorConfig.self, from: json)
        XCTAssertEqual(cfg.rearmRiseFraction, 0)

        var on = DetectorConfig.default
        on.rearmRiseFraction = 0.4
        let round = try JSONDecoder().decode(DetectorConfig.self,
                                             from: JSONEncoder().encode(on))
        XCTAssertEqual(round.rearmRiseFraction, 0.4)
    }

    /// A negative or NaN rise is not a rise. Off is the safe reading, because
    /// the alternative re-arms on the first sample past the debounce.
    func testNonsenseValuesClampToOff() {
        for bad in [-0.5, Double.nan, -Double.infinity] {
            var cfg = DetectorConfig.default
            cfg.rearmRiseFraction = bad
            XCTAssertEqual(cfg.madeCoherent().rearmRiseFraction, 0)
            XCTAssertTrue(cfg.coherenceIssues.contains { $0.field == "rearmRiseFraction" })
        }
    }

    /// The shipped detector, off, against recorded soft-surface taps. The
    /// spacings are the ones it produced before this field was added; the whole
    /// corpus was checked the same way with `tunk-score run --data data/raw`
    /// (101/123 detected, 104 triggers, 3 false, p95 225.2 ms, identical either
    /// side of the change).
    func testOffReproducesTheRecordedBaseline() throws {
        let dir = URL(fileURLWithPath:
            "/Users/stas/Playground/tunk/data/raw/tap_deck__soft__20260814-104124__fe9b8c")
        let session = try Session(directory: dir)
        let samples = try session.samples()
        let inputs = try session.inputs().map(\.event)

        let baseline = TapDetector.replay(samples: samples, inputs: inputs,
                                          config: .default).triggers
        let spacingsMs = baseline.map { ($0.tapOnsets[1] - $0.tapOnsets[0] + 500_000) / 1_000_000 }
        XCTAssertEqual(spacingsMs, [205, 163, 175, 181, 201, 149, 148, 170, 219, 189,
                                    179, 161, 164, 169, 166, 173, 158, 115, 109, 173])

        var explicitlyOff = DetectorConfig.default
        explicitlyOff.rearmRiseFraction = 0
        let same = TapDetector.replay(samples: samples, inputs: inputs,
                                      config: explicitlyOff).triggers
        XCTAssertEqual(same, baseline)
    }

    // MARK: - The mechanism

    /// A surface that rings for hundreds of milliseconds. The first strike keeps
    /// the envelope above the release line for longer than the gap to the second
    /// strike, so the shipped rule is still disarmed when the second one lands.
    private func ringingDouble(spacingNs: Int64 = 160_000_000) -> [AccelSample] {
        let base = SyntheticStream.leadInNs
        var stream = SyntheticStream(durationNs: base + spacingNs + 2_000_000_000)
        stream.taps = [
            .init(tNs: base, amplitude: SyntheticStream.amplitude(timesThreshold: 3.0),
                  decaySeconds: 0.15),
            .init(tNs: base + spacingNs,
                  amplitude: SyntheticStream.amplitude(timesThreshold: 1.5),
                  decaySeconds: 0.15),
        ]
        return stream.samples()
    }

    func testOffTheDetectorIsDeafToTheSecondStrike() {
        let result = TapDetector.replay(samples: ringingDouble(), inputs: [],
                                        config: .default)
        XCTAssertEqual(result.onsets.count, 1, "the tail never fell back under the release line")
        XCTAssertTrue(result.triggers.isEmpty)
    }

    func testOnTheSecondStrikeIsHeardAndTheGestureFires() {
        var cfg = DetectorConfig.default
        cfg.rearmRiseFraction = 0.4
        let result = TapDetector.replay(samples: ringingDouble(), inputs: [], config: cfg)
        XCTAssertEqual(result.onsets.count, 2)
        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertEqual(result.triggers.first?.tapCount, 2)
    }

    /// One tap is two lobes: peak, trough at +12.6 ms, second lobe at +26.4 ms
    /// and 80 % of the original peak (measured, see notes/BAR_ASSESSMENT.md).
    /// The rise re-arm must not turn that into two onsets — `onsetDebounceNs`
    /// applies to it exactly as it does to the release rule.
    func testTheSecondLobeOfOneStrikeIsStillOneOnset() {
        let base = SyntheticStream.leadInNs
        var stream = SyntheticStream(durationNs: base + 2_000_000_000)
        stream.taps = [
            .init(tNs: base, amplitude: SyntheticStream.amplitude(timesThreshold: 3.0),
                  decaySeconds: 0.15),
            .init(tNs: base + 26_400_000,
                  amplitude: SyntheticStream.amplitude(timesThreshold: 2.4),
                  decaySeconds: 0.15),
        ]
        for p in [0.0, 0.2, 0.4, 1.0] {
            var cfg = DetectorConfig.default
            cfg.rearmRiseFraction = p
            let result = TapDetector.replay(samples: stream.samples(), inputs: [], config: cfg)
            XCTAssertEqual(result.onsets.count, 1, "rearmRiseFraction \(p)")
            XCTAssertTrue(result.triggers.isEmpty, "rearmRiseFraction \(p)")
        }
    }
}
