import Foundation

/// Within-group candidate ranking for the second tap.
///
/// ## Why this is not another detector
///
/// Eleven mechanisms before this one asked a detection question — "is this
/// sample a real tap?" — and answered it with a statistic and a threshold. The
/// best statistic found kept 10 % of real second strikes at a cutoff admitting
/// 1 % of ring lobes, which is useless as a gate.
///
/// The detector already buffers. A group waits a whole `confirmWindowNs` after
/// its last onset before it fires, and on a lap the second strike frequently
/// arrives while the detector is still disarmed by the first strike's ring, so
/// the group sits at one onset with the answer sitting unread in the signal.
/// The question this file asks is **which** of the candidates inside that
/// already-elapsed window is the second tap. Ordering two or three candidates
/// is a far weaker demand than gating, and a statistic with AUC 0.79 is a
/// usable tie-breaker even though it is a hopeless gate.
///
/// ## Cost
///
/// None in latency. The scan runs inside the join window, which has already
/// elapsed; a recovered gesture fires one confirm window after the onset that
/// was selected, exactly like a gesture the detector heard unaided. Nothing
/// here reads a clock: every deadline is a comparison against a sample's own
/// timestamp.
///
/// ## Shape
///
/// 1. The group's first onset fixes a reference: the lateral (x, y) direction of
///    the high-passed acceleration at that strike's peak sample, and an
///    exponential fitted to the strike's own envelope decay.
/// 2. Inside `minInterTapNs ... maxInterTapNs` a shadow peak-picker collects
///    candidates at `rankCandidateFraction` of the onset threshold, re-arming
///    against each candidate's own peak rather than against the threshold — the
///    point is to hear a strike riding a tail that never returns to baseline.
/// 3. Each candidate gets four statistics, measured on the raw high-passed
///    signal before the sliding max destroys the waveform's shape.
/// 4. `rankStatTailNs` after the window closes, the candidates are ranked
///    within the group, the ranks are averaged, and the winner is taken only if
///    at least `rankAgreement` of the statistics put it first.
///
/// Rank-averaging rather than summing raw values is deliberate: crest factor
/// carries a per-surface offset and even a per-surface sign, and the surface is
/// not detectable at runtime. A within-group rank is scale-free, so a constant
/// offset cancels; the agreement rule is what handles the sign, by refusing to
/// act when the statistics disagree instead of trusting a broken one.
struct RankSelector {

    /// One buffered sample. Only the fields the statistics read.
    struct Sample {
        var tNs: Int64
        var hx: Double
        var hy: Double
        var hz: Double
        var env: Double
    }

    struct Candidate {
        var tNs: Int64
        /// Envelope at the crossing sample. This is what the decay residual is
        /// measured against, so it is the same quantity the fit predicts.
        var crossingEnv: Double
        /// Highest envelope seen while the candidate was open, published as the
        /// onset's strength if it wins.
        var peakEnv: Double
        var evaluated = false
        /// cos_first_xy, crest, decay residual, kurtosis. NaN until evaluated.
        var stats: [Double] = [.nan, .nan, .nan, .nan]
    }

    static let statCount = 4

    // MARK: - Buffered signal

    private var ring: [Sample] = []
    private var ringHead = 0
    private var ringFilled = 0

    // MARK: - Per-group state

    private(set) var isActive = false
    private var firstOnsetNs: Int64 = 0
    private var threshold: Double = 0

    private var refPeakNs: Int64 = 0
    private var refPeakMagnitude: Double = 0
    private var refX: Double = 0
    private var refY: Double = 0

    // Least squares of ln(envelope) against time over the first strike's decay.
    private var fitN = 0.0, fitSx = 0.0, fitSy = 0.0, fitSxx = 0.0, fitSxy = 0.0

    private var candidateArmed = true
    private var openTNs: Int64?
    private var openCrossingEnv = 0.0
    private var openPeakEnv = 0.0

    private(set) var candidates: [Candidate] = []
    /// When the ranking decision can be taken: the join window plus the tail the
    /// widest statistic window needs. Nil when no selection is pending.
    private(set) var selectionDeadlineNs: Int64?

    // MARK: - Lifecycle

    mutating func begin(firstOnsetNs: Int64, threshold: Double,
                        config: DetectorConfig, tuning: DSPTuning) {
        reset()
        isActive = true
        self.firstOnsetNs = firstOnsetNs
        self.threshold = threshold
        refPeakNs = firstOnsetNs
        selectionDeadlineNs = firstOnsetNs + config.maxInterTapNs + tuning.rankStatTailNs
    }

    mutating func stop() {
        isActive = false
        selectionDeadlineNs = nil
        candidates.removeAll(keepingCapacity: true)
        openTNs = nil
        candidateArmed = true
        fitN = 0; fitSx = 0; fitSy = 0; fitSxx = 0; fitSxy = 0
        refPeakMagnitude = 0
        refX = 0
        refY = 0
    }

    mutating func reset() {
        stop()
        ring.removeAll(keepingCapacity: true)
        ringHead = 0
        ringFilled = 0
    }

    // MARK: - Sample path

