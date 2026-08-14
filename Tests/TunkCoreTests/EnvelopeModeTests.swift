import XCTest
@testable import TunkCore

/// Tests for `DSPTuning.envelopeMode`, the front-end experiment knob.
///
/// The knob exists to answer one question with data: is the 3-sample sliding
/// maximum smearing the first strike over the second, so that the second tap of
/// a lap gesture never appears as a rise of its own? Measured on data/raw, no —
/// the peak envelope around every labelled second tap is identical to four
/// decimals whether the stage is a sliding max, a median, or absent. The knob
/// stays because the measurement should be reproducible, and because a front end
/// somebody can swap is worth more than a comment saying it was tried.
///
/// The load-bearing test here is `testKnobOffIsTheShippedChainSampleForSample`.
/// Everything else is a claim about a mode nobody ships.
final class EnvelopeModeTests: XCTestCase {

    // MARK: - Off means off

    func testDefaultTuningRunsTheSlidingMaximum() {
        XCTAssertEqual(DSPTuning.default.envelopeMode, .slidingMax)
        XCTAssertEqual(DSPTuning.default.envelopeDecayTauMs, 0)
        XCTAssertEqual(DSPTuning.default.envelopePeakSamples, 3)
    }

    /// The shipped chain is whatever `DSPTuning.default` builds. Naming the mode
    /// explicitly must produce the same envelope on every sample, or "off" is
    /// not off.
    func testKnobOffIsTheShippedChainSampleForSample() {
        var explicit = DSPTuning.default
        explicit.envelopeMode = .slidingMax
        explicit.envelopeDecayTauMs = 0

        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        let samples = stream.samples()

        var shipped = SignalChain(tuning: .default)
        var named = SignalChain(tuning: explicit)
        for s in samples {
            let a = shipped.process(x: Double(s.x), y: Double(s.y), z: Double(s.z), holdNoiseFloor: false)
            let b = named.process(x: Double(s.x), y: Double(s.y), z: Double(s.z), holdNoiseFloor: false)
            XCTAssertEqual(a, b, "envelope diverged at t=\(s.tNs)")
        }
        XCTAssertEqual(shipped.noiseFloor, named.noiseFloor)
    }

    /// And the same through the whole detector, triggers and onsets alike.
    func testKnobOffReplaysToTheSameTriggers() {
        var explicit = DSPTuning.default
        explicit.envelopeMode = .slidingMax

        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        let samples = stream.samples()
        let shipped = TapDetector.replay(samples: samples, inputs: [], tuning: .default)
        let named = TapDetector.replay(samples: samples, inputs: [], tuning: explicit)

        XCTAssertEqual(shipped.triggers.count, 1, "fixture should fire one double-tap")
        XCTAssertEqual(shipped.triggers, named.triggers)
        XCTAssertEqual(shipped.onsets, named.onsets)
    }

    // MARK: - What each mode does

    private func envelopes(_ mode: EnvelopeMode, tauMs: Double = 0,
                           input: [Double]) -> [Double] {
        var tuning = DSPTuning.default
        tuning.envelopeMode = mode
        tuning.envelopeDecayTauMs = tauMs
        var stage = SignalChain(tuning: tuning)
        // Drive the chain on one axis. The high pass passes an impulse almost
        // intact at 20 Hz against 796 Hz, so the shape survives to the envelope.
        return input.map { stage.process(x: $0, y: 0, z: 0, holdNoiseFloor: true) }
    }

    func testSlidingMaxHoldsAPeakAndSampleModeDoesNot() {
        let impulse = [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
        let held = envelopes(.slidingMax, input: impulse)
        let bare = envelopes(.sample, input: impulse)

        // The quadrature pair pairs each sample with the one before, so a single
        // input impulse is already two samples wide before any envelope stage
        // runs. A 3-sample sliding max takes that to four.
        XCTAssertEqual(bare.filter { $0 > 0.5 }.count, 2)
        XCTAssertEqual(held.filter { $0 > 0.5 }.count, 4)
        for i in impulse.indices {
            XCTAssertGreaterThanOrEqual(held[i], bare[i], "the sliding max can only dilate")
        }
    }

    /// The median is the only mode that can read LOWER than the raw pair, which
    /// is why it was rejected: at 796 Hz a tap's energy lands in a couple of
    /// samples and the median gives some of it away. On data/raw it cost two lap
    /// second taps (67 of 80 over threshold under the shipped chain, 65 under
    /// the median) and lost 6.25 points of lap detection end to end.
    func testMedianAttenuatesAPeakTheOtherModesKeep() {
        let impulse = [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
        let med = envelopes(.median, input: impulse)
        let bare = envelopes(.sample, input: impulse)
        let held = envelopes(.slidingMax, input: impulse)
        XCTAssertLessThan(med.max()!, bare.max()!)
        XCTAssertLessThan(med.max()!, held.max()!)
    }

    func testDecayHoldReleasesAtTheStatedTimeConstant() {
        let tauMs = 20.0
        var input = [0.0, 0.0, 1.0]
        input.append(contentsOf: Array(repeating: 0.0, count: 400))
        let out = envelopes(.decayHold, tauMs: tauMs, input: input)

        let peakIndex = out.firstIndex(of: out.max()!)!
        let peak = out[peakIndex]
        // One tau later the hold should sit at 1/e of the peak. At 796.3 Hz,
        // 20 ms is 15.9 samples; allow the rounding that implies.
        let oneTau = peakIndex + Int((tauMs / 1000.0 * DSPTuning.default.sampleRateHz).rounded())
        XCTAssertEqual(out[oneTau] / peak, exp(-1.0), accuracy: 0.02)
        XCTAssertTrue(zip(out[peakIndex...], out[(peakIndex + 1)...]).allSatisfy { $0 >= $1 },
                      "a peak hold must be monotonically falling once released")
    }

    /// A tau of zero must degenerate to a pass-through, not to a latch. A hold
    /// that never releases would leave the detector disarmed for the rest of the
    /// session, which is the worst failure this file can ship.
    func testDecayHoldWithZeroTauIsAPassThrough() {
        let impulse = [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
        XCTAssertEqual(envelopes(.decayHold, tauMs: 0, input: impulse),
                       envelopes(.sample, input: impulse))
    }

    /// Every mode still has to fire a clean, loud double-tap. A front end that
    /// stops detecting the easy case is broken, whatever it does for the hard one.
    func testEveryModeStillFiresACleanDoubleTap() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 180_000_000)
        let samples = stream.samples()
        for mode in EnvelopeMode.allCases {
            var tuning = DSPTuning.default
            tuning.envelopeMode = mode
            tuning.envelopeDecayTauMs = mode == .decayHold ? 12 : 0
            let out = TapDetector.replay(samples: samples, inputs: [], tuning: tuning)
            XCTAssertEqual(out.triggers.count, 1, "mode \(mode) did not fire a clean double-tap")
        }
    }
}
