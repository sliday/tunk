import XCTest
@testable import TunkCore

/// The one-sample race at the join boundary.
///
/// With `maxInterTapNs == confirmWindowNs` an onset whose delta lands in
/// `(maxInterTapNs, maxInterTapNs + one sample]` reaches the grouping code while
/// the previous group is still live — deadlines are checked after onsets, on
/// purpose, so an onset landing exactly on a deadline still counts as inside the
/// window. That onset cannot join, and the old code responded by deleting the
/// live group: no `TapGroupEvent`, no trigger, nothing in the tap monitor.
///
/// The window is one sample period wide, ~1.26 ms at 796 Hz, so it is rare. It
/// is also silent, and it can eat a completed double-tap.
///
/// All fixtures are SYNTHETIC (see SyntheticSignal.swift).
final class DetectorJoinBoundaryTests: XCTestCase {

    private static let sampleNs = SyntheticStream.intervalNs

    private func thumps(at offsets: [Int64], amplitude: Double = 0.5)
        -> (stream: SyntheticStream, base: Int64)
    {
        let base = SyntheticStream.leadInNs
        var stream = SyntheticStream(durationNs: base + (offsets.last ?? 0) + 1_500_000_000)
        stream.taps = offsets.map { .init(tNs: base + $0, amplitude: amplitude) }
        return (stream, base)
    }

    private func run(_ stream: SyntheticStream, armed: Set<Int>)
        -> (triggers: [Trigger], onsets: [OnsetEvent], groups: [TapGroupEvent])
    {
        TapDetector.replayGroups(samples: stream.samples(), inputs: [], armedTapCounts: armed)
    }

    // MARK: - The gesture that used to vanish

    /// A clean double, then one unrelated knock landing in the race window. The
    /// double is already complete and its count can no longer change, so it must
    /// fire. Before the fix this measured `groups=[1]`, `triggers=0` at 221 ms
    /// against `groups=[2]`, `triggers=1` at 222 ms — a whole gesture lost to a
    /// stray knock 1 ms earlier than another that costs nothing.
    func testAStrayKnockInTheRaceWindowDoesNotEatACompletedDouble() {
        for strayMs in [221, 222, 230, 300] as [Int64] {
            let (stream, _) = thumps(at: [0, 150_000_000, 150_000_000 + strayMs * 1_000_000])
            let result = run(stream, armed: [2])

            XCTAssertEqual(result.triggers.count, 1,
                           "stray knock \(strayMs) ms after the second tap")
            XCTAssertEqual(result.triggers.first?.tapCount, 2)
            XCTAssertTrue(result.groups.contains { $0.tapCount == 2 && $0.fired },
                          "and the monitor sees the gesture too")
        }
    }

    /// The other side of the same boundary: a stray knock close enough to chain
    /// makes it a triple, and a triple is not a double. That was already correct
    /// and must stay correct.
    func testAStrayKnockInsideTheJoinWindowStillMakesItATriple() {
        for strayMs in [200, 219, 220] as [Int64] {
            let (stream, _) = thumps(at: [0, 150_000_000, 150_000_000 + strayMs * 1_000_000])
            let result = run(stream, armed: [2])
            XCTAssertTrue(result.triggers.isEmpty, "stray knock \(strayMs) ms")
            XCTAssertEqual(result.groups.map(\.tapCount), [3])
        }
    }

    // MARK: - Every group reaches the monitor

    /// Two isolated knocks either side of the boundary. Both are groups of one,
    /// and both must be reported whatever the spacing — the tap monitor going
    /// quiet is how a user concludes the sensor is broken. Before the fix,
    /// 220 and 221 ms reported one group where 222 ms reported two.
    func testBothIsolatedKnocksAreReportedAcrossTheBoundary() {
        // Spacings sit clear of maxInterTapNs (220 ms) rather than on it.
        // Exactly-on-the-boundary is sample-quantisation sensitive: samples are
        // 1.256 ms apart, so which one first crosses the threshold moves the
        // measured delta by a sample, and lowering the threshold to its fitted
        // 0.045 g moved it across. The property under test is that no group is
        // ever DELETED rather than closed, which does not live at one value.
        for spacingMs in [210, 215, 225, 230, 240] as [Int64] {
            let (stream, _) = thumps(at: [0, spacingMs * 1_000_000])
            let result = run(stream, armed: [])

            XCTAssertEqual(result.onsets.count, 2, "spacing \(spacingMs) ms")
            let expected = spacingMs <= 220 ? [2] : [1, 1]
            XCTAssertEqual(result.groups.map(\.tapCount), expected,
                           "spacing \(spacingMs) ms: no group may be deleted instead of closed")
        }
    }

