import Foundation

/// Result of the "learn my tap" step, with the working shown so the settings
/// panel can explain itself and the harness can log why a threshold moved.
public struct CalibrationResult: Sendable, Equatable {
    /// What to write into `DetectorConfig.calibratedThreshold`, in g.
    public var threshold: Double
    /// Low percentile of the recorded tap strengths, in g. The threshold is
    /// derived from this, not from the mean.
    public var lowPercentileStrength: Double
    public var weakestStrength: Double
    public var medianStrength: Double
    /// Noise floor observed while calibrating, in g. Zero if not supplied.
    public var noiseFloor: Double
    /// `weakestStrength / threshold`. Under ~1.3 means the user's weakest tap is
    /// uncomfortably close to the bar; ask for a firmer tap or a better surface.
    public var margin: Double
    /// Set when the noise floor, not the taps, decided the threshold.
    public var noiseLimited: Bool
    public var sampleCount: Int

    // MARK: - Learned gesture timing

    /// Join window fitted to the user's own inter-tap intervals, in ns. Nil when
    /// calibration saw no complete gestures to measure.
    ///
    /// The threshold was never the whole story. Measured across three surfaces,
    /// one operator: desk intervals run 168-199 ms, soft 149-371, lap 91-597.
    /// A shipped 220 ms window fits desk almost perfectly and misses 8 of 80 lap
    /// gestures outright — not because the taps were weak, but because the
    /// gesture is simply slower and more variable when the machine is on a lap.
    /// That is exactly the per-user, per-surface variation the PRD's
    /// learn-my-tap step exists to absorb, and nothing was writing it.
    public var interTapNs: Int64?
    /// The observed spread, so the panel can show why it chose what it chose.
    public var interTapP10Ns: Int64?
    public var interTapP90Ns: Int64?
    /// How loudly the chassis rings after a strike, as a fraction of that
    /// strike: the envelope 60-100 ms later divided by the strike's own peak.
    /// Nil when calibration could not measure it.
    ///
    /// This is the property that separates a lap that works from one that does
    /// not, and it is not the one you would guess. Measured across four lap
    /// sessions on one machine, tap amplitude (0.032-0.036 g), noise floor and
    /// decay time were effectively identical, and signal-to-noise ran BACKWARDS
    /// — the session that detected 100 % had the LOWEST SNR. What tracked
    /// detection was the ring:
    ///
    ///     ring/strike 0.30 -> 95 %      0.38 -> 90 %
    ///     ring/strike 0.42 -> 100 %     0.61 -> 80 %
    ///
    /// A second tap has to be heard over the first one's tail, so a chassis that
    /// returns 61 % of the strike is a chassis where half the gesture is
    /// competing with itself. Resting a forearm on the case while tapping is one
    /// way to produce it.
    public var ringToStrike: Double?

    /// True when the fitted window had to be cut to stay inside the latency
    /// budget. The user is then choosing between reliability and responsiveness
    /// and deserves to be told, rather than having it decided for them.
    public var interTapClamped: Bool

    public init(threshold: Double, lowPercentileStrength: Double, weakestStrength: Double,
                medianStrength: Double, noiseFloor: Double, margin: Double,
                noiseLimited: Bool, sampleCount: Int,
                interTapNs: Int64? = nil, interTapP10Ns: Int64? = nil,
                interTapP90Ns: Int64? = nil, interTapClamped: Bool = false,
                ringToStrike: Double? = nil) {
        self.threshold = threshold
        self.lowPercentileStrength = lowPercentileStrength
        self.weakestStrength = weakestStrength
        self.medianStrength = medianStrength
        self.noiseFloor = noiseFloor
        self.margin = margin
        self.noiseLimited = noiseLimited
        self.sampleCount = sampleCount
        self.interTapNs = interTapNs
        self.interTapP10Ns = interTapP10Ns
        self.interTapP90Ns = interTapP90Ns
        self.interTapClamped = interTapClamped
        self.ringToStrike = ringToStrike
    }
}

/// Derives an onset threshold from recorded taps.
///
/// ## The rule
///
///     aim   = percentileMargin * p20(strengths)      // 0.60 x the weak tail
///     reach = weakestMargin * min(strengths)         // 0.80 x the worst tap
///     guard = distributionFloor * median(strengths)  // 0.35 x typical
///
///     threshold = max( min(aim, max(reach, guard)),
///                      noiseSnrMultiple * noiseFloor,
///                      minThresholdG )
///
/// Strengths are `OnsetEvent.strength` in g, exactly what the detector publishes
/// and what the tap monitor shows, so the number is the same currency as
/// `DetectorConfig.defaultThreshold`.
///
/// ## Why in that shape
///
/// The pass line is 98 % detection, so the bar has to sit under nearly every tap
/// the user will produce, and ten calibration taps are a small and optimistic
/// sample: people tap harder when a dialog is watching. The mean would put the
/// bar above a third of real taps. The strict minimum would hand the whole
/// threshold to one glancing hit — on a synthetic set of nine taps at 0.70 g
/// plus one at 0.05 g, a minimum-based rule lands at 0.04 g, which is noise.
///
/// So: aim at 0.6 x the 20th percentile, which is the weak tail without being
/// hostage to a single dud. Then stretch down if needed so the weakest recorded
/// tap still clears the bar by 25 % — but never past 0.35 x the median, which is
/// the line where a tap stops being a tap and starts being a graze.
///
/// Going lower is not free: the false-trigger budget is zero for typing and for
/// the confound set. Two clamps stop the rule running away. The threshold never
/// drops under `noiseSnrMultiple` times the noise the machine is already living
/// in, nor under `minThresholdG` in absolute terms. When a clamp bites,
/// `noiseLimited` is set and the UI should say so: the surface, not the tap, is
/// the problem.
///
/// Every constant here is a guess pending the recorded dataset. They are named
/// and public so the scoring harness can sweep them against real taps.
public enum TapCalibration {

