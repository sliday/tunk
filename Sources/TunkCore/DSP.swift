import Foundation

// Signal chain for tap onset detection. Every filter here is index-domain: it
// advances one step per sample and never looks at a clock. Sample timestamps are
// used by the state machine in Detector.swift, never by these filters, so the
// filtered signal is a pure function of the sample values and their order.

/// One-pole high pass, `y[n] = a * (y[n-1] + x[n] - x[n-1])`.
///
/// This is the gravity remover. The chassis rests at ~1 g on z and the DC term
/// swamps everything; a tap is a broadband transient sitting on top of it. The
/// first sample primes the filter with `x` so opening the stream does not look
/// like a step edge.
public struct OnePoleHighPass: Sendable, Equatable {
    public let coefficient: Double
    private var prevIn: Double = 0
    private var prevOut: Double = 0
    private var primed: Bool = false

    public init(cutoffHz: Double, sampleRateHz: Double) {
        let fc = max(cutoffHz, 0.000_1)
        let fs = max(sampleRateHz, 1.0)
        coefficient = exp(-2.0 * Double.pi * fc / fs)
    }

    public mutating func reset() {
        prevIn = 0
        prevOut = 0
        primed = false
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        guard primed else {
            primed = true
            prevIn = x
            prevOut = 0
            return 0
        }
        let y = coefficient * (prevOut + x - prevIn)
        prevIn = x
        prevOut = y
        return y
    }
}

/// Sliding maximum over a short window.
///
/// Final envelope stage. It holds the peak of a ringing transient for a few
/// samples, which keeps the envelope readable as "peak g of broadband shake" —
/// the unit calibration and `DetectorConfig.defaultThreshold` are stated in. A
/// rising edge appears immediately; only the fall is stretched, and by far less
/// than the onset debounce.
///
/// Averaging or a running median was the obvious alternative and is wrong here.
/// A tap rings at a few hundred Hz and up, so at 796 Hz its energy lands in
/// isolated samples with sign flips between them; a median-of-3 measured 0.35x
/// the true peak on the synthetic fixtures and would have thrown away most of
/// the tap. The cost of taking the max is that a lone bad sample from the sensor
/// passes through as an onset. That is survivable — it has to happen twice,
/// 80-400 ms apart, to fire anything — but if the recordings show single-sample
/// fliers, this is the place to fix it.
public struct SlidingMax: Sendable, Equatable {
    private var ring: [Double]
    private var index: Int = 0
    private var filled: Int = 0

    public init(length: Int) {
        ring = Array(repeating: 0, count: max(1, length))
    }

    public mutating func reset() {
        for i in ring.indices { ring[i] = 0 }
        index = 0
        filled = 0
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        ring[index] = x
        index = (index + 1) % ring.count
        if filled < ring.count { filled += 1 }
        var peak = ring[0]
        for i in 1..<filled where ring[i] > peak { peak = ring[i] }
        return peak
    }
}

/// Asymmetric envelope tracker used as the adaptive noise floor.
///
/// Rises slowly (seconds) and falls faster (a fraction of a second), so a 10 ms
/// tap barely moves it while a genuinely noisy surface (lap, a desk carrying a
/// subwoofer) pushes it up within a second or two. The detector holds this
/// tracker frozen for one strike's ring-down after a crossing, so a tap cannot
/// raise the very floor it is being compared against — see
/// `DSPTuning.noiseFloorHoldNs` for why that hold is bounded rather than lasting
/// as long as the detector stays disarmed.
public struct NoiseFloorTracker: Sendable, Equatable {
    public let riseAlpha: Double
    public let fallAlpha: Double
    public private(set) var value: Double = 0

    public init(riseTauSeconds: Double, fallTauSeconds: Double, sampleRateHz: Double) {
        let fs = max(sampleRateHz, 1.0)
        riseAlpha = 1.0 - exp(-1.0 / max(riseTauSeconds * fs, 1.0))
        fallAlpha = 1.0 - exp(-1.0 / max(fallTauSeconds * fs, 1.0))
    }

    public mutating func reset() { value = 0 }

    @inline(__always)
    public mutating func update(_ envelope: Double) {
        let alpha = envelope > value ? riseAlpha : fallAlpha
        value += alpha * (envelope - value)
    }
}

