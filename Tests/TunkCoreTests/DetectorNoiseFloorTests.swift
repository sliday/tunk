import XCTest
@testable import TunkCore

/// The adaptive noise floor, and the latch that used to come with freezing it.
///
/// Every fixture here is SYNTHETIC (see SyntheticSignal.swift). "Live surface"
/// below means uniform broadband shake added to all three axes — an invented
/// stand-in for a resonant desk or a machine on a lap, not a recording. It is
/// deliberately broadband, because the 20 Hz high pass already removes the
/// low-frequency confounds (footfall, bass) and those are covered elsewhere.
final class DetectorNoiseFloorTests: XCTestCase {

    /// Add continuous broadband shake to an existing SYNTHETIC stream over
    /// `fromNs ..< toNs`, in g per axis.
    private func addingLiveSurface(_ samples: [AccelSample], amplitude: Double,
                                   fromNs: Int64, toNs: Int64 = .max,
                                   seed: UInt64 = 0x5EA_51DE) -> [AccelSample] {
        var noise = SyntheticNoise(seed: seed)
        return samples.map { s in
            guard s.tNs >= fromNs, s.tNs < toNs else { return s }
            var out = s
            out.x += Float(noise.next(amplitude))
            out.y += Float(noise.next(amplitude))
            out.z += Float(noise.next(amplitude))
            return out
        }
    }

    /// Floor and threshold sampled at the end of every one-second window.
    private func track(_ samples: [AccelSample]) -> [(tNs: Int64, floor: Double, threshold: Double, onsets: Int)] {
        let detector = TapDetector(armedTapCounts: [2])
        var out: [(Int64, Double, Double, Int)] = []
        var windowStart: Int64 = samples.first?.tNs ?? 0
        var onsets = 0
        for s in samples {
            _ = detector.ingest(sample: s)
            onsets += detector.drainOnsets().count
            _ = detector.drainGroups()
            if s.tNs - windowStart >= 1_000_000_000 {
                out.append((s.tNs, detector.noiseFloor, detector.activeThreshold, onsets))
                windowStart = s.tNs
                onsets = 0
            }
        }
        return out.map { (tNs: $0.0, floor: $0.1, threshold: $0.2, onsets: $0.3) }
    }

    // MARK: - The latch

    /// The failure this replaced: the floor froze for as long as the detector
    /// stayed disarmed, and on a surface loud enough to keep it disarmed the
    /// threshold could never rise to let it re-arm. Measured on this fixture
    /// before the fix: floor pinned at 0.0030 g and threshold at 0.3000 g for
    /// the whole ten seconds.
    func testFloorKeepsTrackingWhileTheDetectorCannotReArm() {
        let base = SyntheticStream(durationNs: 14_000_000_000).samples()
        let samples = addingLiveSurface(base, amplitude: 0.25,
                                        fromNs: 2_000_000_000, toNs: 12_000_000_000)
        let windows = track(samples)

        let loud = windows.filter { $0.tNs > 3_000_000_000 && $0.tNs < 12_000_000_000 }
        XCTAssertFalse(loud.isEmpty)
        for w in loud {
            XCTAssertGreaterThan(w.floor, 0.15,
                                 "floor must follow the surface at t=\(w.tNs / 1_000_000) ms")
            XCTAssertGreaterThan(w.threshold, DetectorConfig.default.defaultThreshold,
                                 "and lift the bar above the absolute threshold")
        }
    }

    /// The consequence that matters. A frozen floor does not merely stop
    /// adapting: it leaves the detector deaf, because it cannot re-arm until the
    /// envelope drops under `releaseFraction * threshold` and the threshold is
    /// the thing that is stuck. Before the fix this fixture produced zero
    /// triggers from ten deliberate double-taps.
    func testALoudSurfaceDoesNotDeafenTheDetector() {
        var stream = SyntheticStream(durationNs: 14_000_000_000)
        var expected: [Int64] = []
        var t: Int64 = 3_000_000_000
        while t < 13_000_000_000 {
            stream.taps.append(.init(tNs: t, amplitude: 3.0))
            stream.taps.append(.init(tNs: t + 150_000_000, amplitude: 3.0))
            expected.append(t)
            t += 1_000_000_000
        }
        let samples = addingLiveSurface(stream.samples(), amplitude: 0.25, fromNs: 2_000_000_000)
        let result = TapDetector.replayGroups(samples: samples, inputs: [], armedTapCounts: [2])

        XCTAssertEqual(result.triggers.count, expected.count,
                       "every deliberate double on a loud surface must still land")
        XCTAssertTrue(result.triggers.allSatisfy { $0.tapCount == 2 })
    }

