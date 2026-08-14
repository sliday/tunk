import XCTest
@testable import TunkCore
import TunkFormat

/// `DetectorConfig.tailRearmNs`: re-arm on the clock alone, so a second strike
/// that lands on a still-ringing tail is heard.
///
/// The synthetic fixtures here prove the state machine. The two real-data tests
/// pin the measured result on `data/raw`, because the whole point of the knob is
/// a number on recordings, not a shape in a formula.
final class DetectorTailRearmTests: XCTestCase {

    // MARK: - Off by default, and inert when off

    func testShippedDefaultsLeaveTheMechanismOff() {
        let d = DetectorConfig.default
        XCTAssertEqual(d.tailRearmNs, 0, "the knob must ship off")
        XCTAssertEqual(d.tailRearmDipFraction, 0)
        XCTAssertEqual(d.tailRearmPeakFraction, 0)
    }

    /// The guards must not be able to change anything on their own. Otherwise
    /// "off" would depend on three numbers being right instead of one.
    func testGuardsAreInertWhileTheMechanismIsOff() throws {
        var armed = DetectorConfig.default
        armed.tailRearmDipFraction = 0.5
        armed.tailRearmPeakFraction = 0.8

        for name in try Self.tapDeckNames() {
            let samples = try Self.samples(named: name)
            let shipped = TapDetector.replay(samples: samples, inputs: [], config: .default)
            let withGuards = TapDetector.replay(samples: samples, inputs: [], config: armed)
            XCTAssertEqual(shipped.triggers, withGuards.triggers, "triggers moved in \(name)")
            XCTAssertEqual(shipped.onsets, withGuards.onsets, "onsets moved in \(name)")
        }
    }

    /// Same replay twice, with the mechanism on. The detector reads no clock, so
    /// a config that changes when it listens must not make it non-deterministic.
    func testTailRearmStaysDeterministic() throws {
        var on = DetectorConfig.default
        on.tailRearmNs = 200_000_000
        let samples = try Self.samples(named: Self.lapDeck)
        let first = TapDetector.replay(samples: samples, inputs: [], config: on)
        let second = TapDetector.replay(samples: samples, inputs: [], config: on)
        XCTAssertEqual(first.triggers, second.triggers)
        XCTAssertEqual(first.onsets, second.onsets)
    }

    // MARK: - The deafness the knob exists for