/// Filter-design constants for the onset front end.
///
/// These are deliberately **not** in `DetectorConfig`: that struct is frozen and
/// holds what the settings panel exposes (threshold, gate, tap timing). Nothing
/// here duplicates or overrides a `DetectorConfig` field, and the detector reads
/// every user-facing number from `config` only. If any of these should become
/// user-tunable, `DetectorConfig` has to grow the field first — see the request
/// in the detector's report.
public struct DSPTuning: Sendable, Equatable {
    /// Nominal sensor rate. Measured at 796.3 Hz with `ReportInterval = 1250`.
    /// Only used to translate cutoffs and time constants into per-sample
    /// coefficients; the state machine uses real timestamps.
    public var sampleRateHz: Double
    /// Gravity/drift removal. 20 Hz also throws away most of footfall, bass
    /// through the desk and the slow tilt of picking the machine up.
    public var highPassHz: Double
    /// Envelope peak-hold length in samples (~3.8 ms at 796 Hz).
    public var envelopePeakSamples: Int
    public var noiseRiseTauSeconds: Double
    public var noiseFallTauSeconds: Double
    /// An onset must beat this multiple of the running noise floor as well as
    /// the calibrated absolute threshold. This is the part that survives moving
    /// from a hard desk to a lap.
    public var noiseSnrMultiple: Double
    /// Hard lower bound on the threshold, in g. Stops a silly calibration (or a
    /// dead-silent machine) from arming on sensor hash.
    public var minThresholdG: Double
    /// Envelope must fall back below this fraction of the threshold before the
    /// detector re-arms. Hysteresis, so one strike is one onset.
    public var releaseFraction: Double
    /// Minimum spacing between two accepted onsets. Shorter than
    /// `config.minInterTapNs` on purpose: ring-down inside this window is one
    /// physical tap, while a second strike between this and `minInterTapNs` is a
    /// real but illegal double and must kill the group rather than be swallowed.
    public var onsetDebounceNs: Int64
    /// How long after a crossing the peak is tracked before the onset's strength
    /// is published. Does not delay the trigger; grouping uses the crossing time.
    public var peakHoldNs: Int64
    /// Samples ignored at stream start while the high pass settles.
    public var warmupSamples: Int
    /// A timestamp jump this large means the sensor dropped out. Filters and the
    /// in-flight group are dropped rather than trusted across the seam.
    public var gapResetNs: Int64
    /// A gating input event also kills an onset that landed this recently before
    /// it. The chassis shock of a keystroke can reach the sensor a hair before
    /// the HID event reaches us, and a group does not fire until a whole
    /// `DetectorConfig.confirmWindowNs` after its last onset, so as long as this
    /// stays well under that window the retraction is free — the group has not
    /// fired yet and nothing downstream has seen it.
    public var preGateNs: Int64
    /// How long the adaptive noise floor stays frozen after an onset crossing.
    ///
    /// The freeze exists so a strike cannot lift the floor it is measured
    /// against; the second tap of a double is compared against a floor the first
    /// tap moved, and the error only ever runs one way (upward, less sensitive).
    /// One strike's ring-down is all that needs covering: a SYNTHETIC 0.5 g
    /// strike decays to a tenth of its peak 12.6 ms after the peak, and
    /// `onsetDebounceNs` already calls 30 ms "still one physical tap".
    ///
    /// It is bounded on purpose. Freezing for as long as the detector stays
    /// disarmed — which is what this used to do — latches on a live surface:
    /// while the envelope never falls back under `releaseFraction * threshold`
    /// the detector cannot re-arm, and because the floor is frozen the threshold
    /// cannot rise to let it. Measured on a SYNTHETIC 10 s stretch of 0.25 g
    /// broadband shake: floor pinned at 0.0030 g, threshold pinned at 0.3000 g,
    /// one onset in the first second and none for the remaining nine, and a
    /// deliberate 3.0 g double-tap partway through produced no onset at all.
    public var noiseFloorHoldNs: Int64
    /// Cap on the undrained onset log, so a live app that never drains cannot
    /// grow without bound.
    public var onsetLogCapacity: Int
    /// Same cap for the closed-group log behind `drainGroups()`.
    public var groupLogCapacity: Int

    public static let `default` = DSPTuning(
        sampleRateHz: 796.3,
        highPassHz: 20.0,
        envelopePeakSamples: 3,
        noiseRiseTauSeconds: 1.0,
        noiseFallTauSeconds: 0.15,
        noiseSnrMultiple: 4.0,
        minThresholdG: 0.02,
        releaseFraction: 0.4,
        onsetDebounceNs: 30_000_000,
        peakHoldNs: 12_000_000,
        warmupSamples: 200,
        gapResetNs: 20_000_000,
        preGateNs: 25_000_000,
        noiseFloorHoldNs: 30_000_000,
        onsetLogCapacity: 512,
        groupLogCapacity: 256
    )