    public static let lowPercentile: Double = 0.20
    public static let percentileMargin: Double = 0.60
    /// How far under the weakest recorded tap the threshold is allowed to reach.
    public static let weakestMargin: Double = 0.80
    /// Hard stop on that reach, as a fraction of the median tap.
    public static let distributionFloor: Double = 0.35
    /// Below this the weakest recorded tap is too close to the bar to trust.
    public static let comfortableMargin: Double = 1.30

    /// Ring-to-strike ratio above which detection has been measured to fall.
    /// The four lap sessions split 0.30/0.38/0.42 at 90-100 % against 0.61 at
    /// 80 %, so the line is drawn between them rather than fitted to them.
    public static let noisyRingRatio: Double = 0.50

    /// - Parameters:
    ///   - tapStrengths: `OnsetEvent.strength` for each recorded calibration
    ///     tap, in g. Non-positive entries are dropped.
    ///   - noiseFloor: the detector's `noiseFloor` observed during calibration,
    ///     in g. Pass 0 if unknown; the absolute clamp still applies.
    ///   - tuning: supplies the two clamp constants only.
    /// - Returns: nil if there is nothing usable to calibrate from.
    public static func calibrate(tapStrengths: [Double],
                                 noiseFloor: Double = 0,
                                 tuning: DSPTuning = .default) -> CalibrationResult? {
        let strengths = tapStrengths.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !strengths.isEmpty else { return nil }

        let p20 = percentile(strengths, lowPercentile)
        let median = percentile(strengths, 0.5)
        let aim = percentileMargin * p20
        let reach = weakestMargin * strengths[0]
        let distributionGuard = distributionFloor * median
        let raw = min(aim, max(reach, distributionGuard))

        let clamp = max(tuning.noiseSnrMultiple * max(noiseFloor, 0), tuning.minThresholdG)
        let threshold = max(raw, clamp)

        return CalibrationResult(
            threshold: threshold,
            lowPercentileStrength: p20,
            weakestStrength: strengths[0],
            medianStrength: median,
            noiseFloor: max(noiseFloor, 0),
            margin: threshold > 0 ? strengths[0] / threshold : .infinity,
            noiseLimited: clamp > raw,
            sampleCount: strengths.count,
            interTapNs: nil,
            interTapP10Ns: nil,
            interTapP90Ns: nil,
            interTapClamped: false
        )
    }

    /// Widest join window the latency bar allows, in ns.
    ///
    /// The window IS the latency: a gesture fires one confirm window after its
    /// last onset, and `maxInterTapNs <= confirmWindowNs` is enforced. The PRD's
    /// p95 budget is 250 ms and the measured overhead above the window is about
    /// 1 ms at p50, so 235 ms leaves honest headroom.
    public static let latencySafeWindowNs: Int64 = 235_000_000

    /// Absolute ceiling when the user knowingly trades responsiveness for
    /// reliability. Beyond this the gesture stops feeling like a double-tap.
    public static let maxWindowNs: Int64 = 400_000_000

    /// Fit the join window to the user's own gesture, from the intervals
    /// observed during calibration.
    ///
    /// Aims at the 90th percentile plus a small margin, so nine gestures in ten
    /// land inside the window with room, rather than at the median, which would
    /// leave half of them outside.
    ///
    /// - Parameter allowExceedingLatencyBudget: when false the result is capped
    ///   at `latencySafeWindowNs` and `interTapClamped` says so. The caller is
    ///   expected to surface that rather than swallow it: on a lap this operator
    ///   produced intervals up to 597 ms, and honouring them costs latency the
    ///   PRD's bar does not have.
    public static func fitInterTap(intervalsNs: [Int64],
                                   allowExceedingLatencyBudget: Bool = false,
                                   minimumNs: Int64 = 100_000_000) -> (window: Int64,
                                                                       p10: Int64,
                                                                       p90: Int64,
                                                                       clamped: Bool)? {
        let v = intervalsNs.filter { $0 > 0 }.sorted()
        guard v.count >= 3 else { return nil }
        func pct(_ p: Double) -> Int64 {
            v[min(v.count - 1, Int((Double(v.count - 1) * p).rounded()))]
        }
        let p90 = pct(0.90)
        let aim = Int64(Double(p90) * 1.15)
        let ceiling = allowExceedingLatencyBudget ? maxWindowNs : latencySafeWindowNs
        let window = max(minimumNs, min(aim, ceiling))
        return (window, pct(0.10), p90, aim > ceiling)
    }