    /// Buffer one sample and advance the reference, the decay fit and the shadow
    /// candidate scan. Called only while a group is live and the knob is on, so
    /// a detector with ranking off never pays for the ring.
    mutating func ingest(tNs: Int64, hx: Double, hy: Double, hz: Double, env: Double,
                         config: DetectorConfig, tuning: DSPTuning) {
        push(Sample(tNs: tNs, hx: hx, hy: hy, hz: hz, env: env), capacity: tuning.rankRingCapacity)
        guard isActive else { return }

        // 1. The first strike's peak sample, searched over one full cycle of the
        //    sensor's 50 Hz ceiling. A shorter window lands on the rising edge,
        //    where the lateral direction has the opposite sign.
        if tNs <= firstOnsetNs + tuning.rankPeakWindowNs {
            let magnitude = (hx * hx + hy * hy + hz * hz).squareRoot()
            if magnitude > refPeakMagnitude {
                refPeakMagnitude = magnitude
                refPeakNs = tNs
                refX = hx
                refY = hy
            }
        }

        // 2. The strike's own decay, in log space, from just past its peak.
        let sinceRef = tNs - refPeakNs
        if sinceRef >= 6_000_000, sinceRef <= 60_000_000, env > 0 {
            let x = Double(sinceRef) / 1e9
            let y = Foundation.log(env)
            fitN += 1; fitSx += x; fitSy += y; fitSxx += x * x; fitSxy += x * y
        }

        // 3. The shadow scan, bounded by the join window on both sides.
        let windowOpens = firstOnsetNs + config.minInterTapNs
        let windowCloses = firstOnsetNs + config.maxInterTapNs
        guard tNs >= windowOpens else { return }
        guard tNs <= windowCloses else {
            closeOpenCandidate()
            return
        }

        if candidateArmed {
            if env >= config.rankCandidateFraction * threshold {
                candidateArmed = false
                openTNs = tNs
                openCrossingEnv = env
                openPeakEnv = env
            }
        } else if let open = openTNs {
            openPeakEnv = max(openPeakEnv, env)
            if env <= tuning.rankCandidateReleaseFraction * openPeakEnv,
               tNs - open >= tuning.rankCandidateDebounceNs {
                closeOpenCandidate()
                candidateArmed = true
            }
        }
    }

    private mutating func closeOpenCandidate() {
        guard let open = openTNs else { return }
        candidates.append(Candidate(tNs: open, crossingEnv: openCrossingEnv, peakEnv: openPeakEnv))
        openTNs = nil
    }

    // MARK: - Selection

    /// The winner, or nil if nothing was chosen. Nil is the safe answer: the
    /// group keeps the count it already had, which is today's behaviour.
    mutating func select(now: Int64, config: DetectorConfig, tuning: DSPTuning)
        -> (tNs: Int64, strength: Double)?
    {
        closeOpenCandidate()
        for i in candidates.indices where !candidates[i].evaluated {
            candidates[i].stats = statistics(for: candidates[i], tuning: tuning)
            candidates[i].evaluated = true
        }
        guard !candidates.isEmpty else { return nil }

        let weights = [config.rankWeightCos, config.rankWeightCrest,
                       config.rankWeightDecay, config.rankWeightKurtosis]
        let enabled = (0..<Self.statCount).filter { weights[$0] > 0 }

        // Within-group fractional ranks, one statistic at a time. Scale-free by
        // construction, which is the whole reason for ranking rather than
        // summing: a per-surface offset on any statistic cancels here.
        var score = [Double](repeating: 0, count: candidates.count)
        var weightSum = 0.0
        for s in enabled {
            let values = candidates.map { $0.stats[s] }
            let ranks = fractionalRanks(values)
            for i in candidates.indices { score[i] += weights[s] * ranks[i] }
            weightSum += weights[s]
        }
        if weightSum > 0 {
            for i in score.indices { score[i] /= weightSum }
        }

        // Ties break towards the later candidate. With every weight at zero this
        // is the whole rule, which makes "take the last candidate in the window"
        // measurable through the same knob as the ranker it is the baseline for.
        var best = 0
        for i in candidates.indices where score[i] > score[best] + 1e-12
            || (abs(score[i] - score[best]) <= 1e-12 && candidates[i].tNs > candidates[best].tNs) {
            best = i
        }

        // Agreement. A posture that inverts one statistic leaves the group
        // alone rather than promoting a ring lobe.
        let required = Int(config.rankAgreement.rounded())
        if required > 0 && !enabled.isEmpty {
            var agreeing = 0
            for s in enabled {
                let winner = candidates[best].stats[s]
                if candidates.allSatisfy({ !($0.stats[s] > winner) }) { agreeing += 1 }
            }
            if agreeing < required { return nil }
        }

        return (candidates[best].tNs, candidates[best].peakEnv)
    }

