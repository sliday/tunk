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

/// One complex pole pair: a narrow band around a chosen frequency, whose output
/// is the MAGNITUDE of the pole's complex state.
///
/// Two properties earn it a place in front of the envelope, and both are
/// measured rather than assumed (see `notes/FRONT_END_RING.md`):
///
/// 1. **It suppresses the tail a second lap strike lands on.** In the 12-45 ms
///    before a real second strike, the lap signal carries 43-46 % of its power
///    below 20 Hz against 28-38 % for the strike itself. A one-pole 20 Hz high
///    pass rolls off at 6 dB/oct and passes most of that shoulder; a pole pair
///    rejects it from both sides.
/// 2. **Its output does not ripple.** A real-valued narrow band dips to zero
///    twice per cycle, and the detector re-arms on those dips — the exact
///    "metronome at the debounce period" failure three earlier re-arm
///    mechanisms hit. The complex state carries its own quadrature, so `|s|` is
///    a smooth envelope: no zero crossings to re-arm on.
///
/// `y[n] = p * y[n-1] + x[n]` with `p = r * e^{jw}`, output `(1-r) * |y[n]|`, so
/// the peak gain is 1 and a broadband strike still loses amplitude to the
/// narrow band — that loss is real and the threshold has to be refitted with it.
///
/// Causal and index-domain like everything else here: two state variables, one
/// multiply-add pair per sample, no lookahead.
public struct Resonator: Sendable, Equatable {
    /// `r * cos(w)` and `r * sin(w)`, the pole in rectangular form.
    public let poleRe: Double
    public let poleIm: Double
    /// `1 - r`. Normalises the peak gain to 1.
    public let gain: Double
    private var stateRe: Double = 0
    private var stateIm: Double = 0

    public init(centreHz: Double, q: Double, sampleRateHz: Double) {
        let fs = max(sampleRateHz, 1.0)
        let f0 = min(max(centreHz, 0.000_1), fs / 2)
        let quality = max(q, 0.1)
        let r = exp(-Double.pi * f0 / (quality * fs))
        let w = 2.0 * Double.pi * f0 / fs
        poleRe = r * cos(w)
        poleIm = r * sin(w)
        gain = 1.0 - r
    }

    public mutating func reset() {
        stateRe = 0
        stateIm = 0
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let nextRe = poleRe * stateRe - poleIm * stateIm + x
        let nextIm = poleIm * stateRe + poleRe * stateIm
        stateRe = nextRe
        stateIm = nextIm
        return gain * (nextRe * nextRe + nextIm * nextIm).squareRoot()
    }
}

/// One-pole low pass. Used to track where the accelerometer settles, so
/// "the machine is being moved" can be told apart from "the case rang".
public struct OnePoleLowPass: Sendable, Equatable {
    public let alpha: Double
    public private(set) var value: Double = 0
    private var primed = false

    public init(cutoffHz: Double, sampleRateHz: Double) {
        let fs = max(sampleRateHz, 1.0)
        let rc = 1.0 / (2.0 * Double.pi * max(cutoffHz, 0.0001))
        let dt = 1.0 / fs
        alpha = dt / (rc + dt)
    }

    public mutating func reset() { value = 0; primed = false }

