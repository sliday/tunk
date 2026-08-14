import Foundation

/// Choosing WHICH onsets in an over-long group are the real strikes.
///
/// Every discriminator this project has built so far was a gate: "is this sample
/// a real tap?". That is detection, and it is measured hard — the best statistic
/// found, at a threshold admitting 1 % of ring lobes, kept 10 % of real second
/// strikes. Useless as an admission rule.
///
/// This file asks the other question. The detector already buffers: a group waits
/// a whole `confirmWindowNs` after its last onset before it fires anything, and
/// during that wait it is holding two, three or four candidate onsets and
/// choosing nothing. So when the group holds MORE onsets than any armed count,
/// instead of throwing the whole gesture away, rank the candidates and keep the
/// ones most likely to be strikes.
///
/// Ranking is a much weaker requirement than gating. A statistic with AUC 0.79 is
/// worthless as a threshold and useful as a tie-break between two candidates. And
/// because the confirm window has already elapsed when this runs, selection costs
/// zero extra latency and stays causal: every sample it reads is older than the
/// deadline that triggered it.
///
/// Nothing here admits an onset. It can only ever discard, so it cannot
/// manufacture a trigger out of quiet — the onsets it chooses between were all
/// declared by the unchanged front end.
enum GroupPrune {

    /// One high-passed sample, before the 3-sample sliding maximum.
    ///
    /// The sliding max is what makes the envelope readable as peak g, and it is
    /// also what destroys shape: measured rise time from 20 % to peak reads
    /// 0.0 ms for almost every real tap after it. Everything in this file reads
    /// the pre-max signal instead.
    struct ShapeSample: Sendable, Equatable {
        var tNs: Int64
        var x: Double
        var y: Double
        var z: Double

        var norm: Double { (x * x + y * y + z * z).squareRoot() }
    }

    /// Which statistic ranks the candidates. The magnitude picks the statistic;
    /// a NEGATIVE value inverts it.
    ///
    /// The sign exists for one measured reason. Crest factor separates strikes
    /// from ring lobes on a lap (AUC 0.835 inside the amplitude-overlap band) and
    /// runs BACKWARDS on desk (0.108) and soft (0.315), and the surface is not
    /// detectable from the signal, so it can never be a fixed absolute rule.
    /// Inside one group every candidate shares a surface and a gesture, which is
    /// the only setting where "consistently backwards" is still usable.
    enum Ranker: Int, Sendable, CaseIterable {
        case off = 0
        /// Cosine between this candidate's lateral (x, y) direction at its peak
        /// and the FIRST onset's lateral direction at its peak. Real second
        /// strikes median +0.974, ring lobes median -0.173; lap AUC 0.764 raw,
        /// 0.789 amplitude-stratified. The only one of eleven statistics that is
        /// not amplitude or rise time in disguise, and intrinsically a comparison
        /// against the first strike — which is why it suits ranking inside a
        /// group and failed as a standalone gate.
        case cosFirstXY = 1
        /// max|p| / RMS(p) over -5..+30 ms, p projected on the peak direction.
        /// Strikes median 1.78, ring lobes 1.39 — essentially sqrt(2), the
        /// sinusoid value the ring hypothesis predicts.
        case crest = 2
        /// How far the candidate sits above the fitted decay of the PRECEDING
        /// onset. Lap AUC 0.782, amplitude-stratified.
        case decayResidual = 3
        /// Rank-sum of the three. Ranks rather than z-scores: with two to four
        /// candidates a standard deviation is noise.
        case combined = 4
        /// CONTROL, not a statistic: the latest candidate wins. Reads no signal
        /// at all. Any shape statistic that does not beat this has bought
        /// nothing, and this project has already had one "recovery" turn out to
        /// be a fitted number rather than a cure.
        case recency = 5
        /// CONTROL: the strongest candidate wins, by the same envelope the onset
        /// threshold is measured in. Amplitude has been measured shut as a
        /// discriminator four separate times; it is here as the thing to beat.
        case strength = 6
    }

    // MARK: - Selection

