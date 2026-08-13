import Foundation

/// The tap detector. Pure and deterministic: it advances only inside
/// `ingest(sample:)` and `ingest(input:)`, it reads no clock, and every decision
/// is a function of the values and the order it was handed. The live app and the
/// offline harness run this same object and get identical triggers for identical
/// input.
///
/// ## Signal chain
///
/// `SignalChain` (see DSP.swift) turns x/y/z in g into one broadband transient
/// envelope in g: per-axis 20 Hz high pass to drop gravity and slow tilt, vector
/// magnitude so the struck face does not matter, then a 3-sample sliding peak so
/// the number reads as peak g.
/// Alongside it runs an asymmetric noise floor tracker.
///
/// ## Onset rule
///
/// An onset is an upward crossing of
///
///     T = max(config.effectiveThreshold,           // calibrated, absolute, in g
///             tuning.noiseSnrMultiple * noiseFloor, // adaptive, beats coupling
///             tuning.minThresholdG)                 // sanity floor
///
/// The absolute term is what "learn my tap" calibrates. The adaptive term is
/// what keeps a lap or a resonant desk from spraying onsets: it costs nothing on
/// a quiet machine (the floor sits far below the absolute threshold) and lifts
/// the bar exactly when the surface is alive. After a crossing the detector
/// disarms and re-arms only once the envelope falls back under
/// `releaseFraction * T` **and** `onsetDebounceNs` has passed, so one strike is
/// one onset.
///
/// ## Grouping
///
/// Onsets `config.minInterTapNs ... config.maxInterTapNs` apart join a group.
/// An onset closer than `minInterTapNs` is a bounce or a fumbled strike and
/// aborts the group outright — the make-or-break metric is false triggers, so
/// ambiguity resolves to "fire nothing". A group short of
/// `config.tapCountToFire` waits until `lastOnset + maxInterTapNs` for another
/// member, then dies. A group that has reached the count waits
/// `config.confirmWindowNs` before firing, which is what leaves room to add
/// triple-tap later without changing how double feels; an extra onset inside
/// that window makes the count wrong and the group fires nothing. After any
/// trigger, onsets are ignored for `config.refractoryNs`.
///
/// ## Gate
///
/// Any `InputEvent` whose `kind.gatesDetection` is true arms suppression for
/// `config.gateWindowNs`. Suppressed onsets are still published through
/// `drainOnsets()` with `suppressedByGate = true` — the tap monitor should show
/// the user that the sensor saw the knock — but they never join a group. The
/// gate also reaches backwards by `tuning.preGateNs`: a keystroke's shock can
/// hit the accelerometer slightly before the HID event reaches us, and since the
/// trigger is 180 ms away we can still retract an onset that recent for free.
///
/// ## Threading
///
/// Not thread-safe, deliberately: no locks on a 796 Hz path. Confine one
/// instance to one serial queue and hand it samples and input events in `tNs`
/// order. `drainOnsets()` counts as a mutation and belongs on that queue too.
public final class TapDetector: TapDetecting {

    // MARK: - Public surface

    /// Everything user-tunable. Nothing else in this file reads a default.
    /// Changing it takes effect on the next ingested sample; call `reset()` if
    /// the change should also drop in-flight state.
    public var config: DetectorConfig

    /// Filter design constants. Not user-facing, not part of `DetectorConfig`,
    /// and not a duplicate of anything in it. Exposed so the scoring harness can
    /// sweep the front end offline.
    public let tuning: DSPTuning

    public init(config: DetectorConfig = .default, tuning: DSPTuning = .default) {
        self.config = config
        self.tuning = tuning
        self.chain = SignalChain(tuning: tuning)
    }

    // MARK: - State

    private struct GroupOnset {
        var tNs: Int64
        var strength: Double
    }

    /// An onset whose peak is still being tracked. Its crossing time is already
    /// in the group; only the published strength is pending.
    private struct PendingOnset {
        var tNs: Int64
        var peak: Double
        var suppressedByGate: Bool
        var joinedGroup: Bool
    }

    private var chain: SignalChain

    private var sampleIndex: Int = 0
    private var lastSampleNs: Int64?
    private var armed: Bool = true
    private var lastOnsetNs: Int64?
    private var pending: PendingOnset?

    private var group: [GroupOnset] = []
    private var groupDeadlineNs: Int64?
    /// Time of the last ungated onset, group member or not. A new group may not
    /// start closer than `minInterTapNs` to it, so a burst of fumbled strikes
    /// cannot reassemble itself into a legal-looking pair.
    private var lastGroupingOnsetNs: Int64?

    private var refractoryUntilNs: Int64 = Int64.min
    private var gateUntilNs: Int64 = Int64.min

