import XCTest
@testable import TunkCore
import TunkFormat

/// The optional narrow band in front of the envelope (`DSPTuning.resonatorHz`).
///
/// Two things have to hold. It must be ABSENT unless asked for — the shipped
/// front end is the one every number in `notes/BAR_ASSESSMENT.md` was measured
/// on, and turning a filter on by accident would invalidate all of them. And
/// when it is asked for it must do the thing it was built for: reject the
/// low-frequency shoulder the second lap strike competes with, without ringing
/// long enough to be mistaken for a tap.
final class FrontEndResonatorTests: XCTestCase {

    // MARK: - Off by default

    func testShippedTuningHasNoResonator() {
        XCTAssertEqual(DSPTuning.default.resonatorHz, 0,
                       "the resonator ships OFF; every graded number assumes it")
    }

    /// The whole safety argument for this knob: with it off, the envelope is
    /// sample-for-sample what it was before the stage existed.
    func testOffReproducesTheShippedEnvelopeExactly() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        var shipped = SignalChain(tuning: .default)
        var explicitlyOff = DSPTuning.default
        explicitlyOff.resonatorHz = 0
        // Q is irrelevant while the centre is zero, and a stage that ignored the
        // centre would show up here as a divergence.
        explicitlyOff.resonatorQ = 7.5
        var off = SignalChain(tuning: explicitlyOff)

