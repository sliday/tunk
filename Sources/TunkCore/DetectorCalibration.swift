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

    public init(threshold: Double, lowPercentileStrength: Double, weakestStrength: Double,
                medianStrength: Double, noiseFloor: Double, margin: Double,
                noiseLimited: Bool, sampleCount: Int) {
        self.threshold = threshold
        self.lowPercentileStrength = lowPercentileStrength
        self.weakestStrength = weakestStrength
        self.medianStrength = medianStrength
        self.noiseFloor = noiseFloor
        self.margin = margin
        self.noiseLimited = noiseLimited
        self.sampleCount = sampleCount
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
            sampleCount: strengths.count
        )
    }

    /// Convenience: apply a calibration to a config without touching anything
    /// else the settings panel owns.
    public static func apply(_ result: CalibrationResult, to config: DetectorConfig) -> DetectorConfig {
        var out = config
        out.calibratedThreshold = result.threshold
        return out
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
