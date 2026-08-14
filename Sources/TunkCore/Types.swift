import Foundation

// Frozen vocabulary shared by the sensor source, the detector, the capture tool,
// the scoring harness and the app. See FORMAT.md. Changing anything public here
// means editing FORMAT.md first.

/// One accelerometer reading. `tNs` is the device timestamp; `arrivalNs` is when
/// the callback ran. Both are nanoseconds since the session epoch, same timebase.
public struct AccelSample: Sendable, Equatable {
    public var tNs: Int64
    public var arrivalNs: Int64
    public var x: Float
    public var y: Float
    public var z: Float

    public init(tNs: Int64, arrivalNs: Int64, x: Float, y: Float, z: Float) {
        self.tNs = tNs
        self.arrivalNs = arrivalNs
        self.x = x
        self.y = y
        self.z = z
    }

    /// Record size on disk, per FORMAT.md. Asserted by the reader and writer.
    public static let byteWidth = 28
}

public enum InputEventKind: String, Sendable, Codable, CaseIterable {
    case keyDown = "key_down"
    case keyUp = "key_up"
    case flagsChanged = "flags_changed"
    case mouseDown = "mouse_down"
    case mouseUp = "mouse_up"
    case mouseMoved = "mouse_moved"
    case scroll
    case trackpadTouch = "trackpad_touch"

    /// Whether this kind arms the suppression gate. Mouse movement alone does
    /// not shake the chassis; presses and touches do.
    public var gatesDetection: Bool {
        switch self {
        case .keyDown, .keyUp, .flagsChanged, .mouseDown, .mouseUp, .trackpadTouch:
            return true
        case .mouseMoved, .scroll:
            return false
        }
    }
}

public struct InputEvent: Sendable, Equatable {
    public var tNs: Int64
    public var kind: InputEventKind
    /// Key code or button index. Recorded for repeat detection only; never used
    /// to reconstruct text.
    public var code: Int32

    public init(tNs: Int64, kind: InputEventKind, code: Int32 = -1) {
        self.tNs = tNs
        self.kind = kind
        self.code = code
    }
}

/// A confirmed multi-tap gesture.
public struct Trigger: Sendable, Equatable {
    /// When the detector decided. Latency is measured against `tapOnsets.last`.
    public var tNs: Int64
    /// Onsets that made up the gesture, ascending.
    public var tapOnsets: [Int64]
    /// Detector confidence, for the tap monitor readout and for tuning curves.
    public var score: Double

    public init(tNs: Int64, tapOnsets: [Int64], score: Double) {
        self.tNs = tNs
        self.tapOnsets = tapOnsets
        self.score = score
    }

    public var tapCount: Int { tapOnsets.count }
}

/// An onset the detector accepted, whether or not it became a trigger. The tap
/// monitor in Settings shows these so the user can see the sensor responding.
public struct OnsetEvent: Sendable, Equatable {
    public var tNs: Int64
    public var strength: Double
    public var suppressedByGate: Bool

    public init(tNs: Int64, strength: Double, suppressedByGate: Bool) {
        self.tNs = tNs
        self.strength = strength
        self.suppressedByGate = suppressedByGate
    }
}

/// Everything tunable. The settings panel writes this; the detector reads only
/// this. No detector code reads defaults on its own.
public struct DetectorConfig: Sendable, Equatable, Codable {
    /// Onset threshold, in units of the calibrated tap statistic. Calibration
    /// sets `calibratedThreshold`; `sensitivity` scales it (1.0 = as calibrated,
    /// lower = more sensitive).
    public var sensitivity: Double
    /// Absolute onset threshold derived from the "learn my tap" step. Nil means
    /// uncalibrated; the detector then falls back to `defaultThreshold`.
    public var calibratedThreshold: Double?