    public init(sampleRateHz: Double, highPassHz: Double, envelopePeakSamples: Int,
                noiseRiseTauSeconds: Double, noiseFallTauSeconds: Double,
                noiseSnrMultiple: Double, minThresholdG: Double, releaseFraction: Double,
                onsetDebounceNs: Int64, peakHoldNs: Int64, warmupSamples: Int,
                gapResetNs: Int64, preGateNs: Int64,
                noiseFloorHoldNs: Int64 = 30_000_000,
                onsetLogCapacity: Int, groupLogCapacity: Int = 256) {
        self.sampleRateHz = sampleRateHz
        self.highPassHz = highPassHz
        self.envelopePeakSamples = envelopePeakSamples
        self.noiseRiseTauSeconds = noiseRiseTauSeconds
        self.noiseFallTauSeconds = noiseFallTauSeconds
        self.noiseSnrMultiple = noiseSnrMultiple
        self.minThresholdG = minThresholdG
        self.releaseFraction = releaseFraction
        self.onsetDebounceNs = onsetDebounceNs
        self.peakHoldNs = peakHoldNs
        self.warmupSamples = warmupSamples
        self.gapResetNs = gapResetNs
        self.preGateNs = preGateNs
        self.noiseFloorHoldNs = noiseFloorHoldNs
        self.onsetLogCapacity = onsetLogCapacity
        self.groupLogCapacity = groupLogCapacity
    }
}

/// x/y/z in g → one scalar transient envelope in g, plus its noise floor.
///
/// Chain: per-axis high pass (drops gravity and slow tilt) → vector magnitude
/// (orientation independent, so it does not matter which face was struck) →
/// quadrature pair with the previous sample → 3-sample sliding peak. The result
/// is "peak broadband shake right now", in g, the unit the calibration step and
/// `DetectorConfig.defaultThreshold` are expressed in.
///
/// The quadrature pair, `sqrt(m[n]^2 + m[n-1]^2)`, is what makes the number
/// repeatable. A tap rings at a few hundred Hz, so at 796 Hz there are only four
/// or five samples per cycle and where they land against the waveform is luck:
/// taking the raw sampled peak, two identical synthetic taps 150 ms apart
/// measured 0.349 g and 0.298 g, a 15 % spread from sampling phase alone, which
/// is the difference between clearing a threshold and missing it. Consecutive
/// samples of a 180 Hz ring sit ~82° apart, near enough to quadrature that the
/// two-sample norm recovers the envelope instead of the instantaneous value. Off
/// that frequency the pair overshoots by at most sqrt(2), which the calibration
/// step absorbs because it measures the same statistic.
public struct SignalChain: Sendable, Equatable {
    private var hpX: OnePoleHighPass
    private var hpY: OnePoleHighPass
    private var hpZ: OnePoleHighPass
    private var previousSquared: Double = 0
    private var peak: SlidingMax
    private var floorTracker: NoiseFloorTracker

    public private(set) var envelope: Double = 0
    public var noiseFloor: Double { floorTracker.value }

    public init(tuning: DSPTuning) {
        hpX = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        hpY = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        hpZ = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        peak = SlidingMax(length: tuning.envelopePeakSamples)
        floorTracker = NoiseFloorTracker(riseTauSeconds: tuning.noiseRiseTauSeconds,
                                         fallTauSeconds: tuning.noiseFallTauSeconds,
                                         sampleRateHz: tuning.sampleRateHz)
    }

    public mutating func reset() {
        hpX.reset()
        hpY.reset()
        hpZ.reset()
        previousSquared = 0
        peak.reset()
        floorTracker.reset()
        envelope = 0
    }

    /// Advance one sample. `holdNoiseFloor` freezes the floor for one strike's
    /// ring-down after a crossing so the tap cannot lift its own reference. The
    /// caller decides how long that lasts; it must not be open-ended.
    @discardableResult
    public mutating func process(x: Double, y: Double, z: Double, holdNoiseFloor: Bool) -> Double {
        let ax = hpX.process(x)
        let ay = hpY.process(y)
        let az = hpZ.process(z)
        let squared = ax * ax + ay * ay + az * az
        let pair = (squared + previousSquared).squareRoot()
        previousSquared = squared
        envelope = peak.process(pair)
        if !holdNoiseFloor { floorTracker.update(envelope) }
        return envelope
    }
}
