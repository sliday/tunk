import XCTest
@testable import TunkCore

/// The two false-trigger cases that kept `promising/m26-polarization` off the
/// ship list, and the guard that closes them.
///
/// M26's candidate bar is anchored to the LIVE THRESHOLD and to nothing else, so
/// a crest qualifies as a second tap at half the bar no matter how small it is
/// beside the contact that produced it. Both failing cases exploit exactly that:
///
///  1. A lone knock with a lap-like ring-down. At tau 35 ms a 0.5 g knock is at
///     exp(-100/35) = 5.7 % of its own peak 100 ms later, which is still 0.89x
///     the 0.032 g threshold. Half-bar clears it comfortably; a twentieth of the
///     anchor does not clear a 0.3 anchor floor.
///  2. A hard contact at 3x the bar and a SEPARATE weak contact at 0.6x, 110-200
///     ms later. No ring involved at all: the ratio is 0.2.
///
/// Measured on data/raw, the 17 train gestures M26 rescues sit at crest-to-anchor
/// ratios 0.38-1.33, p50 0.53. The two populations do not overlap, which is what
/// makes `pairRescueAnchorFraction` possible at all; the numbers are in the
/// round's report.
final class PairRescueAnchorFloorTests: XCTestCase {

    /// M26 exactly as graded: candidateFraction 0.5, cosMin 0.7, rank by rect.
    private static func m26(anchorFraction: Double) -> DSPTuning {
        var t = DSPTuning.default
        t.pairRescueEnabled = true
        t.pairRescueAnchorFraction = anchorFraction
        return t
    }

    private static let floor = 0.30