    func testFloorFallsBackWhenTheSurfaceGoesQuiet() {
        let base = SyntheticStream(durationNs: 14_000_000_000).samples()
        let samples = addingLiveSurface(base, amplitude: 0.25,
                                        fromNs: 2_000_000_000, toNs: 12_000_000_000)
        let windows = track(samples)

        guard let last = windows.last else { return XCTFail("no windows") }
        XCTAssertLessThan(last.floor, 0.01, "the fall time constant is a fraction of a second")
        XCTAssertEqual(last.threshold, DetectorConfig.default.defaultThreshold, accuracy: 1e-9,
                       "and the absolute threshold is back in charge")
    }

    // MARK: - What the hold still buys

    /// The hold exists so a strike cannot lift the floor it is measured against
    /// — the second tap of a double is compared against a floor the first tap
    /// moved, and that error only ever runs one way. Bounding the hold must not
    /// give that up. Measured identically before and after the change.
    func testAStrikeBarelyMovesTheFloorItIsMeasuredAgainst() {
        var stream = SyntheticStream(durationNs: 4_000_000_000)
        stream.taps = [.init(tNs: SyntheticStream.leadInNs, amplitude: 0.9)]

        let detector = TapDetector(armedTapCounts: [2])
        var beforeStrike = 0.0
        var atSecondTap: Double?
        for s in stream.samples() {
            _ = detector.ingest(sample: s)
            if s.tNs < SyntheticStream.leadInNs { beforeStrike = detector.noiseFloor }
            if s.tNs >= SyntheticStream.leadInNs + 150_000_000, atSecondTap == nil {
                atSecondTap = detector.noiseFloor
            }
        }
        guard let after = atSecondTap else { return XCTFail("stream too short") }

        XCTAssertLessThan(after - beforeStrike, 0.002,
                          "a 0.9 g strike must not lift its own reference")
        XCTAssertLessThan(DSPTuning.default.noiseSnrMultiple * after,
                          DetectorConfig.default.defaultThreshold * 0.1,
                          "the adaptive term stays a rounding error next to the absolute one")
    }

    func testAQuietSurfaceCostsNothing() {
        let detector = TapDetector(armedTapCounts: [2])
        var maxFloor = 0.0
        for s in SyntheticStream(durationNs: 5_000_000_000).samples() {
            _ = detector.ingest(sample: s)
            maxFloor = max(maxFloor, detector.noiseFloor)
        }
        XCTAssertLessThan(DSPTuning.default.noiseSnrMultiple * maxFloor,
                          DetectorConfig.default.defaultThreshold,
                          "on a quiet machine the absolute threshold is the one in force")
        XCTAssertEqual(detector.activeThreshold, DetectorConfig.default.effectiveThreshold,
                       accuracy: 1e-9)
    }

    /// The hold is a fixed span from the crossing, not "until we re-arm". If
    /// anyone reconnects it to `armed` this fails.
    func testTheHoldIsBoundedNotOpenEnded() {
        XCTAssertGreaterThan(DSPTuning.default.noiseFloorHoldNs, 0)
        XCTAssertLessThan(DSPTuning.default.noiseFloorHoldNs,
                          DetectorConfig.default.minInterTapNs,
                          "the hold must lapse before the next tap of a gesture can arrive")

        // A stream that keeps the detector disarmed indefinitely: the envelope
        // never falls back under releaseFraction * threshold at the shipped
        // threshold, so the only way the floor moves is if the hold lapses.
        let base = SyntheticStream(durationNs: 6_000_000_000).samples()
        let samples = addingLiveSurface(base, amplitude: 0.25, fromNs: 1_000_000_000)
        let detector = TapDetector(armedTapCounts: [2])
        var floorAtTwoSeconds = 0.0
        for s in samples {
            _ = detector.ingest(sample: s)
            if s.tNs >= 2_000_000_000, floorAtTwoSeconds == 0 { floorAtTwoSeconds = detector.noiseFloor }
        }
        XCTAssertGreaterThan(floorAtTwoSeconds, 0.1,
                             "one second of shake must have moved the floor")
    }

    func testFloorTrackingStaysDeterministic() {
        let base = SyntheticStream(durationNs: 8_000_000_000).samples()
        let samples = addingLiveSurface(base, amplitude: 0.25, fromNs: 2_000_000_000)
        let a = TapDetector.replayGroups(samples: samples, inputs: [], armedTapCounts: [1, 2, 3])
        let b = TapDetector.replayGroups(samples: samples, inputs: [], armedTapCounts: [1, 2, 3])
        XCTAssertEqual(a.triggers, b.triggers)
        XCTAssertEqual(a.onsets, b.onsets)
        XCTAssertEqual(a.groups, b.groups)
    }
}
