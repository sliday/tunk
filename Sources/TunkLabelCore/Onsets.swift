import Foundation
import TunkCore

// Transient picking for labelling. This is deliberately NOT the detector: the
// detector runs causally, in real time, under a false-positive budget. This runs
// offline, knows where to look because a beep told it, and is allowed to be
// greedy. Sharing code between them would let a labelling quirk quietly become a
// detection quirk, and then the harness would be grading the detector against
// its own assumptions.

/// One transient found in the stream.
public struct Peak: Sendable {
    public var tNs: Int64
    /// Envelope height at the peak, in g above the local baseline.
    public var amplitude: Double
    /// Height relative to the session's noise floor. The honest measure of
    /// "did something actually happen here".
    public var snr: Double
}

public struct OnsetPicker {
    /// Window for the running baseline. Long enough to hold gravity and posture
    /// steady, short enough that it does not smear a tap.
    public var baselineWindow = 64          // ~80 ms at 796 Hz
    /// Envelope smoothing. A tap rings for a few ms; this keeps one physical tap
    /// as one peak instead of a burst.
    public var envelopeWindow = 4           // ~5 ms
    /// Two peaks closer than this are the same physical event.
    public var minSeparationNs: Int64 = 40_000_000
    /// A peak must clear this multiple of the noise floor to count at all.
    public var snrThreshold = 6.0
    /// And this absolute height, so a pathologically quiet session cannot make
    /// sensor dither look like a tap.
    public var absoluteFloor = 0.004        // g

    public init() {}

    /// High-pass by subtracting a centred running mean, then take the magnitude
    /// across all three axes. Orientation-free: a tap on the lid and a tap on
    /// the palm rest load different axes, and we care about neither.
    public func envelope(_ samples: [AccelSample]) -> [Double] {
        let n = samples.count
        guard n > baselineWindow else { return [Double](repeating: 0, count: n) }

        var sx = 0.0, sy = 0.0, sz = 0.0
        var mag = [Double](repeating: 0, count: n)
        let w = baselineWindow
        // Prefix sums keep this O(n) rather than O(n·w); sessions are minutes long.
        var px = [Double](repeating: 0, count: n + 1)
        var py = px, pz = px
        for i in 0..<n {
            sx += Double(samples[i].x); sy += Double(samples[i].y); sz += Double(samples[i].z)
            px[i + 1] = sx; py[i + 1] = sy; pz[i + 1] = sz
        }
        for i in 0..<n {
            let lo = max(0, i - w / 2), hi = min(n, i + w / 2)
            let c = Double(hi - lo)
            let bx = (px[hi] - px[lo]) / c
            let by = (py[hi] - py[lo]) / c
            let bz = (pz[hi] - pz[lo]) / c
            let dx = Double(samples[i].x) - bx
            let dy = Double(samples[i].y) - by
            let dz = Double(samples[i].z) - bz
            mag[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        // Dilate so each transient is one plateau rather than a comb.
        var env = mag
        if envelopeWindow > 1 {
            for i in 0..<n {
                let lo = max(0, i - envelopeWindow), hi = min(n - 1, i + envelopeWindow)
                var m = 0.0
                for j in lo...hi where mag[j] > m { m = mag[j] }
                env[i] = m
            }
        }
        return env
    }

    /// Median of the envelope. Robust to the taps themselves, which is the point:
    /// a mean would be dragged upward by the very events we are measuring.
    public func noiseFloor(_ env: [Double]) -> Double {
        guard !env.isEmpty else { return 0 }
        var s = env
        s.sort()
        let m = s[s.count / 2]
        return max(m, 1e-9)
    }

    /// Every transient in `[from, to]`, strongest first.
    public func peaks(in samples: [AccelSample], env: [Double], floor: Double,
                      from: Int64, to: Int64) -> [Peak] {
        var found: [Peak] = []
        let minHeight = max(floor * snrThreshold, absoluteFloor)

        var i = 0
        while i < samples.count, samples[i].tNs < from { i += 1 }
        while i < samples.count, samples[i].tNs <= to {
            let v = env[i]
            if v >= minHeight {
                // Walk to the top of this plateau.
                var j = i
                var best = i
                while j < samples.count, samples[j].tNs <= to, env[j] >= minHeight {
                    if env[j] > env[best] { best = j }
                    j += 1
                }
                found.append(Peak(tNs: samples[best].tNs, amplitude: env[best], snr: env[best] / floor))
                i = j
            } else {
                i += 1
            }
        }

        // Collapse anything closer than one physical event apart, keeping the
        // taller of the pair.
        var kept: [Peak] = []
        for p in found.sorted(by: { $0.amplitude > $1.amplitude }) {
            if kept.contains(where: { abs($0.tNs - p.tNs) < minSeparationNs }) { continue }
            kept.append(p)
        }
        return kept.sorted { $0.amplitude > $1.amplitude }
    }
}
