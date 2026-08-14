import XCTest
@testable import TunkCore
import TunkFormat

/// The tail model: re-arm against a decay model of the last strike instead of
/// against a fixed release line. Shipped OFF — these tests fix what the knob
/// does when it is off (nothing at all) and what it does when it is on.
///
/// Measured result on data/raw, and the reason it ships off: see
/// notes/TAIL_MODEL.md.
final class TailModelTests: XCTestCase {

    private var enabled: DetectorConfig {
        var c = DetectorConfig.default
        c.tailRearmFraction = 1.0
        c.tailOnsetFraction = 1.2
        c.tailDecayTauNs = 90_000_000
        return c
    }

    // MARK: - Off is off

    func testOffIsTheShippedDetectorOnSyntheticGestures() {
        let (stream, _) = SyntheticStream.gesture(
            count: 2, spacingNs: 180_000_000,
            amplitude: SyntheticStream.amplitude(timesThreshold: 3),
            wobbleAmplitude: 0.05)
        let samples = stream.samples()

        // Every tail knob set to something loud, with the mechanism switch at
        // zero. Nothing may change.
        var off = DetectorConfig.default
        off.tailRearmFraction = 0
        off.tailOnsetFraction = 2.0
        off.tailDecayTauNs = 400_000_000

        let base = TapDetector.replayGroups(samples: samples, inputs: [], config: .default)
        let same = TapDetector.replayGroups(samples: samples, inputs: [], config: off)
        XCTAssertEqual(base.triggers, same.triggers)
        XCTAssertEqual(base.onsets, same.onsets)
        XCTAssertEqual(base.groups, same.groups)
        XCTAssertFalse(base.triggers.isEmpty, "the fixture has to fire, or this proves nothing")
    }

    func testOffIsTheShippedDetectorOnEveryRecordedTapSession() throws {
        let root = TailModelDiagnosisTests.dataRoot()
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()
        XCTAssertFalse(dirs.isEmpty)

        var off = DetectorConfig.default
        off.tailRearmFraction = 0
        off.tailOnsetFraction = 2.0
        off.tailDecayTauNs = 400_000_000

        for name in dirs {
            let session = try Session(directory: URL(fileURLWithPath: root + name))
            let samples = try session.samples()
            let inputs = try session.inputs().map(\.event)
            let base = TapDetector.replayGroups(samples: samples, inputs: inputs, config: .default)
            let same = TapDetector.replayGroups(samples: samples, inputs: inputs, config: off)
            XCTAssertEqual(base.triggers, same.triggers, name)
            XCTAssertEqual(base.onsets, same.onsets, name)
        }
    }

    // MARK: - On does what it claims

    /// A single strike whose ring lasts far longer than the gesture. The
    /// envelope never falls back under `releaseFraction * threshold` before the
    /// second strike lands, so the shipped detector is still disarmed when it
    /// arrives: one onset, no trigger. This is the SYNTHETIC form of the 12 lap
    /// and 3 soft gestures the diagnosis test counts as deaf.
    func testATailTooLongForTheAbsoluteReleaseLineIsDeafWithoutTheModel() {
        let samples = ringingGesture()
        let off = TapDetector.replayGroups(samples: samples, inputs: [], config: .default)
        XCTAssertEqual(off.onsets.filter { !$0.suppressedByGate }.count, 1,
                       "the second strike must be missed, or the fixture is not deaf")
        XCTAssertTrue(off.triggers.isEmpty)
    }

    func testTheModelHearsTheSecondStrikeOnThatSameTail() {
        let samples = ringingGesture()
        let on = TapDetector.replayGroups(samples: samples, inputs: [], config: enabled)
        XCTAssertEqual(on.onsets.filter { !$0.suppressedByGate }.count, 2,
                       "the model must recover exactly the second strike, not the ring as well")
        XCTAssertEqual(on.triggers.count, 1)
    }

