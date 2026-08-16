import Foundation

// Retrospective pairing, ranked by polarization. The mechanism graded as M26.
//
// ## What it does, and what it deliberately does not touch
//
// The onset state machine in `Detector.swift` is untouched. Full-bar onsets
// still count, so a third full-bar onset still makes an unbindable 3-group and
// a periodic knock train still dies as one over-long group. Nothing here acts
// on a crest as it happens.
//
// What it adds is a buffer under the onset threshold: every local maximum of the
// envelope that reaches `candidateFraction` of the LIVE threshold is recorded
// with its amplitude, its rectilinearity and its principal axis, armed or
// disarmed, gated or not. At the group deadline that already exists — and only
// there, and only for a group that reached exactly one member — the buffer is
// scanned for a crest inside the legal inter-tap band, and the survivor with the
// LOWEST rectilinearity is taken as the second tap.
//
// Latency is unchanged by construction: the decision happens at the deadline the
// detector was already waiting for, not at some new instant.
//
// ## Why the lowest rectilinearity, and why the veto points the way it does
//
// A lap second-strike lands on the ring-down of the first, and the two are
// indistinguishable by amplitude — measured over the whole corpus, crest peak
// over live threshold runs 1.01-4.83 for real strikes and 1.05-2.22 for lobes,
// total overlap. They are not indistinguishable by axis structure: a lobe is one
// chassis mode decaying, so its covariance is nearly rank one, and a fresh
// contact excites several modes at once.
//
// The polarization veto reads the other way round from the obvious guess, and
// the direction was measured rather than assumed. The second tap's axis is MORE
// aligned with the first tap's, not less: two strikes from the same finger on
// the same spot push the chassis the same way. So the veto is a COHERENCE
// requirement (`|u_candidate . u_anchor| >= cosMin`), not a novelty one.
//
// ## The anchor floor, and the two false-trigger cases it closes
//
// `candidateFraction` is measured against the LIVE THRESHOLD and against nothing
// else, so a crest can be a twentieth of the contact that produced it and still
// qualify. Two cases lived in that gap and both were reproduced by critics: a
// lone knock with a lap-like ring-down, whose own decay clears half the bar 100
// ms later, and a hard contact followed by a separate weak one at 0.6x the bar.
//
// `anchorFraction` closes both by requiring the crest to reach a fraction of the
// ANCHOR'S OWN peak envelope. Measured rather than assumed, on data/raw:
//
//   the 19 crests M26 rescues on train   ratio 0.382 - 1.328, p50 0.590
//   the lone-knock ring storm            ratio 0.032 - 0.131, p50 0.056
//   hard contact then a weak one         ratio 0.175 - 0.235, p50 0.202
//
// The populations do not touch. Anything in (0.235, 0.382) kills both storms and
// keeps every train rescue; `PairRescueAnchorFloorTests` walks the storm side of
// that plateau and `tunk-score sweep --param pairRescueAnchorFraction` the train
// side. It ships at 0, i.e. inactive, exactly as M26 was graded.

/// One buffered envelope crest, with the axis structure read a fixed number of
/// samples later.
struct PairRescueCandidate: Sendable, Equatable {
    var tNs: Int64
    /// Envelope at the crest, in g.
    var amplitude: Double
    /// The live onset threshold at the crest's own sample, in g. Kept so the
    /// admission test is against the bar that was in force then, not the one in
    /// force at the deadline.
    var threshold: Double
    var rect: Double
    var ux: Double
    var uy: Double
    var uz: Double
}

/// The crest buffer, the fixed delay line that feeds it, and the anchor's own
/// polarization reading.
///
/// Every buffer here is allocated once. `observe` runs on the 796 Hz path and
/// touches no heap; `scan` runs at most once per group deadline.
struct PairRescue: Sendable {

    /// Crests are at worst every other sample, so a 220 ms window holds under 90
    /// of them. 512 is four times the worst case and still 20 kB.
    static let capacity = 512

    private var ring: ContiguousArray<PairRescueCandidate>
    private var start = 0
    private var count = 0

    /// Delay line of `(tNs, envelope, threshold)`, long enough to test a crest
    /// `lookahead` samples after it happened: the test needs the sample before
    /// and the sample after the crest, so the line holds `lookahead + 2`.
    private var delayT: ContiguousArray<Int64>
    private var delayEnv: ContiguousArray<Double>
    private var delayThr: ContiguousArray<Double>
    private var delayHead = 0
    private var delayFilled = 0

    let lookahead: Int

    /// Sample index at which the live group's FIRST onset gets its polarization
    /// reading, i.e. that onset's index plus `lookahead`.
    private var anchorAxisDueIndex: Int?
    private var anchorUX = 0.0, anchorUY = 0.0, anchorUZ = 0.0
    private var anchorAxisValid = false

    init(lookahead: Int) {
        let l = max(1, min(lookahead, PolarizationTracker.maxWindow))
        self.lookahead = l
        ring = ContiguousArray(repeating: PairRescueCandidate(tNs: 0, amplitude: 0, threshold: 0,
                                                              rect: 0, ux: 0, uy: 0, uz: 0),
                               count: Self.capacity)
        delayT = ContiguousArray(repeating: 0, count: l + 2)
        delayEnv = ContiguousArray(repeating: 0, count: l + 2)
        delayThr = ContiguousArray(repeating: 0, count: l + 2)
    }