    /// Indices of `onsets` to keep, or nil when this group must be left alone.
    ///
    /// The first onset is always kept. It is the anchor `cosFirstXY` is measured
    /// against, and the question being asked is "which of the later candidates is
    /// the real second strike", not "which of these was the first".
    ///
    /// Deterministic: ties break towards the earlier candidate, and every value
    /// read is a pure function of the samples handed in.
    static func select(onsets: [Int64],
                       strengths: [Double],
                       target: Int,
                       samples: [ShapeSample],
                       peakHoldNs: Int64,
                       ranker rankerValue: Int) -> [Int]? {
        guard target >= 1, onsets.count > target, strengths.count == onsets.count else { return nil }
        guard let ranker = Ranker(rawValue: abs(rankerValue)), ranker != .off else { return nil }
        let inverted = rankerValue < 0

        var peaks: [Int] = []
        if ranker != .recency && ranker != .strength {
            for t in onsets {
                guard let p = peakIndex(samples: samples, onsetNs: t, holdNs: peakHoldNs) else { return nil }
                peaks.append(p)
            }
        }

        var scores = [Double](repeating: 0, count: onsets.count)
        switch ranker {
        case .off:
            return nil
        case .recency:
            for i in 1..<onsets.count { scores[i] = Double(i) }
        case .strength:
            for i in 1..<onsets.count { scores[i] = strengths[i] }
        case .cosFirstXY:
            for i in 1..<onsets.count { scores[i] = cosFirstXY(samples: samples, peak: peaks[i], first: peaks[0]) }
        case .crest:
            for i in 1..<onsets.count { scores[i] = crest(samples: samples, peak: peaks[i]) }
        case .decayResidual:
            for i in 1..<onsets.count {
                scores[i] = decayResidual(samples: samples, previousPeak: peaks[i - 1], peak: peaks[i])
            }
        case .combined:
            var perFeature: [[Double]] = []
            var cos = [Double](repeating: 0, count: onsets.count)
            var cf = [Double](repeating: 0, count: onsets.count)
            var dr = [Double](repeating: 0, count: onsets.count)
            for i in 1..<onsets.count {
                cos[i] = cosFirstXY(samples: samples, peak: peaks[i], first: peaks[0])
                cf[i] = crest(samples: samples, peak: peaks[i])
                dr[i] = decayResidual(samples: samples, previousPeak: peaks[i - 1], peak: peaks[i])
            }
            perFeature = [cos, cf, dr]
            for feature in perFeature {
                let r = ranks(of: Array(feature[1...]))
                for (k, value) in r.enumerated() { scores[k + 1] += value }
            }
        }

        if inverted { for i in scores.indices { scores[i] = -scores[i] } }

        // Keep the first, then the best `target - 1` of the rest. `sorted` on a
        // key that includes the index keeps this a total order, so two candidates
        // that score identically always resolve the same way.
        let rest = Array(1..<onsets.count)
        let ordered = rest.sorted { a, b in
            scores[a] == scores[b] ? a < b : scores[a] > scores[b]
        }
        let kept = ([0] + ordered.prefix(target - 1)).sorted()
        return kept
    }

    /// Ascending ranks, 0-based, ties sharing the lower rank position by index
    /// order. Only used inside `combined`.
    private static func ranks(of values: [Double]) -> [Double] {
        let order = values.indices.sorted { a, b in
            values[a] == values[b] ? a < b : values[a] < values[b]
        }
        var out = [Double](repeating: 0, count: values.count)
        for (rank, idx) in order.enumerated() { out[idx] = Double(rank) }
        return out
    }

    // MARK: - Features

    /// Index of the largest high-passed vector inside `[onsetNs, onsetNs+holdNs]`.
    ///
    /// The same span the detector already waits before publishing an onset's
    /// strength, so nothing here reads further into the future than the existing
    /// peak tracker does.
    static func peakIndex(samples: [ShapeSample], onsetNs: Int64, holdNs: Int64) -> Int? {
        var best: Int?
        var bestValue = -1.0
        var i = lowerBound(samples: samples, tNs: onsetNs)
        while i < samples.count, samples[i].tNs <= onsetNs + holdNs {
            let v = samples[i].norm
            if v > bestValue { bestValue = v; best = i }
            i += 1
        }
        return best
    }