    /// The other half of the mechanism. Re-arming early without a guard means
    /// the tail declares itself the moment the detector listens again, which is
    /// how the model turns a double into an unbound triple.
    func testWithoutTheOnsetGuardTheTailDeclaresItself() {
        var noGuard = enabled
        noGuard.tailOnsetFraction = 0
        let out = TapDetector.replayGroups(samples: ringingGesture(), inputs: [], config: noGuard)
        let second = SyntheticStream.leadInNs + 200_000_000
        let onsets = out.onsets.filter { !$0.suppressedByGate }.map(\.tNs)
        XCTAssertGreaterThanOrEqual(onsets.count, 2)
        // The recovered onset is the ring crossing the bar the instant the
        // detector listens again, not the strike 200 ms in.
        XCTAssertTrue(onsets.contains { $0 < second - 50_000_000 && $0 > onsets[0] },
                      "expected a phantom onset on the tail, got \(onsets)")

        // With the guard in place the recovered onset is the strike itself.
        let guarded = TapDetector.replayGroups(samples: ringingGesture(), inputs: [], config: enabled)
        let guardedOnsets = guarded.onsets.filter { !$0.suppressedByGate }.map(\.tNs)
        XCTAssertEqual(guardedOnsets.count, 2)
        XCTAssertLessThan(abs(guardedOnsets[1] - second), 20_000_000)
    }

    /// Two lobes of ONE strike are still one onset: the debounce gates re-arming
    /// before the tail model is ever consulted.
    func testTheModelStillSwallowsTheSecondLobeOfOneStrike() {
        var stream = SyntheticStream(durationNs: 3_000_000_000, taps: [
            SyntheticStream.Tap(tNs: SyntheticStream.leadInNs,
                                amplitude: SyntheticStream.amplitude(timesThreshold: 4)),
            // The measured second lobe: +26 ms, 80 % of the first.
            SyntheticStream.Tap(tNs: SyntheticStream.leadInNs + 26_400_000,
                                amplitude: SyntheticStream.amplitude(timesThreshold: 3.2)),
        ])
        stream.noiseAmplitude = 0.002
        let out = TapDetector.replayGroups(samples: stream.samples(), inputs: [], config: enabled)
        XCTAssertEqual(out.onsets.filter { !$0.suppressedByGate }.count, 1)
        XCTAssertTrue(out.triggers.isEmpty)
    }

    // MARK: - Config hygiene

    func testANonsenseFractionTurnsTheModelOffRatherThanOn() {
        var c = DetectorConfig.default
        c.tailRearmFraction = -1
        c.tailOnsetFraction = .nan
        XCTAssertEqual(c.madeCoherent().tailRearmFraction, 0)
        XCTAssertEqual(c.madeCoherent().tailOnsetFraction, 0)
        XCTAssertFalse(c.madeCoherent().tailModelEnabled)
        XCTAssertEqual(c.coherenceIssues.count, 2)
    }

    func testTheKnobsSurviveASettingsRoundTrip() throws {
        var c = DetectorConfig.default
        c.tailRearmFraction = 0.75
        c.tailOnsetFraction = 1.25
        c.tailDecayTauNs = 175_000_000
        let back = try JSONDecoder().decode(DetectorConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    /// A settings file written before these keys existed still loads, and loads
    /// with the model off.
    func testALegacySettingsFileLoadsWithTheModelOff() throws {
        let json = Data(#"{"sensitivity":1.0,"defaultThreshold":0.032,"tapCountToFire":2}"#.utf8)
        let c = try JSONDecoder().decode(DetectorConfig.self, from: json)
        XCTAssertEqual(c.tailRearmFraction, 0)
        XCTAssertFalse(c.tailModelEnabled)
    }

    // MARK: - Fixture

    /// SYNTHETIC. One strike that rings for ~90 ms of time constant, then a
    /// second strike 200 ms later at half the first one's amplitude.
    private func ringingGesture() -> [AccelSample] {
        var stream = SyntheticStream(durationNs: 3_500_000_000, taps: [
            SyntheticStream.Tap(tNs: SyntheticStream.leadInNs,
                                amplitude: SyntheticStream.amplitude(timesThreshold: 8),
                                decaySeconds: 0.09),
            SyntheticStream.Tap(tNs: SyntheticStream.leadInNs + 200_000_000,
                                amplitude: SyntheticStream.amplitude(timesThreshold: 4),
                                decaySeconds: 0.004),
        ])
        stream.noiseAmplitude = 0.002
        return stream.samples()
    }
}