    /// Pre-calibration threshold, in g. **0.030, fitted to real taps.**
    ///
    /// It was 0.30 — invented before any recording existed — and the first real
    /// session showed that value missing every onset. Measured over 40 labelled
    /// onsets, one operator, hard desk: amplitude 0.0456 to 0.1326 g, median
    /// 0.0842, noise floor 0.00101 g. The weakest deliberate tap is 45x the
    /// floor, so the signal was never marginal; the threshold was in the wrong
    /// place.
    ///
    /// Swept against 29.9 minutes of real ambient and confound recordings, so
    /// detection and false triggers move together rather than one being traded
    /// blindly for the other:
    ///
    ///     threshold  detection        false triggers      margin below
    ///                                                     weakest real tap
    ///     0.300      0.00 % (0/22)    0.00                —
    ///     0.060      95.45 %          0.00                —
    ///     0.045      100.00 %         0.00                 1 %
    ///     0.035      100.00 %         0.00                23 %
    ///     0.030      100.00 %         0.00                34 %
    ///     0.025      100.00 %         0.00                45 %
    ///     0.020      100.00 %         0.67 per 20 min     56 %
    ///
    /// 0.045 was chosen first and was a mistake: it sits 1 % under the weakest
    /// tap ever observed, so a single slightly softer tap is missed and there is
    /// no headroom at all. The honest reading of the sweep is that the usable
    /// band runs from just above 0.020, where false triggers appear, to about
    /// 0.045, where detection headroom runs out. 0.030 sits near the middle of
    /// it: a third of the way below the weakest real tap, and half again above
    /// where the ambient recordings start firing.
    ///
    /// Still one person, one surface, one tap location, one session. Calibration
    /// should replace it per user, and soft and lap surfaces will very likely
    /// move it — coupling is the thing that changes most between surfaces.
    public var defaultThreshold: Double

    /// Suppress onsets for this long after any gating input event.
    public var gateWindowNs: Int64
    /// Minimum spacing between the two onsets of a double-tap.
    ///
    /// Must be at least `DSPTuning.onsetDebounceNs`, or it describes a gesture
    /// the front end cannot produce: onsets closer than the debounce are merged
    /// into one, so a "legal" band below it is unreachable config. Raised to
    /// 100 ms when the debounce moved there to fix soft-surface detection. The
    /// shortest interval this operator has ever produced is 149 ms.
    public var minInterTapNs: Int64
    public var maxInterTapNs: Int64
    /// After the last accepted onset, wait this long before firing, so a further
    /// tap can still join the group.
    ///
    /// This window does two jobs, and the second is why it cannot be shortened
    /// to nothing even while triple-tap is unwired: it distinguishes a double
    /// from a triple, and it rejects a continuous knock train. Without it, bass
    /// through a desk fires repeatedly.
    ///
    /// The invariant `maxInterTapNs <= confirmWindowNs` is enforced, because a
    /// tap that arrives after the group has already fired cannot retract it.
    /// Waiting longer than `maxInterTapNs` buys nothing and costs latency, so
    /// the two are equal by default.
    public var confirmWindowNs: Int64
    /// Ignore further onsets for this long after a trigger.
    public var refractoryNs: Int64

    /// Tap counts that fire an action. A gesture whose count is not armed is
    /// still reported to the tap monitor, but fires nothing.
    ///
    /// Single tap is a different risk class from double: every mug set down and
    /// every footfall is one transient, whereas requiring two deliberate onsets
    /// in a narrow window is the whole false-positive defence. Arm 1 only
    /// deliberately, and read the harness's per-count false-trigger numbers first.
    public var armedTapCounts: Set<Int>

    /// Upper bound on onset strength, in g. An onset stronger than this is not a
    /// tap and is discarded.
    ///
    /// A deliberate tap has a *bounded* amplitude — a fingertip can only put so
    /// much into a chassis. Picking the machine up, setting it down hard, or
    /// closing the lid puts in far more. Without a ceiling the detector treats
    /// "enormous" as "very confidently a tap", which is backwards, and moving the
    /// laptop reads as a gesture.
    ///
    /// Nil disables the ceiling. Calibration should set it from the observed tap
    /// distribution with generous headroom, since a hard tap on a soft surface
    /// and a light tap on a hard one differ by a lot.
    public var onsetCeilingG: Double?

    /// How far the chassis's settled acceleration may drift, in g, before onsets
    /// are suppressed as movement rather than taps.
    ///
    /// The guard the ceiling cannot provide. A ceiling rejects a strike harder
    /// than a fingertip; it does nothing about a laptop being lifted, where the
    /// individual rings are perfectly tap-sized. What separates those is that a
    /// tap leaves the resting attitude where it found it and a lift does not.
    ///
    /// 0.030 g is measured, by sweeping the real detector over synthetic lifts
    /// and taps. Triggers produced, ceiling disabled to isolate the gate:
    ///
    ///     gate      lift .35/.2s  lift .35/.6s  lift .6/1s   tap 0.9 g  tap 3 g
    ///     0.020        0             0             0            0          0
    ///     0.030        0             0             0            1          1
    ///     0.050        0             1             1            1          1
    ///
    /// **It ships DISABLED (0) anyway**, because a second measurement killed it.
    ///
    /// The window is already narrow — at 0.020 the gate eats deliberate taps, at
    /// 0.050 lifts get through, so 0.030 sits in a valley about 0.01 g wide.
    /// Then the existing suite found the real problem:
    /// `testALoudSurfaceDoesNotDeafenTheDetector` dropped from 10 deliberate
    /// doubles landing to 6. On a surface that is genuinely alive — a lap, a
    /// desk carrying a subwoofer — the settled magnitude wanders, the gate reads
    /// that as movement, and it deafens the detector in exactly the conditions
    /// the PRD lists as required.
    ///
    /// Trading a false trigger for a detector that ignores 40 % of taps on a lap
    /// is a bad trade, so the number stays 0 until real recordings of a laptop
    /// being moved exist to set it from. The `confound_handling` capture
    /// category is for precisely this, and a gate scaled against the adaptive
    /// noise floor rather than a fixed g value is the obvious next attempt.
    ///
    /// Zero disables the gate.
    public var motionGateG: Double