    /// Convenience: apply a calibration to a config without touching anything
    /// else the settings panel owns.
    public static func apply(_ result: CalibrationResult, to config: DetectorConfig) -> DetectorConfig {
        var out = config
        out.calibratedThreshold = result.threshold
        // The learned window, when calibration measured complete gestures.
        // `maxInterTapNs <= confirmWindowNs` is the invariant, and the window is
        // the latency, so both move together — writing one and not the other
        // would be clamped straight back by madeCoherent().
        if let interTap = result.interTapNs {
            out.calibratedInterTapNs = interTap
            out.maxInterTapNs = interTap
            out.confirmWindowNs = interTap
            // A hand-raised minimum above the observed cadence leaves no band
            // for the gesture just calibrated: madeCoherent() clamps min == max
            // and it can never group again. Lower it to fit, with the same 15 %
            // margin the window gets above p90, never under the onset debounce.
            if let p10 = result.interTapP10Ns {
                let floor = max(DSPTuning.default.onsetDebounceNs, Int64(Double(p10) / 1.15))
                out.minInterTapNs = min(out.minInterTapNs, floor)
            }
        }
        return out
    }

    /// Widest gap that can still be two halves of one gesture, for grouping
    /// calibration onsets. Deliberately far wider than any window that will be
    /// fitted: the point is to *observe* how slowly this user actually taps,
    /// including intervals the shipped window would reject. Fitting against a
    /// span that already assumed the answer would only ever confirm it.
    public static let gestureSpanNs: Int64 = 600_000_000

    /// Turn a flat run of calibration onsets into gestures.
    ///
    /// Only pairs are used for timing. A run of three or more inside one span is
    /// ambiguous — a fumble, or a damped case ringing loudly enough to publish a
    /// second lobe as an onset — and learning a window from it would bake that
    /// artifact into the user's config. Their strengths still count toward the
    /// threshold; only their timing is discarded.
    ///
    /// - Parameters:
    ///   - onsetTimesNs: ascending onset times.
    ///   - strengths: same order and count as `onsetTimesNs`.
    public static func gestures(onsetTimesNs: [Int64], strengths: [Double],
                                spanNs: Int64 = gestureSpanNs)
        -> [(strengths: [Double], intervalNs: Int64)] {
        guard onsetTimesNs.count == strengths.count, !onsetTimesNs.isEmpty else { return [] }
        var runs: [[Int]] = [[0]]
        for i in 1..<onsetTimesNs.count {
            if onsetTimesNs[i] - onsetTimesNs[i - 1] <= spanNs {
                runs[runs.count - 1].append(i)
            } else {
                runs.append([i])
            }
        }
        return runs.map { run in
            let s = run.map { strengths[$0] }
            // 0 means "no timing from this run"; fitInterTap drops non-positive.
            let interval: Int64 = run.count == 2 ? onsetTimesNs[run[1]] - onsetTimesNs[run[0]] : 0
            return (strengths: s, intervalNs: interval)
        }
    }

    /// Calibrate from complete gestures rather than loose strengths, so the
    /// timing can be learned alongside the threshold.
    ///
    /// - Parameter gestures: one entry per recorded double-tap: the strength of
    ///   each onset, and the interval between them.
    public static func calibrate(gestures: [(strengths: [Double], intervalNs: Int64)],
                                 noiseFloor: Double = 0,
                                 allowExceedingLatencyBudget: Bool = false,
                                 ringRatios: [Double] = [],
                                 tuning: DSPTuning = .default) -> CalibrationResult? {
        guard var result = calibrate(tapStrengths: gestures.flatMap(\.strengths),
                                     noiseFloor: noiseFloor, tuning: tuning) else { return nil }
        if let fit = fitInterTap(intervalsNs: gestures.map(\.intervalNs),
                                 allowExceedingLatencyBudget: allowExceedingLatencyBudget) {
            result.interTapNs = fit.window
            result.interTapP10Ns = fit.p10
            result.interTapP90Ns = fit.p90
            result.interTapClamped = fit.clamped
        }
        let usable = ringRatios.filter { $0.isFinite && $0 > 0 }.sorted()
        if !usable.isEmpty { result.ringToStrike = percentile(usable, 0.5) }
        return result
    }

    /// Linear-interpolated percentile of an ascending array.
    public static func percentile(_ ascending: [Double], _ q: Double) -> Double {
        guard let first = ascending.first else { return 0 }
        guard ascending.count > 1 else { return first }
        let clamped = min(max(q, 0), 1)
        let position = clamped * Double(ascending.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, ascending.count - 1)
        let fraction = position - Double(lower)
        return ascending[lower] + (ascending[upper] - ascending[lower]) * fraction
    }
}
