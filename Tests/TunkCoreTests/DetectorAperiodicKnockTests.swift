import XCTest
@testable import TunkCore

/// The gap the trigger-storm fix does not close, measured rather than argued.
///
/// `maxInterTapNs <= confirmWindowNs` kills a *periodic* knock train by
/// absorbing it into one over-long group. An aperiodic one slips through: jitter
/// throws up pairs 80–220 ms apart bounded by longer gaps, and that is literally
/// the definition of a double-tap. The detector has no notion of tap shape, so
/// it cannot tell such a pair from a deliberate gesture.
///
/// These tests pin the size of the gap so a future shape test has something to
/// be graded against. They are NOT a pass line. Every fixture is SYNTHETIC (see
/// SyntheticSignal.swift), the knock amplitudes and the gap distribution are
/// invented, and the real number belongs to recordings that do not exist yet.
final class DetectorAperiodicKnockTests: XCTestCase {

    /// SYNTHETIC aperiodic knock train: gaps drawn uniformly from `gapLoNs ...
    /// gapHiNs`, amplitude scattered by `amplitudeJitter` either side of
    /// `amplitude`.
    private func jitterTrain(seed: UInt64, durationNs: Int64,
                             gapLoNs: Int64, gapHiNs: Int64,
                             amplitude: Double = 0.5,
                             amplitudeJitter: Double = 0) -> SyntheticStream {
        var rng = SyntheticNoise(seed: seed)
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + durationNs
                                                 + 1_000_000_000)
        stream.seed = seed &+ 99
        var t = SyntheticStream.leadInNs
        let span = Double(gapHiNs - gapLoNs)
        while t < SyntheticStream.leadInNs + durationNs {
            stream.taps.append(.init(tNs: t, amplitude: amplitude * (1 + rng.next(amplitudeJitter))))
            // `next` is symmetric about zero over ±amplitude, so shift it into 0...1.
            t += gapLoNs + Int64((rng.next(1.0) + 1) / 2 * span)
        }
        return stream
    }

    private func triggers(_ stream: SyntheticStream, armed: Set<Int> = [2]) -> [Trigger] {
        TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                 armedTapCounts: armed).triggers
    }

    // MARK: - The gap

    /// The number the whole write-up hangs on. Five seeds, 60 s each, gaps drawn
    /// uniformly from 100–400 ms. Measured: 22, 26, 22, 27, 24 — mean 24.2 per
    /// 60 s, against a PRD bar of under one per 20 minutes.
    func testAJitteredKnockTrainStillFiresRepeatedly() {
        var counts: [Int] = []
        for seed in [UInt64(1), 2, 3, 4, 5] {
            let stream = jitterTrain(seed: seed, durationNs: 60_000_000_000,
                                     gapLoNs: 100_000_000, gapHiNs: 400_000_000)
            counts.append(triggers(stream).count)
        }
        let mean = Double(counts.reduce(0, +)) / Double(counts.count)
        XCTAssertGreaterThan(mean, 10,
                             "if this drops, something real changed — measure it, do not "
                             + "silently accept it. Measured 24.2 per 60 s: \(counts)")
        XCTAssertLessThan(mean, 60, "the refractory caps it at 100 per 60 s: \(counts)")
    }

    /// The contrast that shows the storm fix works and shows what it works on. A
    /// strictly periodic train at the same cadence fires nothing, because it
    /// chains into one over-long group; the jittered one does not chain.
    func testAPeriodicTrainAtTheSameCadenceFiresNothing() {
        for spacingNs in [150_000_000, 200_000_000] as [Int64] {
            var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 61_000_000_000)
            var t = SyntheticStream.leadInNs
            while t < SyntheticStream.leadInNs + 60_000_000_000 {
                stream.taps.append(.init(tNs: t, amplitude: 0.5))
                t += spacingNs
            }
            XCTAssertTrue(triggers(stream).isEmpty, "periodic \(spacingNs / 1_000_000) ms")
        }
    }

    /// Why no timing test inside the pair can help: the false pairs' inter-tap
    /// intervals fill the legal band, and a deliberate double-tap lives in that
    /// same band by definition. Narrowing the band trades false triggers for
    /// missed gestures one for one, with no data yet to price either side.
    func testFalsePairIntervalsFillTheLegalBand() {
        let stream = jitterTrain(seed: 7, durationNs: 300_000_000_000,
                                 gapLoNs: 100_000_000, gapHiNs: 400_000_000,
                                 amplitudeJitter: 0.5)
        let fired = triggers(stream)
        XCTAssertGreaterThan(fired.count, 20)

        let intervals = fired.compactMap { t -> Int64? in
            guard t.tapOnsets.count == 2 else { return nil }
            return t.tapOnsets[1] - t.tapOnsets[0]
        }.sorted()
        guard let lo = intervals.first, let hi = intervals.last else { return XCTFail("none") }

        XCTAssertLessThan(lo, DetectorConfig.default.minInterTapNs + 30_000_000,
                          "false pairs reach the bottom of the legal band")
        XCTAssertGreaterThan(hi, DetectorConfig.default.maxInterTapNs - 30_000_000,
                             "and the top of it")
    }

    /// The one discriminator that showed real separation on this fixture, and it
    /// is not a shape test: require quiet either side of the pair. Looking
    /// backwards is free; looking forwards costs latency, one millisecond for
    /// one millisecond, and the PRD budget is 250 ms from the last onset.
    ///
    /// Measured on the 300 s fixture, 88 false triggers: a 400 ms backward-only
    /// quiet window leaves 38, both directions leave 19. The forward half buys
    /// the other half of the reduction and is the half that costs latency.
    func testIsolationSeparatesFalsePairsFarBetterThanTimingDoes() {
        let stream = jitterTrain(seed: 7, durationNs: 300_000_000_000,
                                 gapLoNs: 100_000_000, gapHiNs: 400_000_000,
                                 amplitudeJitter: 0.5)
        let result = TapDetector.replayGroups(samples: stream.samples(), inputs: [],
                                              armedTapCounts: [2])
        let onsetTimes = result.onsets.map(\.tNs)
        let fired = result.triggers
        XCTAssertGreaterThan(fired.count, 20)

        let quiet: Int64 = 400_000_000
        let survivingBackwardOnly = fired.filter { trigger in
            guard let first = trigger.tapOnsets.first else { return false }
            return onsetTimes.last { $0 < first }.map { first - $0 >= quiet } ?? true
        }.count

        XCTAssertLessThan(survivingBackwardOnly, fired.count / 2,
                          "a backward-only isolation test costs no latency and removes "
                          + "over half of these: \(survivingBackwardOnly) of \(fired.count)")
    }
}