    private var onsetLog: [OnsetEvent] = []

    // MARK: - TapDetecting

    public func ingest(sample: AccelSample) -> Trigger? {
        // Out-of-order samples are a contract violation upstream. Drop them
        // rather than let them rewind the state machine.
        if let last = lastSampleNs, sample.tNs < last { return nil }

        if let last = lastSampleNs, sample.tNs - last > tuning.gapResetNs {
            // Sensor dropped out. The filters would ring on the seam and the
            // in-flight group spans a hole we cannot vouch for.
            dropSignalState()
        }
        lastSampleNs = sample.tNs
        sampleIndex &+= 1

        let envelope = chain.process(x: Double(sample.x),
                                     y: Double(sample.y),
                                     z: Double(sample.z),
                                     holdNoiseFloor: !armed)

        if pending != nil {
            pending!.peak = max(pending!.peak, envelope)
            if sample.tNs - pending!.tNs >= tuning.peakHoldNs { publishPending() }
        }

        let threshold = currentThreshold()

        if armed {
            if sampleIndex > tuning.warmupSamples && envelope >= threshold {
                armed = false
                lastOnsetNs = sample.tNs
                acceptOnset(at: sample.tNs, strength: envelope)
            }
        } else if envelope <= threshold * tuning.releaseFraction,
                  let onset = lastOnsetNs,
                  sample.tNs - onset >= tuning.onsetDebounceNs {
            armed = true
        }

        // Onsets first, deadlines second: an onset landing on the same sample as
        // an expiring wait window is inside the window, per "min...max join".
        return checkGroupDeadline(now: sample.tNs)
    }

    public func ingest(input: InputEvent) {
        guard input.kind.gatesDetection else { return }
        gateUntilNs = max(gateUntilNs, input.tNs + config.gateWindowNs)

        // Retroactive gate: kill an onset that landed just before this event.
        if let last = group.last, input.tNs >= last.tNs, input.tNs - last.tNs <= tuning.preGateNs {
            clearGroup()
        }
        if pending != nil, input.tNs >= pending!.tNs, input.tNs - pending!.tNs <= tuning.preGateNs {
            pending!.suppressedByGate = true
        } else if let i = onsetLog.indices.last,
                  input.tNs >= onsetLog[i].tNs,
                  input.tNs - onsetLog[i].tNs <= tuning.preGateNs {
            onsetLog[i].suppressedByGate = true
        }
    }

    public func drainOnsets() -> [OnsetEvent] {
        let out = onsetLog
        onsetLog.removeAll(keepingCapacity: true)
        return out
    }

    public func reset() {
        chain.reset()
        sampleIndex = 0
        lastSampleNs = nil
        armed = true
        lastOnsetNs = nil
        pending = nil
        group.removeAll(keepingCapacity: true)
        groupDeadlineNs = nil
        lastGroupingOnsetNs = nil
        refractoryUntilNs = Int64.min
        gateUntilNs = Int64.min
        onsetLog.removeAll(keepingCapacity: true)
    }

    // MARK: - Readouts for the tap monitor and the harness

    /// Current transient envelope, in g. For the live monitor readout only.
    public var envelope: Double { chain.envelope }
    /// Current adaptive noise floor, in g.
    public var noiseFloor: Double { chain.noiseFloor }
    /// The threshold an onset would have to beat right now, in g.
    public var activeThreshold: Double { currentThreshold() }

    // MARK: - Internals

    private func currentThreshold() -> Double {
        max(config.effectiveThreshold,
            max(tuning.noiseSnrMultiple * chain.noiseFloor, tuning.minThresholdG))
    }

    /// Drop everything derived from the sample stream, keeping gate and
    /// refractory (they are driven by wall-order events, not by the filters).
    private func dropSignalState() {
        chain.reset()
        sampleIndex = 0
        armed = true
        lastOnsetNs = nil
        lastGroupingOnsetNs = nil
        publishPending()
        clearGroup()
    }

    private func publishPending() {
        guard let p = pending else { return }
        append(OnsetEvent(tNs: p.tNs, strength: p.peak, suppressedByGate: p.suppressedByGate))
        if p.joinedGroup, let i = group.indices.last, group[i].tNs == p.tNs {
            group[i].strength = p.peak
        }
        pending = nil
    }

    private func append(_ event: OnsetEvent) {
        onsetLog.append(event)
        if onsetLog.count > tuning.onsetLogCapacity {
            onsetLog.removeFirst(onsetLog.count - tuning.onsetLogCapacity)
        }
    }

