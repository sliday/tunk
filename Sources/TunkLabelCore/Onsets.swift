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
    /// How far a local maximum must stand above the dip separating it from a
    /// taller neighbour, as a fraction of its own height. Stops ripple on a
    /// decaying tail from counting as a second strike, while still separating
    /// two real taps whose rings overlap — which is what a soft surface does.
    public var prominenceFraction = 0.35

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

        // Every LOCAL maximum above the bar, not one per plateau.
        //
        // Taking a single maximum per contiguous run above `minHeight` looked
        // right on a hard desk, where the ring decays below the bar between the
        // two taps of a gesture. On a soft surface it does not: the case rings
        // longer, the envelope never dips under the bar, and both taps merge
        // into one plateau whose single reported peak is the louder strike. The
        // second tap vanishes, the labeller writes a one-onset group, and the
        // detector's perfectly correct trigger then scores as a false positive
        // against a label anchored on the beep. That is how a working detector
        // read 33 % on soft.
        //
        // A local maximum needs `prominence`: it must stand clear of the
        // shallowest dip separating it from a taller neighbour, so ripple on the
        // way down does not become a tap.
        var i = 0
        while i < samples.count, samples[i].tNs < from { i += 1 }
        let start = i
        while i < samples.count, samples[i].tNs <= to {
            let v = env[i]
            let prev = i > start ? env[i - 1] : 0
            let next = (i + 1 < samples.count && samples[i + 1].tNs <= to) ? env[i + 1] : 0
            if v >= minHeight, v >= prev, v > next {
                found.append(Peak(tNs: samples[i].tNs, amplitude: v, snr: v / floor))
            }
            i += 1
        }

        // Drop maxima that do not stand clear of the dip between them and a
        // taller neighbour. Without this every wobble on a decaying tail counts.
        let byTime = found.sorted { $0.tNs < $1.tNs }
        var prominent: [Peak] = []
        for (idx, p) in byTime.enumerated() {
            var isProminent = true
            for (jdx, q) in byTime.enumerated() where q.amplitude > p.amplitude {
                // Lowest envelope value between the two.
                let lo = min(idx, jdx), hi = max(idx, jdx)
                var valley = Double.greatestFiniteMagnitude
                var k = 0
                while k < samples.count, samples[k].tNs < byTime[lo].tNs { k += 1 }
                while k < samples.count, samples[k].tNs <= byTime[hi].tNs {
                    valley = min(valley, env[k]); k += 1
                }
                if p.amplitude - valley < p.amplitude * prominenceFraction {
                    isProminent = false
                    break
                }
            }
            if isProminent { prominent.append(p) }
        }
        found = prominent

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