    /// Inter-tap interval learned from the user's own taps during calibration.
    /// Coupling and cadence vary per person and per surface far more than any
    /// shipped constant can cover. Nil until calibrated.
    public var calibratedInterTapNs: Int64?

    /// Legacy single-count accessor. Reads the lowest armed count; writing it
    /// replaces the armed set. Kept so existing call sites keep working while
    /// callers migrate to `armedTapCounts` — there is still exactly one stored
    /// source of truth.
    public var tapCountToFire: Int {
        get { armedTapCounts.min() ?? 2 }
        set { armedTapCounts = [newValue] }
    }

    /// Shipped defaults, before calibration.
    ///
    /// `maxInterTapNs == confirmWindowNs == 220 ms` is a compromise between two
    /// things pulling opposite ways, and it is the number most likely to move
    /// once real taps exist:
    ///
    /// - Latency is essentially the confirm window, and the PRD's p95 budget is
    ///   250 ms. That caps the window at roughly 240 ms.
    /// - A double-tap slower than the window does not group at all, so too tight
    ///   a value silently costs detection rate on people who tap deliberately
    ///   rather than quickly.
    ///
    /// 220 ms leaves 30 ms of headroom under the budget while covering an
    /// unhurried double-tap. Calibration should replace it with the user's own
    /// measured interval — that is exactly the per-person variation the PRD's
    /// "learn my tap" step exists to absorb.
    public static let `default` = DetectorConfig(
        sensitivity: 1.0,
        calibratedThreshold: nil,
        defaultThreshold: 0.030,
        gateWindowNs: 180_000_000,
        minInterTapNs: 100_000_000,
        maxInterTapNs: 220_000_000,
        confirmWindowNs: 220_000_000,
        refractoryNs: 600_000_000,
        armedTapCounts: [2],
        onsetCeilingG: 2.5,
        motionGateG: 0
    )

    public init(sensitivity: Double, calibratedThreshold: Double?, defaultThreshold: Double,
                gateWindowNs: Int64, minInterTapNs: Int64, maxInterTapNs: Int64,
                confirmWindowNs: Int64, refractoryNs: Int64,
                armedTapCounts: Set<Int> = [2],
                onsetCeilingG: Double? = 2.5,
                motionGateG: Double = 0,
                calibratedInterTapNs: Int64? = nil) {
        self.sensitivity = sensitivity
        self.calibratedThreshold = calibratedThreshold
        self.defaultThreshold = defaultThreshold
        self.gateWindowNs = gateWindowNs
        self.minInterTapNs = minInterTapNs
        self.maxInterTapNs = maxInterTapNs
        self.confirmWindowNs = confirmWindowNs
        self.refractoryNs = refractoryNs
        self.armedTapCounts = armedTapCounts
        self.onsetCeilingG = onsetCeilingG
        self.motionGateG = motionGateG
        self.calibratedInterTapNs = calibratedInterTapNs
    }

    /// Compatibility initialiser for call sites still passing a single count.
    public init(sensitivity: Double, calibratedThreshold: Double?, defaultThreshold: Double,
                gateWindowNs: Int64, minInterTapNs: Int64, maxInterTapNs: Int64,
                confirmWindowNs: Int64, refractoryNs: Int64, tapCountToFire: Int) {
        self.init(sensitivity: sensitivity, calibratedThreshold: calibratedThreshold,
                  defaultThreshold: defaultThreshold, gateWindowNs: gateWindowNs,
                  minInterTapNs: minInterTapNs, maxInterTapNs: maxInterTapNs,
                  confirmWindowNs: confirmWindowNs, refractoryNs: refractoryNs,
                  armedTapCounts: [tapCountToFire])
    }

    // MARK: - Codable