    /// The boundary is where it is because a detected onset lands a sample or
    /// two after the strike. Stated as an assertion so the fixtures above stay
    /// honest if the sample rate in the generator ever moves.
    func testTheBoundaryFallsWhereTheOnsetDeltaSaysItDoes() {
        let (stream, _) = thumps(at: [0, 221_000_000])
        let result = run(stream, armed: [])
        XCTAssertEqual(result.onsets.count, 2)

        let delta = result.onsets[1].tNs - result.onsets[0].tNs
        XCTAssertGreaterThan(delta, DetectorConfig.default.maxInterTapNs,
                             "this fixture only tests anything if the delta is past the limit")
        XCTAssertLessThanOrEqual(delta, DetectorConfig.default.maxInterTapNs + Self.sampleNs,
                                 "and inside one sample period of it, which is the race")
    }

    // MARK: - Closing is not the same as firing early

    /// A group closed by a late onset takes the same confirm decision it would
    /// have taken at its deadline, including the refractory it sets. The onset
    /// that closed it is then swallowed by that refractory, exactly as it would
    /// have been had the deadline landed one sample sooner.
    func testAGroupClosedByALateOnsetStillSetsTheRefractory() {
        let (stream, _) = thumps(at: [0, 221_000_000, 442_000_000])
        let result = run(stream, armed: [1])

        XCTAssertEqual(result.triggers.count, 1, "one fires, the refractory eats the rest")
        XCTAssertEqual(result.triggers.first?.tapOnsets.count, 1)
        let latency = (result.triggers.first?.tNs ?? 0) - (result.triggers.first?.tapOnsets[0] ?? 0)
        XCTAssertGreaterThanOrEqual(latency, DetectorConfig.default.confirmWindowNs,
                                    "closing early must not fire early")
        XCTAssertLessThan(latency, DetectorConfig.default.confirmWindowNs + Self.sampleNs * 2)
    }

    /// A bounce inside `minInterTapNs` still kills the group outright and
    /// publishes nothing. That group never reached a confirm decision, so there
    /// is no count worth reporting — unlike one closed by a late onset.
    func testABounceStillAbortsWithoutPublishingAGroup() {
        let (stream, _) = thumps(at: [0, 40_000_000])
        let result = run(stream, armed: [1, 2, 3])

        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertTrue(result.groups.isEmpty, "an aborted group has no count to report")
        XCTAssertEqual(result.onsets.count, 2, "but both onsets still reach the monitor")
    }

    /// The same boundary when the confirm window is deliberately wider than the
    /// join window. Here the late onset arrives before the group's own deadline,
    /// so closing it is a real behaviour change: the group's count is already
    /// final, so it gets its decision rather than being thrown away.
    func testAWideConfirmWindowClosesTheGroupRatherThanDeletingIt() {
        var config = DetectorConfig.default
        config.confirmWindowNs = 400_000_000
        config.maxInterTapNs = 150_000_000

        let (stream, _) = thumps(at: [0, 120_000_000, 400_000_000])
        let result = TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                              config: config, armedTapCounts: [2])
        XCTAssertEqual(result.triggers.count, 1, "the pair was complete before the stray knock")
        XCTAssertEqual(result.triggers.first?.tapCount, 2)
        XCTAssertTrue(result.groups.contains { $0.tapCount == 2 && $0.fired })
    }

    func testTheBoundaryFixIsDeterministic() {
        let (stream, _) = thumps(at: [0, 150_000_000, 371_000_000, 600_000_000])
        let samples = stream.samples()
        let a = TapDetector.replayGroups(samples: samples, inputs: [], armedTapCounts: [1, 2, 3])
        let b = TapDetector.replayGroups(samples: samples, inputs: [], armedTapCounts: [1, 2, 3])
        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.groups, b.groups)
    }
}