    private func fractionalRanks(_ values: [Double]) -> [Double] {
        let n = values.count
        guard n > 1 else { return [1] }
        var ranks = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var below = 0.0, equal = 0.0
            for j in 0..<n {
                if values[j] < values[i] { below += 1 }
                else if values[j] == values[i] { equal += 1 }
            }
            ranks[i] = (below + (equal - 1) / 2) / Double(n - 1)
        }
        return ranks
    }

    // MARK: - The statistics

    private func statistics(for candidate: Candidate, tuning: DSPTuning) -> [Double] {
        guard let peak = peakSample(from: candidate.tNs, window: tuning.rankPeakWindowNs) else {
            return [0, 0, 0, 0]
        }
        return [cosFirstXY(at: peak),
                crest(at: peak),
                decayResidual(for: candidate),
                kurtosis(at: peak)]
    }

    /// Index into the ring of the largest |high-passed acceleration| in the
    /// candidate's peak window.
    private func peakSample(from tNs: Int64, window: Int64) -> Int? {
        var best: Int?
        var bestMagnitude = -1.0
        forEachSample(from: tNs, to: tNs + window) { i, s in
            let m = (s.hx * s.hx + s.hy * s.hy + s.hz * s.hz).squareRoot()
            if m > bestMagnitude { bestMagnitude = m; best = i }
        }
        return best
    }

    /// Cosine between the lateral direction here and at the first strike's peak.
    private func cosFirstXY(at index: Int) -> Double {
        let s = ring[index]
        let a = (s.hx * s.hx + s.hy * s.hy).squareRoot()
        let b = (refX * refX + refY * refY).squareRoot()
        guard a > 1e-12, b > 1e-12 else { return 0 }
        return (s.hx * refX + s.hy * refY) / (a * b)
    }

    /// max|p| / RMS(p) over -5..+30 ms, p the waveform projected on the peak
    /// sample's own direction. A ring lobe sits at sqrt(2), the sinusoid value.
    private func crest(at index: Int) -> Double {
        guard let u = unitVector(at: index) else { return 0 }
        let centre = ring[index].tNs
        var peak = 0.0, sumSquares = 0.0, n = 0.0
        forEachSample(from: centre - 5_000_000, to: centre + 30_000_000) { _, s in
            let p = s.hx * u.0 + s.hy * u.1 + s.hz * u.2
            peak = max(peak, abs(p))
            sumSquares += p * p
            n += 1
        }
        guard n > 0 else { return 0 }
        let rms = (sumSquares / n).squareRoot()
        return rms > 1e-15 ? peak / rms : 0
    }

    /// Excess kurtosis of the projected waveform over ~55 ms.
    private func kurtosis(at index: Int) -> Double {
        guard let u = unitVector(at: index) else { return 0 }
        let centre = ring[index].tNs
        var values: [Double] = []
        forEachSample(from: centre - 10_000_000, to: centre + 45_000_000) { _, s in
            values.append(s.hx * u.0 + s.hy * u.1 + s.hz * u.2)
        }
        guard values.count > 3 else { return 0 }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        guard variance > 1e-30 else { return 0 }
        let fourth = values.reduce(0) { $0 + Foundation.pow($1 - mean, 4) } / n
        return fourth / (variance * variance) - 3
    }

    /// How far the candidate's crossing sits above the decay fitted to the
    /// preceding strike, in log-envelope units. Zero when the fit has too little
    /// support to mean anything, which ranks the candidate mid-field rather than
    /// inventing evidence.
    private func decayResidual(for candidate: Candidate) -> Double {
        guard fitN >= 8, candidate.crossingEnv > 0 else { return 0 }
        let denominator = fitN * fitSxx - fitSx * fitSx
        guard abs(denominator) > 1e-18 else { return 0 }
        var slope = (fitN * fitSxy - fitSx * fitSy) / denominator
        // A rising fit is not a decay; predict a flat tail instead of an
        // exploding one.
        if slope > 0 { slope = 0 }
        let intercept = (fitSy - slope * fitSx) / fitN
        let dt = Double(candidate.tNs - refPeakNs) / 1e9
        return Foundation.log(candidate.crossingEnv) - (slope * dt + intercept)
    }

    private func unitVector(at index: Int) -> (Double, Double, Double)? {
        let s = ring[index]
        let m = (s.hx * s.hx + s.hy * s.hy + s.hz * s.hz).squareRoot()
        guard m > 1e-12 else { return nil }
        return (s.hx / m, s.hy / m, s.hz / m)
    }

    // MARK: - Ring

    private mutating func push(_ sample: Sample, capacity: Int) {
        let cap = max(8, capacity)
        if ring.count < cap {
            ring.append(sample)
            ringFilled = ring.count
            ringHead = ring.count % cap
            return
        }
        ring[ringHead] = sample
        ringHead = (ringHead + 1) % cap
        ringFilled = cap
    }

    /// Visit buffered samples with `from <= tNs <= to`, oldest first.
    private func forEachSample(from: Int64, to: Int64, _ body: (Int, Sample) -> Void) {
        guard ringFilled > 0 else { return }
        let cap = ring.count
        for k in 0..<ringFilled {
            let i = (ringHead + cap - ringFilled + k) % cap
            let s = ring[i]
            if s.tNs >= from && s.tNs <= to { body(i, s) }
        }
    }
}