    // Hand-rolled so a settings file written before armed sets existed still
    // loads. Resetting someone's configuration on upgrade is not acceptable.
    private enum CodingKeys: String, CodingKey {
        case sensitivity, calibratedThreshold, defaultThreshold
        case gateWindowNs, minInterTapNs, maxInterTapNs, confirmWindowNs, refractoryNs
        case armedTapCounts, calibratedInterTapNs, onsetCeilingG, motionGateG
        case tapCountToFire   // legacy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectorConfig.default
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
        calibratedThreshold = try c.decodeIfPresent(Double.self, forKey: .calibratedThreshold)
        defaultThreshold = try c.decodeIfPresent(Double.self, forKey: .defaultThreshold) ?? d.defaultThreshold
        gateWindowNs = try c.decodeIfPresent(Int64.self, forKey: .gateWindowNs) ?? d.gateWindowNs
        minInterTapNs = try c.decodeIfPresent(Int64.self, forKey: .minInterTapNs) ?? d.minInterTapNs
        maxInterTapNs = try c.decodeIfPresent(Int64.self, forKey: .maxInterTapNs) ?? d.maxInterTapNs
        confirmWindowNs = try c.decodeIfPresent(Int64.self, forKey: .confirmWindowNs) ?? d.confirmWindowNs
        refractoryNs = try c.decodeIfPresent(Int64.self, forKey: .refractoryNs) ?? d.refractoryNs
        calibratedInterTapNs = try c.decodeIfPresent(Int64.self, forKey: .calibratedInterTapNs)
        onsetCeilingG = try c.decodeIfPresent(Double.self, forKey: .onsetCeilingG) ?? d.onsetCeilingG
        motionGateG = try c.decodeIfPresent(Double.self, forKey: .motionGateG) ?? d.motionGateG
        if let armed = try c.decodeIfPresent(Set<Int>.self, forKey: .armedTapCounts) {
            armedTapCounts = armed
        } else if let legacy = try c.decodeIfPresent(Int.self, forKey: .tapCountToFire) {
            armedTapCounts = [legacy]
        } else {
            armedTapCounts = d.armedTapCounts
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encodeIfPresent(calibratedThreshold, forKey: .calibratedThreshold)
        try c.encode(defaultThreshold, forKey: .defaultThreshold)
        try c.encode(gateWindowNs, forKey: .gateWindowNs)
        try c.encode(minInterTapNs, forKey: .minInterTapNs)
        try c.encode(maxInterTapNs, forKey: .maxInterTapNs)
        try c.encode(confirmWindowNs, forKey: .confirmWindowNs)
        try c.encode(refractoryNs, forKey: .refractoryNs)
        try c.encode(armedTapCounts, forKey: .armedTapCounts)
        try c.encodeIfPresent(calibratedInterTapNs, forKey: .calibratedInterTapNs)
        try c.encodeIfPresent(onsetCeilingG, forKey: .onsetCeilingG)
        try c.encode(motionGateG, forKey: .motionGateG)
        // Written too, so a settings file stays readable by an older build
        // rather than silently losing the user's tap count on a downgrade.
        try c.encode(tapCountToFire, forKey: .tapCountToFire)
    }

    /// The threshold actually applied, after calibration and the sensitivity slider.
    public var effectiveThreshold: Double {
        (calibratedThreshold ?? defaultThreshold) * sensitivity
    }
}

/// The detector contract. One implementation, used identically by the live app
/// and by the offline harness.
///
/// Rules the implementation must obey, asserted by the harness:
/// - advances only on `ingest`, never on a timer or `Date()`
/// - `tNs` values arrive non-decreasing
/// - identical input produces identical output, run to run
public protocol TapDetecting: AnyObject {
    var config: DetectorConfig { get set }

    /// The tap counts this detector will actually fire on, right now.
    ///
    /// Part of the protocol rather than one implementation's detail because the
    /// scoring harness compares it against what it is grading, and refuses to
    /// grade when they disagree. That check existed once as a cast to the
    /// concrete type with a fallback to `config.armedTapCounts` — which is
    /// exactly what it was meant to verify, so a stub reading the lossy
    /// `tapCountToFire` accessor sailed through while armed for one count and
    /// graded against three. A detector has to answer for itself.
    var effectiveArmedTapCounts: Set<Int> { get }

    /// Feed one accelerometer sample. Returns a trigger if this sample completed
    /// a gesture.
    func ingest(sample: AccelSample) -> Trigger?

    /// Feed one input-activity event, which may arm the suppression gate.
    func ingest(input: InputEvent)

    /// Onsets seen since the last drain, for the tap monitor. Draining is not
    /// required for correctness.
    func drainOnsets() -> [OnsetEvent]

    /// Drop all history. Called on sensor reconnect and when config changes in a
    /// way that invalidates state.
    func reset()
}
