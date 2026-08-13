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
    public var defaultThreshold: Double

    /// Suppress onsets for this long after any gating input event.
    public var gateWindowNs: Int64
    /// Minimum and maximum spacing between the two onsets of a double-tap.
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
        defaultThreshold: 0.30,
        gateWindowNs: 180_000_000,
        minInterTapNs: 80_000_000,
        maxInterTapNs: 220_000_000,
        confirmWindowNs: 220_000_000,
        refractoryNs: 600_000_000,
        armedTapCounts: [2]
    )

    public init(sensitivity: Double, calibratedThreshold: Double?, defaultThreshold: Double,
                gateWindowNs: Int64, minInterTapNs: Int64, maxInterTapNs: Int64,
                confirmWindowNs: Int64, refractoryNs: Int64,
                armedTapCounts: Set<Int> = [2],
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
        case armedTapCounts, calibratedInterTapNs
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