    private static func lowerBound(samples: [ShapeSample], tNs: Int64) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].tNs < tNs { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Cosine between the lateral (x, y) high-passed direction at two peaks.
    /// Zero when either lateral vector is degenerate, which ranks it below any
    /// candidate that agrees with the first strike and above any that opposes it.
    static func cosFirstXY(samples: [ShapeSample], peak: Int, first: Int) -> Double {
        guard samples.indices.contains(peak), samples.indices.contains(first) else { return 0 }
        let a = samples[peak], b = samples[first]
        let na = (a.x * a.x + a.y * a.y).squareRoot()
        let nb = (b.x * b.x + b.y * b.y).squareRoot()
        guard na > 0, nb > 0 else { return 0 }
        return (a.x * b.x + a.y * b.y) / (na * nb)
    }

    static let crestPreNs: Int64 = 5_000_000
    static let crestPostNs: Int64 = 30_000_000

    /// max|p| / RMS(p) over -5..+30 ms of the peak, p being the high-passed
    /// acceleration projected on the peak sample's own direction.
    static func crest(samples: [ShapeSample], peak: Int) -> Double {
        guard samples.indices.contains(peak) else { return 0 }
        let centre = samples[peak]
        let n = centre.norm
        guard n > 0 else { return 0 }
        let dx = centre.x / n, dy = centre.y / n, dz = centre.z / n
        let from = centre.tNs - crestPreNs, to = centre.tNs + crestPostNs

        var maxAbs = 0.0
        var sumSquares = 0.0
        var count = 0
        var i = lowerBound(samples: samples, tNs: from)
        while i < samples.count, samples[i].tNs <= to {
            let p = samples[i].x * dx + samples[i].y * dy + samples[i].z * dz
            maxAbs = max(maxAbs, abs(p))
            sumSquares += p * p
            count += 1
            i += 1
        }
        guard count > 1, sumSquares > 0 else { return 0 }
        let rms = (sumSquares / Double(count)).squareRoot()
        return maxAbs / rms
    }

    static let decayFitStartNs: Int64 = 5_000_000
    static let decayFitEndNs: Int64 = 80_000_000
    private static let decayBlock = 8

    /// Natural-log distance between the candidate's peak and the decay curve
    /// fitted to the preceding onset, extrapolated forward.
    ///
    /// A ring lobe sits ON its parent's decay; a fresh strike sits above it. The
    /// fit is a least-squares line through log block-maxima, which is an
    /// exponential decay in the linear domain — the shape a damped chassis
    /// actually produces. Returns 0 when there is not enough of the preceding
    /// onset's tail to fit, which is the neutral value.
    static func decayResidual(samples: [ShapeSample], previousPeak: Int, peak: Int) -> Double {
        guard samples.indices.contains(previousPeak), samples.indices.contains(peak) else { return 0 }
        let origin = samples[previousPeak].tNs
        let from = origin + decayFitStartNs
        let to = min(origin + decayFitEndNs, samples[peak].tNs - decayFitStartNs)
        guard to > from else { return 0 }

        var xs: [Double] = [], ys: [Double] = []
        var i = lowerBound(samples: samples, tNs: from)
        while i < samples.count, samples[i].tNs <= to {
            var blockMax = 0.0
            var blockTime = 0.0
            var k = 0
            while k < decayBlock, i < samples.count, samples[i].tNs <= to {
                blockMax = max(blockMax, samples[i].norm)
                blockTime += Double(samples[i].tNs - origin)
                k += 1
                i += 1
            }
            guard k > 0, blockMax > 0 else { continue }
            xs.append(blockTime / Double(k))
            ys.append(log(blockMax))
        }
        guard xs.count >= 3 else { return 0 }

        let n = Double(xs.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        var sxx = 0.0, sxy = 0.0
        for k in xs.indices { sxx += xs[k] * xs[k]; sxy += xs[k] * ys[k] }
        let denominator = n * sxx - sx * sx
        guard denominator != 0 else { return 0 }
        let slope = (n * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / n

        let candidate = samples[peak].norm
        guard candidate > 0 else { return 0 }
        let dt = Double(samples[peak].tNs - origin)
        return log(candidate) - (intercept + slope * dt)
    }
}