    private func acceptOnset(at tNs: Int64, strength: Double) {
        publishPending()

        let suppressed = tNs < gateUntilNs
        var joined = false

        if !suppressed {
            if tNs >= refractoryUntilNs {
                joined = join(onset: tNs, strength: strength)
            }
            lastGroupingOnsetNs = tNs
        }

        pending = PendingOnset(tNs: tNs, peak: strength,
                               suppressedByGate: suppressed, joinedGroup: joined)
    }

    /// Returns true if the onset is now a member of the live group.
    private func join(onset tNs: Int64, strength: Double) -> Bool {
        guard let last = group.last else {
            if let previous = lastGroupingOnsetNs, tNs - previous < config.minInterTapNs {
                // Still inside the wreckage of a burst. Do not let its tail
                // become the head of a fresh group.
                return false
            }
            startGroup(at: tNs, strength: strength)
            return true
        }
        let delta = tNs - last.tNs
        if delta < config.minInterTapNs {
            // Too close to be a second deliberate tap. Bounce, double-strike, or
            // a fumble. Kill the whole group; do not start a new one from it.
            clearGroup()
            return false
        }
        if delta > config.maxInterTapNs {
            // The old group has already expired on the deadline path; this is
            // the first tap of something new.
            startGroup(at: tNs, strength: strength)
            return true
        }
        group.append(GroupOnset(tNs: tNs, strength: strength))
        groupDeadlineNs = tNs + waitAfterLastOnsetNs(count: group.count)
        return true
    }

    private func startGroup(at tNs: Int64, strength: Double) {
        group = [GroupOnset(tNs: tNs, strength: strength)]
        groupDeadlineNs = tNs + waitAfterLastOnsetNs(count: 1)
    }

    /// How long to hold a group open after its last onset.
    ///
    /// Short of the target count we must wait the full `maxInterTapNs`, or a
    /// deliberate but slow double (say 260 ms apart, legal by config) would have
    /// its first tap expired by the 180 ms confirm window before the second tap
    /// arrived. At or above the target we wait `confirmWindowNs`, which is the
    /// deliberate delay that keeps room for triple-tap later.
    private func waitAfterLastOnsetNs(count: Int) -> Int64 {
        count < config.tapCountToFire ? config.maxInterTapNs : config.confirmWindowNs
    }

    private func clearGroup() {
        group.removeAll(keepingCapacity: true)
        groupDeadlineNs = nil
    }

    private func checkGroupDeadline(now tNs: Int64) -> Trigger? {
        guard let deadline = groupDeadlineNs, tNs >= deadline else { return nil }
        // Normally the peak window closed long ago; it only bites if someone
        // configures a confirm window shorter than the peak hold.
        if pending?.joinedGroup == true { publishPending() }
        let members = group
        clearGroup()

        guard members.count == config.tapCountToFire, config.tapCountToFire > 1 else {
            // Wrong count, or a build configured to fire on a single tap, which
            // we refuse: "single stray taps do nothing, ever".
            return nil
        }

        refractoryUntilNs = tNs + config.refractoryNs
        // Score is the weakest tap in the gesture, in g. The harness can sweep a
        // score cutoff offline and get exactly what raising the threshold would
        // have done.
        let score = members.map(\.strength).min() ?? 0
        return Trigger(tNs: tNs, tapOnsets: members.map(\.tNs), score: score)
    }
}

// MARK: - Replay

extension TapDetector {
    /// Offline replay, the same path the live app takes. Provided here so the
    /// harness and the app cannot disagree about merge order.
    ///
    /// Streams are merged on `tNs`; at an equal timestamp the input event goes
    /// first, so the gate is armed before the sample that might cross the
    /// threshold. That is the conservative order.
    public static func replay(samples: [AccelSample],
                              inputs: [InputEvent],
                              config: DetectorConfig = .default,
                              tuning: DSPTuning = .default)
        -> (triggers: [Trigger], onsets: [OnsetEvent])
    {
        let detector = TapDetector(config: config, tuning: tuning)
        var triggers: [Trigger] = []
        var onsets: [OnsetEvent] = []
        var i = 0, j = 0

        while i < samples.count || j < inputs.count {
            let takeInput: Bool
            if i >= samples.count {
                takeInput = true
            } else if j >= inputs.count {
                takeInput = false
            } else {
                takeInput = inputs[j].tNs <= samples[i].tNs
            }

            if takeInput {
                detector.ingest(input: inputs[j])
                j += 1
            } else {
                if let trigger = detector.ingest(sample: samples[i]) { triggers.append(trigger) }
                i += 1
                onsets.append(contentsOf: detector.drainOnsets())
            }
        }
        onsets.append(contentsOf: detector.drainOnsets())
        return (triggers, onsets)
    }
}
