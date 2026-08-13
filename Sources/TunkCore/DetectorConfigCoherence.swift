import Foundation

/// Coherence rules for `DetectorConfig`.
///
/// `DetectorConfig` is a frozen bag of plain numbers, so nothing in the type
/// itself stops a settings panel, a preferences file or a harness sweep from
/// writing a combination that cannot mean anything. One of those combinations
/// was a shipped bug, so the rules live here rather than in a comment.
///
/// ## The invariant that matters
///
///     minInterTapNs <= maxInterTapNs <= confirmWindowNs
///
/// A group fires one confirm window after its **last** onset. If a later onset
/// could still legally chain onto the group after that deadline — which is
/// exactly what `maxInterTapNs > confirmWindowNs` means — then the group fires
/// before the gesture is over and nothing can retract it. Measured on a
/// synthetic 60 s stream of 0.5 g thumps with `maxInterTapNs = 400 ms` and
/// `confirmWindowNs = 180 ms`: 48 triggers at 250 ms spacing and 60 at 200 ms,
/// with no input events to gate them. Every rhythmic disturbance in the PRD's
/// confound list — bass through the desk, footfall on a timber floor — lands in
/// that shape.
///
/// With the invariant held, an onset that can extend a group always arrives
/// before that group's deadline, so "two knocks then silence" and "a stream of
/// knocks at double-tap cadence" become different things: the first is a group
/// of two, the second is one long group whose count matches no bound action.
///
/// ## Clamped, not rejected
///
/// `madeCoherent()` returns a corrected copy and `coherenceIssues` says what it
/// changed and why. The detector clamps on every config write, so an incoherent
/// config is impossible to run even if it is possible to store; the UI should
/// surface `coherenceIssues` so the number the user typed does not silently
/// disagree with the number in force (read `TapDetector.effectiveConfig` for
/// that one).
///
/// The clamp direction is deliberate: `maxInterTapNs` comes down to meet
/// `confirmWindowNs`, rather than the confirm window going up to meet it.
/// Raising the confirm window would raise the latency of every gesture, and the
/// PRD's p95 budget from last onset to emitted key is 250 ms. Widening the tap
/// spacing a user is allowed costs nothing but a slightly brisker double-tap.
extension DetectorConfig {

    /// Tap counts the state machine can distinguish and bind. Groups outside
    /// this range fire nothing, whatever is bound.
    public static let supportedTapCounts: ClosedRange<Int> = 1...3

    /// Ceiling on any window, so a wild value cannot overflow a deadline
    /// computed as `onset + window`.
    public static let maxWindowNs: Int64 = 10_000_000_000

    /// One thing `madeCoherent()` had to change, in words the settings panel can
    /// show without translating.
    public struct CoherenceIssue: Sendable, Equatable, CustomStringConvertible {
        public var field: String
        public var reason: String
        public var applied: String

        public init(field: String, reason: String, applied: String) {
            self.field = field
            self.reason = reason
            self.applied = applied
        }

        public var description: String { "\(field): \(reason). Using \(applied)." }
    }

    /// What is wrong with this config, empty if nothing is.
    public var coherenceIssues: [CoherenceIssue] { Self.resolve(self).issues }

    public var isCoherent: Bool { coherenceIssues.isEmpty }

    /// A copy that obeys every rule above. Idempotent: the result is coherent.
    public func madeCoherent() -> DetectorConfig { Self.resolve(self).config }

    // MARK: - The single pass both sides read from

    private static func resolve(_ input: DetectorConfig) -> (config: DetectorConfig, issues: [CoherenceIssue]) {
        var out = input
        var issues: [CoherenceIssue] = []

        func ms(_ ns: Int64) -> String { "\(ns / 1_000_000) ms" }

        func clampWindow(_ value: Int64, _ field: String) -> Int64 {
            if value < 0 {
                issues.append(CoherenceIssue(field: field, reason: "negative window", applied: "0 ms"))
                return 0
            }
            if value > maxWindowNs {
                issues.append(CoherenceIssue(field: field,
                                             reason: "window over \(ms(maxWindowNs))",
                                             applied: ms(maxWindowNs)))
                return maxWindowNs
            }
            return value
        }

        out.gateWindowNs = clampWindow(out.gateWindowNs, "gateWindowNs")
        out.refractoryNs = clampWindow(out.refractoryNs, "refractoryNs")
        out.confirmWindowNs = clampWindow(out.confirmWindowNs, "confirmWindowNs")
        out.maxInterTapNs = clampWindow(out.maxInterTapNs, "maxInterTapNs")
        out.minInterTapNs = clampWindow(out.minInterTapNs, "minInterTapNs")

        if out.maxInterTapNs > out.confirmWindowNs {
            issues.append(CoherenceIssue(
                field: "maxInterTapNs",
                reason: "a tap \(ms(out.maxInterTapNs)) after the last one would arrive "
                      + "after the group had already fired at \(ms(out.confirmWindowNs))",
                applied: ms(out.confirmWindowNs)))
            out.maxInterTapNs = out.confirmWindowNs
        }

        if out.minInterTapNs > out.maxInterTapNs {
            issues.append(CoherenceIssue(
                field: "minInterTapNs",
                reason: "no spacing can be both over \(ms(out.minInterTapNs)) "
                      + "and under \(ms(out.maxInterTapNs))",
                applied: ms(out.maxInterTapNs)))
            out.minInterTapNs = out.maxInterTapNs
        }

        if !supportedTapCounts.contains(out.tapCountToFire) {
            let clamped = min(max(out.tapCountToFire, supportedTapCounts.lowerBound),
                              supportedTapCounts.upperBound)
            issues.append(CoherenceIssue(
                field: "tapCountToFire",
                reason: "only \(supportedTapCounts.lowerBound)...\(supportedTapCounts.upperBound) "
                      + "taps can be told apart",
                applied: "\(clamped)"))
            out.tapCountToFire = clamped
        }

        if !(out.sensitivity.isFinite && out.sensitivity > 0) {
            issues.append(CoherenceIssue(field: "sensitivity",
                                         reason: "not a positive number",
                                         applied: "1.0"))
            out.sensitivity = 1.0
        }

        if !(out.defaultThreshold.isFinite && out.defaultThreshold > 0) {
            issues.append(CoherenceIssue(field: "defaultThreshold",
                                         reason: "not a positive threshold in g",
                                         applied: "\(DetectorConfig.default.defaultThreshold)"))
            out.defaultThreshold = DetectorConfig.default.defaultThreshold
        }

        if let calibrated = out.calibratedThreshold, !(calibrated.isFinite && calibrated > 0) {
            issues.append(CoherenceIssue(field: "calibratedThreshold",
                                         reason: "not a positive threshold in g",
                                         applied: "uncalibrated"))
            out.calibratedThreshold = nil
        }

        return (out, issues)
    }
}
