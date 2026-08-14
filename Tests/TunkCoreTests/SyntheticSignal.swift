import Foundation
@testable import TunkCore

// SYNTHETIC SIGNALS. Nothing here is recorded data. There is no dataset yet;
// every waveform below is generated from a formula so the detector's state
// machine can be exercised deterministically. These fixtures prove logic, not
// real-world detection rates. Amplitudes are plausible (a deliberate tap on a
// hard surface swinging a few tenths of a g, resting z near -0.98 g per the
// measured sensor facts in FORMAT.md) but they are invented.

/// Deterministic uniform noise. A plain LCG so a test run is bit-reproducible
/// on any machine, unlike `Double.random`.
struct SyntheticNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next(_ amplitude: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return (unit * 2 - 1) * amplitude
    }
}

/// Builds a SYNTHETIC accelerometer stream at the measured nominal rate.
///
/// Resting attitude is the measured one (z ≈ -0.98 g). Each tap is a damped
/// sinusoid added to all three axes, which is what a struck chassis does: a
/// short broadband ring, not a step.
struct SyntheticStream {
    /// 796.3 Hz, per FORMAT.md.
    static let intervalNs: Int64 = 1_256_000
    static let sampleRateHz: Double = 796.3

    struct Tap {
        var tNs: Int64
        /// Peak deviation in g on the dominant axis.
        var amplitude: Double
        var ringHz: Double = 180
        var decaySeconds: Double = 0.004
    }

    var durationNs: Int64
    var taps: [Tap] = []
    var noiseAmplitude: Double = 0.002
    var seed: UInt64 = 0xC0FFEE
    /// Extra low-frequency wobble in g, e.g. a machine on a lap. Below the
    /// 20 Hz high pass it should be invisible to the detector.
    var wobbleAmplitude: Double = 0
    var wobbleHz: Double = 3

    func samples(startNs: Int64 = 0, arrivalOffsetNs: Int64 = 300_000) -> [AccelSample] {
        var noise = SyntheticNoise(seed: seed)
        var out: [AccelSample] = []
        out.reserveCapacity(Int(durationNs / Self.intervalNs) + 1)

        var t: Int64 = 0
        while t <= durationNs {
            var x = 0.004 + noise.next(noiseAmplitude)
            var y = -0.003 + noise.next(noiseAmplitude)
            var z = -0.9796 + noise.next(noiseAmplitude)

            if wobbleAmplitude > 0 {
                let phase = 2 * Double.pi * wobbleHz * Double(t) / 1e9
                z += wobbleAmplitude * sin(phase)
                x += wobbleAmplitude * 0.4 * sin(phase * 1.3)
            }

            for tap in taps where t >= tap.tNs {
                let dt = Double(t - tap.tNs) / 1e9
                if dt > tap.decaySeconds * 8 { continue }
                let ring = exp(-dt / tap.decaySeconds) * sin(2 * Double.pi * tap.ringHz * dt)
                z += tap.amplitude * ring
                x += tap.amplitude * 0.35 * ring
                y += tap.amplitude * 0.25 * ring
            }

            out.append(AccelSample(tNs: startNs + t,
                                   arrivalNs: startNs + t + arrivalOffsetNs,
                                   x: Float(x), y: Float(y), z: Float(z)))
            t += Self.intervalNs
        }
        return out
    }
}

extension SyntheticStream {
    /// A tap amplitude expressed as a multiple of the shipped onset threshold.
    ///
    /// Fixtures used to state amplitudes absolutely, which tied them to whatever
    /// `defaultThreshold` happened to be. Moving that default from an invented
    /// 0.30 g to a fitted value broke five tests, then ten. None of them because
    /// behaviour regressed — because "a tap" and "a tap too weak to count" had
    /// been written as numbers that only meant something beside the old bar.
    ///
    /// Measured gain through the filter chain: envelope is about 0.68x the tap
    /// amplitude (0.05 -> 0.0333 g, 0.08 -> 0.0534 g).
    static func amplitude(timesThreshold multiple: Double) -> Double {
        DetectorConfig.default.defaultThreshold * multiple / 0.68
    }

    /// Gain of an ARBITRARY front end, measured rather than written down.
    ///
    /// The 0.68 above is the default chain's. The resonator's is 0.0789 — nine
    /// times smaller, because a narrow band passes a slice of a broadband
    /// impulse. A test that swaps the front end and keeps the constant asks for
    /// taps a ninth of the size it means and gets a beautiful, meaningless
    /// result: measuring the resonator against aperiodic knock trains that way
    /// produced 0 firings against the shipped chain's 28.8, which looked like a
    /// breakthrough and was an artifact of every knock being sub-threshold.
    static func chainGain(tuning: DSPTuning) -> Double {
        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 1_000_000_000)
        stream.taps.append(.init(tNs: SyntheticStream.leadInNs, amplitude: 1.0))
        var chain = SignalChain(tuning: tuning)
        var peak = 0.0
        for s in stream.samples() {
            peak = max(peak, chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                           holdNoiseFloor: false))
        }
        return peak
    }

    /// A tap amplitude worth `multiple` of `threshold` through `tuning`.
    static func amplitude(timesThreshold multiple: Double,
                          tuning: DSPTuning,
                          threshold: Double) -> Double {
        threshold * multiple / chainGain(tuning: tuning)
    }

    /// Quiet lead-in so the high pass settles and the noise floor converges
    /// before the first tap. 1.5 s at 796 Hz is ~1200 samples.
    static let leadInNs: Int64 = 1_500_000_000

    /// A stream holding one SYNTHETIC gesture: `count` taps spaced `spacingNs`
    /// apart, starting after the lead-in.
    static func gesture(count: Int,
                        spacingNs: Int64,
                        amplitude: Double = 0.9,
                        tailNs: Int64 = 1_000_000_000,
                        noiseAmplitude: Double = 0.002,
                        wobbleAmplitude: Double = 0) -> (stream: SyntheticStream, onsets: [Int64]) {
        let onsets = (0..<count).map { leadInNs + Int64($0) * spacingNs }
        var stream = SyntheticStream(durationNs: (onsets.last ?? leadInNs) + tailNs,
                                     taps: onsets.map { Tap(tNs: $0, amplitude: amplitude) })
        stream.noiseAmplitude = noiseAmplitude
        stream.wobbleAmplitude = wobbleAmplitude
        return (stream, onsets)
    }
}