    private func fired(_ stream: SyntheticStream, tuning: DSPTuning) -> Int {
        TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                 config: .default, tuning: tuning,
                                 armedTapCounts: [2]).triggers.count
    }

    // MARK: - Fixtures

    /// `count` isolated knocks, one every `spacingNs`, each given a ring-down of
    /// time constant `decayMs`. Nothing else is in the stream: every trigger here
    /// is a lone knock that became a double-tap.
    private func loneKnockStorm(decayMs: Double, amplitude: Double,
                                spacingNs: Int64 = 1_200_000_000,
                                count: Int = 50) -> SyntheticStream {
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs
                                     + Int64(count) * spacingNs + 2_000_000_000)
        for i in 0..<count {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * spacingNs,
                                     amplitude: amplitude,
                                     decaySeconds: decayMs * 1e-3))
        }
        return stream
    }

    /// `count` events, each a hard contact at 3x the bar followed `gapMs` later
    /// by a SEPARATE weak contact at 0.6x. Both keep the default 4 ms ring, so
    /// the second crest is a real second contact and not anyone's ring-down.
    /// Events are 3 s apart, well past the refractory.
    private func hardThenWeak(gapMs: Double, count: Int = 30) -> SyntheticStream {
        let hard = SyntheticStream.amplitude(timesThreshold: 3.0)
        let weak = SyntheticStream.amplitude(timesThreshold: 0.6)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs
                                     + Int64(count) * 3_000_000_000 + 2_000_000_000)
        for i in 0..<count {
            let t0 = SyntheticStream.leadInNs + Int64(i) * 3_000_000_000
            stream.taps.append(.init(tNs: t0, amplitude: hard))
            stream.taps.append(.init(tNs: t0 + Int64(gapMs * 1e6), amplitude: weak))
        }
        return stream
    }

    /// Every rescue a run makes, with the ratio that decides whether the floor
    /// keeps it. The sink is torn down again so no other test inherits it.
    private func rescues(_ stream: SyntheticStream, tuning: DSPTuning) -> [PairRescueTrace.Record] {
        var out: [PairRescueTrace.Record] = []
        PairRescueTrace.sink = { out.append($0) }
        defer { PairRescueTrace.sink = nil }
        _ = TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                     config: .default, tuning: tuning, armedTapCounts: [2])
        return out
    }

    // MARK: - The measurement the floor rests on

    /// Publish the storm side of the distribution. The train side comes from
    /// `data/raw` and cannot live in a unit test: 19 rescues, ratios 0.38-1.33,
    /// p50 0.53, measured with `TUNK_RESCUE_TRACE=1 tunk-score explain`.
    ///
    /// If these two ever overlap, the guard is unjustifiable and this test says
    /// so before the sweeps below have a chance to look reassuring.
    func testStormRescuesSitFarBelowEveryRescueTheTrainCorpusMakes() {
        var case1: [Double] = []
        for decayMs in [30.0, 35, 40, 60, 80] {
            case1 += rescues(loneKnockStorm(decayMs: decayMs, amplitude: 0.5),
                             tuning: Self.m26(anchorFraction: 0)).map(\.ratio)
        }
        var case2: [Double] = []
        for gapMs in [110.0, 150, 200] {
            case2 += rescues(hardThenWeak(gapMs: gapMs),
                             tuning: Self.m26(anchorFraction: 0)).map(\.ratio)
        }
        XCTAssertGreaterThan(case1.count, 200)
        XCTAssertGreaterThan(case2.count, 80)
        print(String(format: "RATIOS case 1 n=%d min %.3f max %.3f | case 2 n=%d min %.3f max %.3f "
                            + "| train (data/raw) n=19 min 0.382 max 1.328",
                     case1.count, case1.min()!, case1.max()!,
                     case2.count, case2.min()!, case2.max()!))
        // 0.382 is the smallest ratio any train rescue has. Both storms have to
        // sit under the floor, and the floor has to sit under 0.382.
        XCTAssertLessThan(case1.max()!, Self.floor)
        XCTAssertLessThan(case2.max()!, Self.floor)
        XCTAssertLessThan(Self.floor, 0.382)
    }

    // MARK: - Case 1, the lone-knock ring storm

    /// The decay sweep the critic ran. Without the floor this climbs from 0 at
    /// 25 ms to 50 of 50 from 35 ms up; with it, nothing fires at any decay.
    func testCase1DecaySweepGoesToZeroWithTheAnchorFloor() {
        var withFloor: [(Double, Int)] = []
        var without: [(Double, Int)] = []
        for decayMs in [25.0, 28, 30, 35, 40, 50, 60, 80] {
            let stream = loneKnockStorm(decayMs: decayMs, amplitude: 0.5)
            without.append((decayMs, fired(stream, tuning: Self.m26(anchorFraction: 0))))
            withFloor.append((decayMs, fired(stream, tuning: Self.m26(anchorFraction: Self.floor))))
        }
        print("CASE1 decay sweep, 50 lone knocks at 0.5 g every 1.2 s "
              + "(decayMs, floor off, floor \(Self.floor)): "
              + zip(without, withFloor).map { "(\($0.0), \($0.1), \($1.1))" }
                  .joined(separator: " "))
        XCTAssertGreaterThan(without.map(\.1).max() ?? 0, 40,
                             "the storm must still be there to be fixed: \(without)")
        for (decay, n) in withFloor {
            XCTAssertEqual(n, 0, "decay \(decay) ms fired \(n) of 50 lone knocks with the floor "
                           + "on; whole sweep with \(withFloor), without \(without)")
        }
    }

    /// Amplitude does not rescue the mechanism either way: the ratio is scale
    /// free, so a 0.2 g knock and a 1.0 g knock storm alike without the floor.
    func testCase1AmplitudeSweepGoesToZeroWithTheAnchorFloor() {
        var table: [(Double, Double, Int, Int)] = []
        for amplitude in [0.2, 0.35, 0.5, 0.75, 1.0] {
            for decayMs in [30.0, 40, 60] {
                let stream = loneKnockStorm(decayMs: decayMs, amplitude: amplitude)
                table.append((amplitude, decayMs,
                              fired(stream, tuning: Self.m26(anchorFraction: 0)),
                              fired(stream, tuning: Self.m26(anchorFraction: Self.floor))))
            }
        }
        print("CASE1 amplitude sweep (amp g, decayMs, floor off, floor \(Self.floor)): \(table)")
        XCTAssertGreaterThan(table.map(\.2).max() ?? 0, 40, "storm absent from the fixture: \(table)")
        for row in table {
            XCTAssertEqual(row.3, 0, "amplitude \(row.0) g decay \(row.1) ms fired \(row.3); "
                           + "whole table (amp, decay, without, with) \(table)")
        }
    }

    /// Spacing out to 3 s, which is where a knock is unambiguously alone.
    func testCase1SpacingSweepGoesToZeroWithTheAnchorFloor() {
        var table: [(Int, Int, Int)] = []
        for spacingMs in [600, 900, 1200, 1800, 2400, 3000] {
            let stream = loneKnockStorm(decayMs: 40, amplitude: 0.5,
                                        spacingNs: Int64(spacingMs) * 1_000_000, count: 20)
            table.append((spacingMs,
                          fired(stream, tuning: Self.m26(anchorFraction: 0)),
                          fired(stream, tuning: Self.m26(anchorFraction: Self.floor))))
        }
        print("CASE1 spacing sweep, 20 lone knocks (spacingMs, floor off, floor \(Self.floor)): \(table)")
        XCTAssertGreaterThan(table.map(\.1).max() ?? 0, 15, "storm absent from the fixture: \(table)")
        for row in table {
            XCTAssertEqual(row.2, 0, "spacing \(row.0) ms fired \(row.2) of 20; table "
                           + "(spacing, without, with) \(table)")
        }
    }

    // MARK: - Case 2, hard contact then a separate weak one

    /// No ring needed. The gap sweep covers the whole legal inter-tap band.
    func testCase2HardThenWeakGoesToZeroWithTheAnchorFloor() {
        var table: [(Double, Int, Int)] = []
        for gapMs in [110.0, 130, 150, 170, 200] {
            let stream = hardThenWeak(gapMs: gapMs)
            table.append((gapMs,
                          fired(stream, tuning: Self.m26(anchorFraction: 0)),
                          fired(stream, tuning: Self.m26(anchorFraction: Self.floor))))
        }
        print("CASE2, 30 hard-then-weak events (gapMs, floor off, floor \(Self.floor)): \(table)")
        XCTAssertGreaterThan(table.map(\.1).max() ?? 0, 25, "case 2 absent from the fixture: \(table)")
        for row in table {
            XCTAssertEqual(row.2, 0, "gap \(row.0) ms fired \(row.2) of 30; table "
                           + "(gap, without, with) \(table)")
        }
    }

    // MARK: - The floor must not be a blanket ban

    /// A pair of comparable taps is what a real gesture looks like, and the floor
    /// has to leave it alone. Both taps here are UNDER the onset bar, so only
    /// retrospective pairing can fire them at all — and it still does.
    func testAPairOfComparableSubThresholdTapsIsStillRescued() {
        let weak = SyntheticStream.amplitude(timesThreshold: 0.8)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 3_000_000_000)
        stream.taps.append(.init(tNs: SyntheticStream.leadInNs, amplitude: weak * 1.35))
        stream.taps.append(.init(tNs: SyntheticStream.leadInNs + 160_000_000, amplitude: weak))
        // The anchor has to clear the full bar for a group to exist at all, so
        // the first tap is the loud one; the second is 0.74 of it.
        XCTAssertEqual(fired(stream, tuning: Self.m26(anchorFraction: 0)), 1)
        XCTAssertEqual(fired(stream, tuning: Self.m26(anchorFraction: Self.floor)), 1,
                       "the floor must not reject a second tap comparable to the first")
    }

    /// The other half of the plateau. `tunk-score sweep --param
    /// pairRescueAnchorFraction` walks the train side and shows every gesture M26
    /// rescues surviving through 0.38; this walks the storm side and shows both
    /// cases dead from 0.24. The shipped 0.30 sits between the two knees.
    func testTheFloorSweepShowsWhereEachStormDies() {
        let case1 = loneKnockStorm(decayMs: 40, amplitude: 0.5)
        let case2 = hardThenWeak(gapMs: 150)
        var table: [(Double, Int, Int)] = []
        for floor in [0.0, 0.05, 0.10, 0.14, 0.18, 0.22, 0.24, 0.26, 0.30, 0.40] {
            table.append((floor,
                          fired(case1, tuning: Self.m26(anchorFraction: floor)),
                          fired(case2, tuning: Self.m26(anchorFraction: floor))))
        }
        print("FLOOR sweep (floor, case 1 of 50, case 2 of 30): \(table)")
        XCTAssertEqual(table.first(where: { $0.0 == Self.floor })?.1, 0)
        XCTAssertEqual(table.first(where: { $0.0 == Self.floor })?.2, 0)
        XCTAssertGreaterThan(table[0].1, 40, "case 1 must storm at floor 0: \(table)")
        XCTAssertGreaterThan(table[0].2, 25, "case 2 must storm at floor 0: \(table)")
    }

    /// The floor is off by default and must stay off: a config that does not name
    /// it gets M26 exactly as it was graded.
    func testTheFloorShipsInactive() {
        XCTAssertEqual(DSPTuning.default.pairRescueAnchorFraction, 0)
    }
}