        for s in samples {
            let a = shipped.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                    holdNoiseFloor: false)
            let b = off.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                holdNoiseFloor: false)
            XCTAssertEqual(a, b, accuracy: 0, "the OFF path must not touch the signal")
            XCTAssertEqual(shipped.noiseFloor, off.noiseFloor, accuracy: 0)
        }
    }

    /// Same claim one level up, where it is the one that matters to a user: the
    /// detector fires the same triggers at the same instants.
    func testOffReproducesTheShippedTriggersExactly() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        var offTuning = DSPTuning.default
        offTuning.resonatorHz = 0
        let shipped = TapDetector(config: .default)
        let off = TapDetector(config: .default, tuning: offTuning)

        var a: [Trigger] = []
        var b: [Trigger] = []
        for s in samples {
            if let t = shipped.ingest(sample: s) { a.append(t) }
            if let t = off.ingest(sample: s) { b.append(t) }
        }
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a, b)
    }

    // MARK: - What it does when it is on

    /// The measured reason the stage exists. On a lap the 12-45 ms before a real
    /// second strike carries 43-46 % of its power below 20 Hz against 28-38 %
    /// for the strike, and a one-pole high pass at 6 dB/oct cannot reject that
    /// shoulder. A pole pair can.
    func testItRejectsTheLowFrequencyShoulderFarHarderThanTheHighPassAlone() {
        func envelopeRatio(tuning: DSPTuning, toneHz: Double) -> Double {
            var chain = SignalChain(tuning: tuning)
            let fs = tuning.sampleRateHz
            var peak = 0.0
            let n = Int(fs * 2)
            for i in 0..<n {
                let phase = 2 * Double.pi * toneHz * Double(i) / fs
                let v = 0.05 * sin(phase)
                let e = chain.process(x: 0, y: 0, z: -0.9796 + v, holdNoiseFloor: true)
                // Ignore the first second: both filters are still settling.
                if i > n / 2 { peak = max(peak, e) }
            }
            return peak
        }

        var on = DSPTuning.default
        on.resonatorHz = 40
        on.resonatorQ = 2

        let shippedShoulder = envelopeRatio(tuning: .default, toneHz: 10)
        let shippedStrike = envelopeRatio(tuning: .default, toneHz: 40)
        let onShoulder = envelopeRatio(tuning: on, toneHz: 10)
        let onStrike = envelopeRatio(tuning: on, toneHz: 40)

        // Measured on this fixture: 1.98 shipped, 4.36 with the resonator. The
        // bar is set at 2x rather than at the measured 2.2x so a small change in
        // the fixture does not read as a regression.
        let shippedSelectivity = shippedStrike / shippedShoulder
        let onSelectivity = onStrike / onShoulder
        XCTAssertGreaterThan(onSelectivity, shippedSelectivity * 2,
                             "40 Hz over 10 Hz: shipped \(shippedSelectivity), with the "
                             + "resonator \(onSelectivity)")
    }

    /// A real-valued narrow band dips to zero twice per cycle and the detector
    /// re-arms in those dips — the "metronome at the debounce period" failure
    /// three earlier re-arm mechanisms hit. Taking the MAGNITUDE of the complex
    /// pole state is what buys a smooth envelope, so this is the property that
    /// makes the stage usable rather than a detail of its arithmetic.
    func testItsOutputIsASmoothEnvelopeRatherThanASineToRideOn() {
        var res = Resonator(centreHz: 40, q: 2, sampleRateHz: 796.3)
        var lo = Double.infinity
        var hi = 0.0
        // Same pole, but reading the REAL part instead of the magnitude — the
        // conventional bandpass, and the one that would re-arm the detector on
        // its own zero crossings.
        var realLo = Double.infinity
        var realHi = 0.0
        var re = 0.0
        var im = 0.0
        for i in 0..<1600 {
            let phase = 2 * Double.pi * 40 * Double(i) / 796.3
            let x = sin(phase)
            let y = res.process(x)
            let nextRe = res.poleRe * re - res.poleIm * im + x
            let nextIm = res.poleIm * re + res.poleRe * im
            re = nextRe
            im = nextIm
            if i > 800 {
                lo = min(lo, y)
                hi = max(hi, y)
                realLo = min(realLo, abs(res.gain * re))
                realHi = max(realHi, abs(res.gain * re))
            }
        }
        // The magnitude still ripples — a real input excites the pole's negative
        // image, which beats at 2f — but it never comes near zero. Measured on
        // this fixture: 0.437 to 0.563, a floor at 0.78 of the peak.
        XCTAssertGreaterThan(lo, 0.5 * hi,
                             "envelope must not collapse between cycles, got \(lo) to \(hi)")
        XCTAssertLessThan(realLo, 0.05 * realHi,
                          "the real part DOES collapse (\(realLo) to \(realHi)); that is what "
                          + "the magnitude is here to avoid")
    }

    /// The filter's own ring-down has to be over long before the detector is
    /// allowed to declare a second onset, or what gets detected is the filter.
    /// Time constant is q / (pi * f0) — 16 ms at 40 Hz Q 2 against a 100 ms
    /// debounce.
    func testItRingsDownWellInsideTheOnsetDebounce() {
        var res = Resonator(centreHz: 40, q: 2, sampleRateHz: 796.3)
        let peak = res.process(1.0)
        XCTAssertGreaterThan(peak, 0)
        var decayedAtNs: Int64 = -1
        for i in 1..<1600 {
            let y = res.process(0)
            if y < peak * 0.01 {
                decayedAtNs = Int64(Double(i) / 796.3 * 1e9)
                break
            }
        }
        XCTAssertGreaterThan(decayedAtNs, 0, "the impulse response must decay")
        XCTAssertLessThan(decayedAtNs, DSPTuning.default.onsetDebounceNs,
                          "filter ring-down \(Double(decayedAtNs) / 1e6) ms must clear the "
                          + "100 ms debounce")
    }

    /// Turning the centre on without refitting the threshold is a trap worth a
    /// test rather than a comment: a narrow band costs a broadband strike about
    /// 3x of its amplitude, and `minThresholdG` (0.02 g) then sits above every
    /// tap on every surface. This records the loss so nobody reads the knob as
    /// free.
    func testANarrowBandCostsABroadbandStrikeRealAmplitude() {
        let (stream, _) = SyntheticStream.gesture(count: 1, spacingNs: 160_000_000)
        let samples = stream.samples()
        func peakEnvelope(_ tuning: DSPTuning) -> Double {
            var chain = SignalChain(tuning: tuning)
            var peak = 0.0
            for s in samples {
                peak = max(peak, chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                               holdNoiseFloor: true))
            }
            return peak
        }
        var on = DSPTuning.default
        on.resonatorHz = 40
        on.resonatorQ = 2
        let loss = peakEnvelope(.default) / peakEnvelope(on)
        XCTAssertGreaterThan(loss, 1.5, "the stage is not free; it costs amplitude")
    }

    /// The mechanism claim, checked on recorded lap taps rather than on a
    /// fixture: with the narrow band in front, the detector is listening when
    /// the second lap strike arrives far more often than it is today.
    ///
    /// "Seen" here is the same test `ArmStateDiagnosisTests` uses — an ungated
    /// onset within 60 ms of the labelled second tap. That test records 55 of 80
    /// lap second taps seen on the shipped front end; this one asserts the
    /// resonator does better, which is the only reason to carry the stage.
    func testItHearsMoreLapSecondTapsThanTheShippedFrontEnd() throws {
        let root = "/Users/stas/Playground/tunk/data/raw/"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root)
            .filter({ $0.hasPrefix("tap_deck__lap__") }).sorted(), !dirs.isEmpty else {
            throw XCTSkip("no lap tap decks under \(root)")
        }

        var resonatorTuning = DSPTuning.default
        resonatorTuning.resonatorHz = 40
        resonatorTuning.resonatorQ = 2
        // Refitted with the stage: the narrow band costs a broadband strike
        // about 3x, so the absolute bar and its sanity floor move with it.
        resonatorTuning.minThresholdG = 0.002
        var resonatorConfig = DetectorConfig.default
        resonatorConfig.defaultThreshold = 0.011

        func secondTapsSeen(config: DetectorConfig, tuning: DSPTuning) throws -> (seen: Int, total: Int) {
            var seen = 0
            var total = 0
            for name in dirs {
                let session = try Session(directory: URL(fileURLWithPath: root + name))
                let samples = try session.samples()
                let groups = try session.labelGroups().filter { $0.count >= 2 }
                guard !samples.isEmpty, !groups.isEmpty else { continue }
                let d = TapDetector(config: config, tuning: tuning)
                for s in samples { _ = d.ingest(sample: s) }
                let onsets = d.drainOnsets().filter { !$0.suppressedByGate }.map(\.tNs)
                for g in groups {
                    total += 1
                    if onsets.contains(where: { abs($0 - g[1].tNs) < 60_000_000 }) { seen += 1 }
                }
            }
            return (seen, total)
        }

        let shipped = try secondTapsSeen(config: .default, tuning: .default)
        let withStage = try secondTapsSeen(config: resonatorConfig, tuning: resonatorTuning)
        print("  lap second taps seen: shipped \(shipped.seen)/\(shipped.total), "
              + "resonator \(withStage.seen)/\(withStage.total)")
        XCTAssertGreaterThan(withStage.seen, shipped.seen)
    }

    /// Deterministic and causal, same contract as the rest of the chain.
    func testItIsDeterministicWithTheResonatorOn() {
        var on = DSPTuning.default
        on.resonatorHz = 40
        on.resonatorQ = 2
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 160_000_000)
        let samples = stream.samples()

        func run() -> [Trigger] {
            let d = TapDetector(config: .default, tuning: on)
            var out: [Trigger] = []
            for s in samples { if let t = d.ingest(sample: s) { out.append(t) } }
            return out
        }
        XCTAssertEqual(run(), run())
    }
}
