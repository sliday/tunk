import XCTest
@testable import TunkCore

/// Does retrospective pairing storm?
///
/// The question is not rhetorical. `maxInterTapNs <= confirmWindowNs` kills a
/// periodic knock train by absorbing it into one over-long group, and this
/// mechanism only ever acts on a group that reached exactly ONE onset — so on
/// paper the anti-storm behaviour is untouched. On paper is not a measurement.
/// A train whose knocks are further apart than the join window produces
/// one-member groups back to back, and every one of them is now rescuable from
/// the crest buffer.
///
/// Every fixture is SYNTHETIC and every one of them is the worst case for this
/// mechanism: `SyntheticStream` builds each tap as one damped sinusoid scaled
/// onto three axes, so every transient is perfectly rectilinear and every
/// transient points the same way. The rectilinearity ranking and the coherence
/// veto are both defeated by construction, which leaves the timing rules alone
/// to hold the line. Real knocks are neither that clean nor that aligned.
final class PairRescueStormTests: XCTestCase {

    private static var m26: DSPTuning {
        var t = DSPTuning.default
        t.pairRescueEnabled = true       // candidateFraction 0.5, cosMin 0.7, rank by rect
        return t
    }

    private func thumpStream(spacingNs: Int64, durationNs: Int64,
                             amplitude: Double = 0.5) -> SyntheticStream {
        let count = Int(durationNs / spacingNs)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + durationNs
                                                 + 1_000_000_000)
        for i in 0..<count {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * spacingNs,
                                     amplitude: amplitude))
        }
        return stream
    }

    private func fired(_ stream: SyntheticStream, tuning: DSPTuning) -> Int {
        TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                 config: .default, tuning: tuning,
                                 armedTapCounts: [2]).triggers.count
    }

    /// THE fixture that killed `rejected/early-fire-on-count`'s predecessor: 60 s
    /// of thumps at double-tap cadence, swept either side of the join window so
    /// the chaining boundary itself is covered. The shipped detector fires zero
    /// at every spacing. This is the same sweep with the mechanism on.
    func testAPeriodicTrainCannotStormWithRetrospectivePairingOn() {
        var counts: [(Int, Int, Int)] = []
        for spacingMs in [120, 160, 200, 210, 220, 230, 260, 300, 400] {
            let stream = thumpStream(spacingNs: Int64(spacingMs) * 1_000_000,
                                     durationNs: 60_000_000_000)
            counts.append((spacingMs, fired(stream, tuning: .default),
                           fired(stream, tuning: Self.m26)))
        }
        for (spacing, baseline, m26) in counts {
            XCTAssertEqual(baseline, 0, "\(spacing) ms baseline")
            XCTAssertEqual(m26, 0, "\(spacing) ms periodic train fired \(m26) times in 60 s "
                           + "with retrospective pairing on; the whole sweep was \(counts)")
        }
    }

    /// The same sweep at a finer step through the band where a train's knocks
    /// land just outside the join window, which is where one-member groups come
    /// back to back and the mechanism has the most to work with.
    func testTheBandJustPastTheJoinWindowDoesNotStormEither() {
        var counts: [(Int, Int)] = []
        for spacingMs in stride(from: 225, through: 340, by: 5) {
            let stream = thumpStream(spacingNs: Int64(spacingMs) * 1_000_000,
                                     durationNs: 60_000_000_000)
            counts.append((spacingMs, fired(stream, tuning: Self.m26)))
        }
        let worst = counts.max { $0.1 < $1.1 }
        XCTAssertEqual(worst?.1, 0, "worst spacing was \(String(describing: worst)) over \(counts)")
    }

    /// Amplitude matters as well as cadence: a quieter train sits closer to the
    /// half-threshold crest bar the mechanism opens, so it gets its own sweep.
    func testAQuietPeriodicTrainDoesNotStorm() {
        for amplitudeTimesThreshold in [1.2, 1.6, 2.5] {
            let amplitude = SyntheticStream.amplitude(timesThreshold: amplitudeTimesThreshold)
            for spacingMs in [240, 260, 280, 320] {
                let stream = thumpStream(spacingNs: Int64(spacingMs) * 1_000_000,
                                         durationNs: 60_000_000_000, amplitude: amplitude)
                XCTAssertEqual(fired(stream, tuning: Self.m26), 0,
                               "\(amplitudeTimesThreshold)x threshold at \(spacingMs) ms")
            }
        }
    }

    /// Isolated knocks two seconds apart: nothing can pair with anything, and
    /// the mechanism must not invent a partner out of one knock's own ring-down.
    /// This is the closest synthetic analogue of the mug and the footfall.
    func testIsolatedKnocksStayIsolated() {
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 61_000_000_000)
        for i in 0..<30 {
            stream.taps.append(.init(tNs: SyntheticStream.leadInNs + Int64(i) * 2_000_000_000,
                                     amplitude: 0.9))
        }
        XCTAssertEqual(fired(stream, tuning: .default), 0)
        XCTAssertEqual(fired(stream, tuning: Self.m26), 0,
                       "a lone knock's own ring-down must not become its second tap")
    }

    /// The gap the storm fix never closed, measured again with the mechanism on.
    /// An aperiodic train throws up legal-looking pairs and the shipped detector
    /// already fires on them; the number that matters is whether this mechanism
    /// makes that worse, and by how much.
    func testAnAperiodicKnockTrainIsNoWorseThanTheShippedDetector() {
        var baseline: [Int] = []
        var m26: [Int] = []
        for seed in [UInt64(1), 2, 3, 4, 5] {
            var rng = SyntheticNoise(seed: seed)
            var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 61_000_000_000)
            stream.seed = seed &+ 99
            var t = SyntheticStream.leadInNs
            while t < SyntheticStream.leadInNs + 60_000_000_000 {
                stream.taps.append(.init(tNs: t, amplitude: 0.5))
                t += 100_000_000 + Int64((rng.next(1.0) + 1) / 2 * 300_000_000)
            }
            baseline.append(fired(stream, tuning: .default))
            m26.append(fired(stream, tuning: Self.m26))
        }
        let baseMean = Double(baseline.reduce(0, +)) / 5
        let m26Mean = Double(m26.reduce(0, +)) / 5
        XCTAssertGreaterThan(baseMean, 10, "the shipped detector already fires here: \(baseline)")
        // Not a pass line — a tripwire. If the mechanism starts multiplying
        // false pairs on a knock train, that shows up here first.
        XCTAssertLessThanOrEqual(m26Mean, baseMean * 1.35,
                                 "baseline \(baseline) vs pairing on \(m26)")
    }
}