    mutating func reset() {
        start = 0
        count = 0
        delayHead = 0
        delayFilled = 0
        anchorAxisDueIndex = nil
        anchorAxisValid = false
        anchorUX = 0; anchorUY = 0; anchorUZ = 0
    }

    /// The live group's first onset landed on `index`. Its axis is read
    /// `lookahead` samples later, the same lag every buffered crest gets, so the
    /// two are measured the same way.
    mutating func armAnchor(atIndex index: Int) {
        anchorAxisDueIndex = index + lookahead
        anchorAxisValid = false
    }

    mutating func disarmAnchor() {
        anchorAxisDueIndex = nil
        anchorAxisValid = false
    }

    var hasAnchorAxis: Bool { anchorAxisValid }

    /// One sample. Advances the delay line, captures the anchor's axis when its
    /// lag comes due, and buffers a crest if the sample `lookahead` back was one.
    ///
    /// `retentionNs` drops crests too old for any live group to pair with. It is
    /// bookkeeping, not policy: the band test in `scan` would reject them anyway.
    mutating func observe(tNs: Int64, index: Int, envelope: Double, threshold: Double,
                          rect: Double, ux: Double, uy: Double, uz: Double,
                          candidateFraction: Double, retentionNs: Int64) {
        if let due = anchorAxisDueIndex, index >= due {
            anchorUX = ux; anchorUY = uy; anchorUZ = uz
            anchorAxisValid = true
            anchorAxisDueIndex = nil
        }

        let n = delayT.count
        delayT[delayHead] = tNs
        delayEnv[delayHead] = envelope
        delayThr[delayHead] = threshold
        delayHead = (delayHead + 1) % n
        if delayFilled < n { delayFilled += 1 }
        guard delayFilled == n, candidateFraction > 0 else { return }

        // Oldest entry is `delayHead`: that is the sample before the crest under
        // test. The crest itself is next, and the sample after it follows.
        let before = delayHead
        let at = (delayHead + 1) % n
        let after = (delayHead + 2) % n
        let e = delayEnv[at]
        guard e >= delayEnv[before], e > delayEnv[after], e >= candidateFraction * delayThr[at] else {
            return
        }

        let crest = PairRescueCandidate(tNs: delayT[at], amplitude: e, threshold: delayThr[at],
                                        rect: rect, ux: ux, uy: uy, uz: uz)
        evict(before: crest.tNs - retentionNs)
        append(crest)
    }

    /// The group closing at `now` holds exactly one member. Find the crest that
    /// best completes it, or nothing.
    ///
    /// Every rejection here is a rule the shipped detector already applies to an
    /// onset — the inter-tap band, the refractory, the input gate — plus the two
    /// this mechanism adds: the rectilinearity ceiling and the polarization
    /// coherence veto.
    ///
    /// The gate is read at the DEADLINE, not at the crest. That is stricter than
    /// reading it live and deliberately so: a keystroke whose HID event arrives
    /// after the chassis shock still retracts a crest that already happened, the
    /// same retroactive protection `preGateNs` gives an onset, and it costs
    /// nothing because the group has not fired yet.
    func scan(anchorTNs: Int64, anchorAmplitude: Double,
              minInterNs: Int64, maxInterNs: Int64,
              refractoryUntilNs: Int64, gateUntilNs: Int64,
              candidateFraction: Double, rectMax: Double, cosMin: Double,
              anchorFraction: Double,
              rankByRect: Bool) -> PairRescueCandidate? {
        if cosMin > 0 && !anchorAxisValid { return nil }
        var best: PairRescueCandidate?
        for k in 0..<count {
            let c = ring[(start + k) % Self.capacity]
            let delta = c.tNs - anchorTNs
            if delta < minInterNs || delta > maxInterNs { continue }
            if c.amplitude < candidateFraction * c.threshold { continue }
            if anchorFraction > 0 && c.amplitude < anchorFraction * anchorAmplitude { continue }
            if c.rect > rectMax { continue }
            if c.tNs < refractoryUntilNs || c.tNs < gateUntilNs { continue }
            if cosMin > 0 {
                let dot = abs(c.ux * anchorUX + c.uy * anchorUY + c.uz * anchorUZ)
                if dot < cosMin { continue }
            }
            guard let b = best else { best = c; continue }
            // Strictly better, so an exact tie keeps the earlier crest and the
            // choice does not depend on iteration order.
            if rankByRect ? (c.rect < b.rect) : (c.amplitude > b.amplitude) { best = c }
        }
        return best
    }

    // MARK: - Ring

    private mutating func append(_ c: PairRescueCandidate) {
        if count == Self.capacity {
            ring[start] = c
            start = (start + 1) % Self.capacity
        } else {
            ring[(start + count) % Self.capacity] = c
            count += 1
        }
    }

    private mutating func evict(before cutoffNs: Int64) {
        while count > 0, ring[start].tNs < cutoffNs {
            start = (start + 1) % Self.capacity
            count -= 1
        }
    }

    /// Buffered crests, for tests and for the harness's diagnostics.
    var bufferedCount: Int { count }

    /// Plant a crest directly. Tests only: it is the only way to pose the
    /// ranking question, since a synthetic waveform cannot produce two crests
    /// that differ in rectilinearity without also differing in half a dozen
    /// other things.
    mutating func insertForTesting(_ c: PairRescueCandidate) { append(c) }
}
