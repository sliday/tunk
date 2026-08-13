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
    /// After the last accepted onset, wait this long before firing, so that a
    /// third tap can be recognised later without changing how double feels.
    public var confirmWindowNs: Int64
    /// Ignore further onsets for this long after a trigger.
    public var refractoryNs: Int64
    /// How many taps to fire on. Only 2 is wired today.
    public var tapCountToFire: Int

    public static let `default` = DetectorConfig(
        sensitivity: 1.0,
        calibratedThreshold: nil,
        defaultThreshold: 0.30,
        gateWindowNs: 180_000_000,
        minInterTapNs: 80_000_000,
        maxInterTapNs: 400_000_000,
        confirmWindowNs: 180_000_000,
        refractoryNs: 600_000_000,
        tapCountToFire: 2
    )

    public init(sensitivity: Double, calibratedThreshold: Double?, defaultThreshold: Double,
                gateWindowNs: Int64, minInterTapNs: Int64, maxInterTapNs: Int64,
                confirmWindowNs: Int64, refractoryNs: Int64, tapCountToFire: Int) {
        self.sensitivity = sensitivity
        self.calibratedThreshold = calibratedThreshold
        self.defaultThreshold = defaultThreshold
        self.gateWindowNs = gateWindowNs
        self.minInterTapNs = minInterTapNs
        self.maxInterTapNs = maxInterTapNs
        self.confirmWindowNs = confirmWindowNs
        self.refractoryNs = refractoryNs
        self.tapCountToFire = tapCountToFire
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