    /// A SYNTHETIC gesture on a chassis that rings for a third of a second: the
    /// envelope never returns under the release line between the two strikes, so
    /// the shipped rule is still disarmed when the second one lands.
    private func ringingGesture(secondStrike: Bool) -> [AccelSample] {
        let amplitude = SyntheticStream.amplitude(timesThreshold: 3.0)
        var taps = [SyntheticStream.Tap(tNs: SyntheticStream.leadInNs,
                                        amplitude: amplitude,
                                        decaySeconds: 0.15)]
        if secondStrike {
            taps.append(SyntheticStream.Tap(tNs: SyntheticStream.leadInNs + 180_000_000,
                                            amplitude: amplitude,
                                            decaySeconds: 0.004))
        }
        let stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 2_000_000_000,
                                     taps: taps)
        return stream.samples()
    }

    func testTheShippedRuleIsDeafToASecondStrikeOnATail() {
        let out = TapDetector.replay(samples: ringingGesture(secondStrike: true),
                                     inputs: [], config: .default)
        XCTAssertEqual(out.onsets.count, 1,
                       "the shipped rule should hear only the first strike here")
        XCTAssertTrue(out.triggers.isEmpty)
    }

    func testTailRearmHearsTheSecondStrikeAndFires() {
        var on = DetectorConfig.default
        on.tailRearmNs = 150_000_000
        let out = TapDetector.replay(samples: ringingGesture(secondStrike: true),
                                     inputs: [], config: on)
        XCTAssertEqual(out.onsets.count, 2, "the second strike must now be heard")
        XCTAssertEqual(out.triggers.count, 1, "and the pair must fire once")
    }

    /// The objection, measured rather than argued: re-arm early enough and the
    /// tail crosses its own threshold. This is why the sweep bottoms out at
    /// 60 ms with pooled detection at 39.84 % — deafness goes to zero and the
    /// phantoms it lets in abort the groups.
    func testAShortRearmDeclaresPhantomOnsetsOnTheTailAlone() {
        var on = DetectorConfig.default
        on.tailRearmNs = 60_000_000
        let samples = ringingGesture(secondStrike: false)
        XCTAssertEqual(TapDetector.replay(samples: samples, inputs: [], config: .default)
                        .onsets.count, 1,
                       "one strike is one onset under the shipped rule")
        XCTAssertGreaterThan(TapDetector.replay(samples: samples, inputs: [], config: on)
                        .onsets.count, 1,
                       "a 60 ms re-arm should read the ring as further strikes")
    }

    /// The guard that stops it, on the same fixture: ask a crossing declared on
    /// a tail to be a decent fraction of the strike that caused the tail.
    func testThePeakGuardSuppressesThoseTailOnsets() {
        var on = DetectorConfig.default
        on.tailRearmNs = 60_000_000
        on.tailRearmPeakFraction = 0.9
        let out = TapDetector.replay(samples: ringingGesture(secondStrike: false),
                                     inputs: [], config: on)
        XCTAssertEqual(out.onsets.count, 1, "the decayed tail must not clear the peak guard")
    }

    // MARK: - What it is worth on the recordings

    /// Measured 2026-08-14 on `data/raw`, four lap tap decks: 62 triggers with
    /// the knob off, 63 with it at 200 ms, and one more labelled gesture
    /// detected in a session whose trigger count did not move (the detector
    /// heard the true strike ~50 ms earlier instead of a later ring peak).
    ///
    /// Pinned as equalities so a later change that quietly spends this has to
    /// say so here.
    func testMeasuredLapTriggerCounts() throws {
        var on = DetectorConfig.default
        on.tailRearmNs = 200_000_000

        var off = 0, tail = 0
        for name in try Self.tapDeckNames() where name.contains("__lap__") {
            let samples = try Self.samples(named: name)
            off += TapDetector.replay(samples: samples, inputs: [], config: .default).triggers.count
            tail += TapDetector.replay(samples: samples, inputs: [], config: on).triggers.count
        }
        XCTAssertEqual(off, 62)
        XCTAssertEqual(tail, 63)
    }

    /// Desk and soft must not pay for the lap gain. Both decks fire exactly as
    /// many times with the knob on as with it off.
    func testDeskAndSoftAreUnmovedAt200ms() throws {
        var on = DetectorConfig.default
        on.tailRearmNs = 200_000_000
        for name in try Self.tapDeckNames() where !name.contains("__lap__") {
            let samples = try Self.samples(named: name)
            let off = TapDetector.replay(samples: samples, inputs: [], config: .default)
            let tail = TapDetector.replay(samples: samples, inputs: [], config: on)
            XCTAssertEqual(off.triggers.count, tail.triggers.count, "trigger count moved in \(name)")
        }
    }

    // MARK: - Coherence

    func testNonsenseValuesAreClampedAndReported() {
        var c = DetectorConfig.default
        c.tailRearmNs = -1
        c.tailRearmDipFraction = -0.5
        c.tailRearmPeakFraction = .nan
        let coherent = c.madeCoherent()
        XCTAssertEqual(coherent.tailRearmNs, 0)
        XCTAssertEqual(coherent.tailRearmDipFraction, 0)
        XCTAssertEqual(coherent.tailRearmPeakFraction, 0)
        let fields = Set(c.coherenceIssues.map(\.field))
        XCTAssertTrue(fields.contains("tailRearmNs"))
        XCTAssertTrue(fields.contains("tailRearmDipFraction"))
        XCTAssertTrue(fields.contains("tailRearmPeakFraction"))
    }

    func testSettingsFileWithoutTheKeysStillLoadsOff() throws {
        let json = Data(#"{"sensitivity": 1.0, "defaultThreshold": 0.032}"#.utf8)
        let decoded = try JSONDecoder().decode(DetectorConfig.self, from: json)
        XCTAssertEqual(decoded.tailRearmNs, 0)
        XCTAssertEqual(decoded.tailRearmDipFraction, 0)
        XCTAssertEqual(decoded.tailRearmPeakFraction, 0)
    }

    func testTheKeysRoundTripThroughCodable() throws {
        var c = DetectorConfig.default
        c.tailRearmNs = 200_000_000
        c.tailRearmDipFraction = 0.3
        c.tailRearmPeakFraction = 0.9
        let back = try JSONDecoder().decode(DetectorConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.tailRearmNs, 200_000_000)
        XCTAssertEqual(back.tailRearmDipFraction, 0.3)
        XCTAssertEqual(back.tailRearmPeakFraction, 0.9)
    }

    // MARK: - Fixtures

    static let lapDeck = "tap_deck__lap__20260814-104745__13e15a"

    static func tapDeckNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: ArmStateDiagnosisTests.rawRoot)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()
    }

    static func samples(named name: String) throws -> [AccelSample] {
        let url = URL(fileURLWithPath: ArmStateDiagnosisTests.rawRoot + name)
        return try Session(directory: url).samples()
    }
}