    @discardableResult
    public mutating func process(_ x: Double) -> Double {
        // Jump to the first sample instead of ramping from zero, or the tracker
        // spends its warm-up reporting a huge false deviation from rest.
        if !primed { value = x; primed = true; return value }
        value += alpha * (x - value)
        return value
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
    /// Minimum spacing between two accepted onsets, in ns. **100 ms, set from
    /// real recordings on a soft surface.**
    ///
    /// It was 30 ms, which was fine on a hard desk and wrong everywhere else. A
    /// damped surface rings for far longer, so the envelope dips under the
    /// re-arm level and climbs again on the same strike, declaring a spurious
    /// third onset. That turns a double into an un-armed triple and the gesture
    /// fires nothing — the detector was working, and the count was wrong.
    ///
    /// Measured across all three recorded tap sessions, triggers out of 20
    /// prompted gestures each:
    ///
    ///     debounce   soft    desk    held-out
    ///      30 ms     12/20   20/20   20/20
    ///      50 ms     15/20   20/20   20/20
    ///      80 ms     18/20   20/20   20/20
    ///     100 ms     19/20   20/20   20/20
    ///
    /// Soft recovers from 60 % to 95 % and the hard-desk sessions do not move at
    /// all. The shortest inter-tap interval ever recorded from this operator is
    /// 149 ms, so a 100 ms debounce sits well clear of a real gesture.
    ///
    /// The cost is that the old bounce-rejection band between this and
    /// `config.minInterTapNs` disappears: a second strike inside 100 ms now
    /// merges into one onset instead of aborting the group. On a damped surface
    /// that merge is the correct reading, and it is why this works.
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
    /// Fast side of `bulkMotion`. A tap's energy sits above 100 Hz and lasts
    /// ~30 ms, so 6 Hz attenuates it heavily; a lift is a sub-10 Hz ramp over
    /// hundreds of ms and passes almost intact.
    public var settleFastHz: Double
    /// Slow side of `bulkMotion`: the resting attitude the fast side is compared
    /// against. Slow enough to ignore a movement entirely while it happens.
    public var settleSlowHz: Double

    /// Multiplier on the onset threshold while a gesture is already in flight,
    /// i.e. within `maxInterTapNs` of an accepted onset. **1.0, disabled.**
    ///
    /// The idea was sound and the measurement killed it. A first onset is
    /// evidence a second is coming, and ~10 % of lap second-taps fall under the
    /// shipped threshold, matching exactly the ten lap gestures missed with both
    /// onsets inside the join window. Lowering the bar to 0.6 for the second
    /// strike should have recovered them.
    ///
    /// Measured instead: lap 73.75 % to 75.00 %, and soft 100 % to 55 %.
    ///
    /// The reason is the same mechanism that caused the original soft-surface
    /// bug. A damped chassis rings for tens of milliseconds; drop the bar during
    /// that ring and the decay itself crosses it, declaring spurious onsets that
    /// turn a double into an un-armed triple. The evidence a first onset gives
    /// you about a second is real, but it cannot be spent on amplitude while
    /// ring-down is the thing competing for the same headroom.
    ///
    /// Kept as a tunable rather than deleted, because the idea is worth
    /// revisiting once onsets can be told apart by SHAPE — a decaying tail and a
    /// fresh strike differ in rise time even when they match in height.
    public var inGestureThresholdFraction: Double

    /// Centre of the optional `Resonator` stage, in Hz. **0 ships, which means
    /// the stage is absent and the chain is byte-identical to the one graded in
    /// `notes/BAR_ASSESSMENT.md`.**
    ///
    /// Non-zero inserts one complex pole pair per axis between the high pass and
    /// the vector magnitude. It exists because on a lap the second strike lands
    /// on a tail whose power sits lower in frequency than the strike's, and a
    /// one-pole high pass cannot tell them apart. Measured on `data/raw`, second
    /// strike peak over the tail level in the 12-45 ms before it, p25 per lap
    /// session: 1.68 / 1.92 / 2.06 shipped, 2.96 / 3.44 / 3.45 at 32 Hz Q 2.
    ///
    /// The stage costs amplitude: a broadband strike loses roughly 3x through a
    /// narrow band, so `minThresholdG` and the calibrated threshold BOTH have to
    /// be refitted whenever this is non-zero. Turning it on alone deafens the
    /// detector, because `minThresholdG` (0.02 g) then sits above every tap.
    public var resonatorHz: Double
    /// Quality factor of that stage. Higher is narrower and rings longer: the
    /// impulse response decays with time constant `q / (pi * f0)`, which is
    /// 20 ms at 32 Hz Q 2 and must stay far below the 100 ms onset debounce or
    /// the filter's own ring becomes the thing being detected.
    public var resonatorQ: Double

    /// How far a second onset must beat the resonator's own predicted ring-down
    /// to count as a fresh contact. **0 ships, which disables the test.**
    ///
    /// The resonator's impulse response is analytically known: `|s|` decays as
    /// `exp(-t * pi * f0 / q)`, time constant `q / (pi * f0)`. So from a group
    /// member's crossing time and strength you can compute what the envelope
    /// would read at time `t` if nothing new struck the case. An onset that only
    /// rides that prediction is the first strike still ringing; a real second
    /// contact must exceed it by this factor.
    ///
    /// Only meaningful with `resonatorHz > 0`, and the prediction is taken as
    /// the largest contribution over the live group's members, which is the
    /// superposition an extra strike would have to beat.
    public var decayPredictionMargin: Double

    public var onsetLogCapacity: Int
    /// Same cap for the closed-group log behind `drainGroups()`.
    public var groupLogCapacity: Int

    /// Ring-down time constant of the resonator stage, in seconds, or `nil` when
    /// the stage is absent. `Resonator` sets its pole radius to
    /// `exp(-pi * f0 / (q * fs))` per sample and outputs `|s|`, so over `dt`
    /// seconds the output falls by `exp(-dt * pi * f0 / q)`: the constant is
    /// `q / (pi * f0)` and does not depend on the sample rate. 15.9 ms at
    /// 40 Hz Q 2. Same clamps as `Resonator.init` so the number describes the
    /// filter that was actually built.
    public var resonatorDecayTauSeconds: Double? {
        guard resonatorHz > 0 else { return nil }
        let f0 = min(max(resonatorHz, 0.000_1), max(sampleRateHz, 1.0) / 2)
        return max(resonatorQ, 0.1) / (Double.pi * f0)
    }

    public static let `default` = DSPTuning(
        sampleRateHz: 796.3,
        highPassHz: 20.0,
        envelopePeakSamples: 3,
        noiseRiseTauSeconds: 1.0,
        noiseFallTauSeconds: 0.15,
        noiseSnrMultiple: 4.0,
        minThresholdG: 0.02,
        releaseFraction: 0.4,
        onsetDebounceNs: 100_000_000,
        peakHoldNs: 12_000_000,
        warmupSamples: 200,
        gapResetNs: 20_000_000,
        preGateNs: 25_000_000,
        noiseFloorHoldNs: 30_000_000,
        inGestureThresholdFraction: 1.0,
        settleFastHz: 6.0,
        settleSlowHz: 0.3,
        resonatorHz: 0.0,
        resonatorQ: 2.0,
        decayPredictionMargin: 0.0,
        onsetLogCapacity: 512,
        groupLogCapacity: 256
    )

    public init(sampleRateHz: Double, highPassHz: Double, envelopePeakSamples: Int,
                noiseRiseTauSeconds: Double, noiseFallTauSeconds: Double,
                noiseSnrMultiple: Double, minThresholdG: Double, releaseFraction: Double,
                onsetDebounceNs: Int64, peakHoldNs: Int64, warmupSamples: Int,
                gapResetNs: Int64, preGateNs: Int64,
                noiseFloorHoldNs: Int64 = 30_000_000,
                inGestureThresholdFraction: Double = 1.0,
                settleFastHz: Double = 6.0,
                settleSlowHz: Double = 0.3,
                resonatorHz: Double = 0.0,
                resonatorQ: Double = 2.0,
                decayPredictionMargin: Double = 0.0,
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
        self.inGestureThresholdFraction = inGestureThresholdFraction
        self.settleFastHz = settleFastHz
        self.settleSlowHz = settleSlowHz
        self.resonatorHz = resonatorHz
        self.resonatorQ = resonatorQ
        self.decayPredictionMargin = decayPredictionMargin
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
    /// Optional narrow band between the high pass and the magnitude. Absent
    /// unless `DSPTuning.resonatorHz` is non-zero, which is not what ships.
    private var resX: Resonator?
    private var resY: Resonator?
    private var resZ: Resonator?
    private var previousSquared: Double = 0
    private var peak: SlidingMax
    private var floorTracker: NoiseFloorTracker
    private var settledMagnitude: OnePoleLowPass
    private var fastMagnitude: OnePoleLowPass
    private var magnitude: Double = 0

    public private(set) var envelope: Double = 0
    public var noiseFloor: Double { floorTracker.value }

    /// How far the chassis's bulk acceleration currently sits from rest, in g.
    ///
    /// The high-passed envelope above answers "did something ring". This answers
    /// a different question the envelope cannot: "is the whole machine moving".
    /// Picking a laptop up, setting it down, or opening the lid swings the
    /// gravity vector across the axes and holds it there for hundreds of
    /// milliseconds. A tap does not: the case rings and the resting attitude is
    /// unchanged either side of it.
    ///
    /// Measured at rest on this machine, |a| sits at 0.9796 g, so deviation from
    /// 1 g is the wrong reference — deviation from the SETTLED value is what
    /// matters.
    ///
    /// Both sides are low-passed, and that is the whole trick. Comparing the RAW
    /// magnitude against a settled value fails: a 0.9 g tap leaks straight into
    /// the comparison and reads as movement, which stopped ordinary double-taps
    /// from firing at all. A tap is ~30 ms of energy above 100 Hz; a lift is a
    /// ramp below 10 Hz lasting hundreds of ms. So the fast side is cut at
    /// `settleFastHz`, which a tap barely crosses and a lift passes intact, and
    /// the slow side at `settleSlowHz` supplies the resting reference it is
    /// measured against.
    public var bulkMotion: Double { abs(fastMagnitude.value - settledMagnitude.value) }

    public init(tuning: DSPTuning) {
        hpX = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        hpY = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        hpZ = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        if tuning.resonatorHz > 0 {
            let make = { Resonator(centreHz: tuning.resonatorHz, q: tuning.resonatorQ,
                                   sampleRateHz: tuning.sampleRateHz) }
            resX = make(); resY = make(); resZ = make()
        }
        peak = SlidingMax(length: tuning.envelopePeakSamples)
        floorTracker = NoiseFloorTracker(riseTauSeconds: tuning.noiseRiseTauSeconds,
                                         fallTauSeconds: tuning.noiseFallTauSeconds,
                                         sampleRateHz: tuning.sampleRateHz)
        settledMagnitude = OnePoleLowPass(cutoffHz: tuning.settleSlowHz,
                                          sampleRateHz: tuning.sampleRateHz)
        fastMagnitude = OnePoleLowPass(cutoffHz: tuning.settleFastHz,
                                       sampleRateHz: tuning.sampleRateHz)
    }

    public mutating func reset() {
        hpX.reset()
        hpY.reset()
        hpZ.reset()
        resX?.reset()
        resY?.reset()
        resZ?.reset()
        previousSquared = 0
        peak.reset()
        floorTracker.reset()
        settledMagnitude.reset()
        fastMagnitude.reset()
        magnitude = 0
        envelope = 0
    }

    /// Advance one sample. `holdNoiseFloor` freezes the floor for one strike's
    /// ring-down after a crossing so the tap cannot lift its own reference. The
    /// caller decides how long that lasts; it must not be open-ended.
    @discardableResult
    public mutating func process(x: Double, y: Double, z: Double, holdNoiseFloor: Bool) -> Double {
        // Raw magnitude first: the bulk-motion tracker must see gravity, which
        // is exactly what the high pass exists to remove.
        magnitude = (x * x + y * y + z * z).squareRoot()
        settledMagnitude.process(magnitude)
        fastMagnitude.process(magnitude)

        var ax = hpX.process(x)
        var ay = hpY.process(y)
        var az = hpZ.process(z)
        // Optional narrow band. Off by default, and the three optionals are nil
        // together, so the shipped path costs one branch and no arithmetic.
        if resX != nil {
            ax = resX!.process(ax)
            ay = resY!.process(ay)
            az = resZ!.process(az)
        }
        let squared = ax * ax + ay * ay + az * az
        let pair = (squared + previousSquared).squareRoot()
        previousSquared = squared
        envelope = peak.process(pair)
        if !holdNoiseFloor { floorTracker.update(envelope) }
        return envelope
    }
}
