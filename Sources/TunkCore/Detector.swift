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
/// The floor keeps tracking the whole time, apart from a bounded
/// `tuning.noiseFloorHoldNs` after each crossing. It has to: it describes the
/// surface, not whether the detector currently feels like firing, and the one
/// state where it matters most is the one where the detector is stuck disarmed.
/// See `DSPTuning.noiseFloorHoldNs` for the latch this used to cause.
///
/// ## Grouping
///
/// Onsets chain into one group while each lands `config.minInterTapNs ...
/// config.maxInterTapNs` after the previous one. The group fires
/// `config.confirmWindowNs` after its **last** onset, and the count it reached
/// picks the action: `tapCount` on the `Trigger` is what the caller binds
/// against, exactly like Back Tap's separate Double Tap and Triple Tap rows. A
/// count with nothing bound fires nothing; so does a count outside
/// `DetectorConfig.supportedTapCounts`.
///
/// This rests on `maxInterTapNs <= confirmWindowNs`, enforced by
/// `DetectorConfig.madeCoherent()` and applied on every config write (see
/// `effectiveConfig`). With it, any onset that could extend a group arrives
/// before that group's deadline, so a stream of knocks at double-tap cadence
/// becomes one long group with an unbound count instead of a trigger every
/// refractory period. Without it the detector fired 48 times on a synthetic
/// 60 s stream of thumps 250 ms apart. Double still fires one confirm window
/// after its second onset whether or not a third was coming, so wiring triple
/// changes nothing about how double feels, and latency stays ~one confirm
/// window from the last onset at every count.
///
/// An onset closer than `minInterTapNs` is a bounce or a fumbled strike and
/// aborts the group outright — the make-or-break metric is false triggers, so
/// ambiguity resolves to "fire nothing". An onset later than `maxInterTapNs`
/// *closes* the live group instead: no later onset could have joined it either,
/// so its count is already final and it deserves its confirm decision. That
/// onset then heads a new group. After any trigger, onsets are ignored for
/// `config.refractoryNs`.
///
/// ## Gate
///
/// Any `InputEvent` whose `kind.gatesDetection` is true arms suppression for
/// `config.gateWindowNs`. Suppressed onsets are still published through
/// `drainOnsets()` with `suppressedByGate = true` — the tap monitor should show
/// the user that the sensor saw the knock — but they never join a group. The
/// gate also reaches backwards by `tuning.preGateNs`: a keystroke's shock can
/// hit the accelerometer slightly before the HID event reaches us, and since a
/// group does not fire until a whole `config.confirmWindowNs` after its last
/// onset, an onset that recent can still be retracted for free.
///
/// ## Threading
///
/// Not thread-safe, deliberately: no locks on a 796 Hz path. Confine one
/// instance to one serial queue and hand it samples and input events in `tNs`
/// order. `drainOnsets()` counts as a mutation and belongs on that queue too.
public final class TapDetector: TapDetecting {

    // MARK: - Public surface

    /// Everything user-tunable, as written by the settings panel. Nothing else
    /// in this file reads a default. Changing it takes effect on the next
    /// ingested sample; call `reset()` if the change should also drop in-flight
    /// state.
    ///
    /// The detector never runs these numbers raw: it runs
    /// `config.madeCoherent()`. Show `effectiveConfig` and
    /// `config.coherenceIssues` if the two can differ in front of a user.
    public var config: DetectorConfig {
        didSet { refreshDerivedConfig() }
    }

    /// Tap counts that have an action bound to them. A group whose count is not
    /// in here fires nothing, though its onsets still reach `drainOnsets()` and
    /// the group itself still reaches `drainGroups()`, so the tap monitor can
    /// show the user a gesture that was seen and deliberately not acted on.
    ///
    /// `nil` means "derive from `config.tapCountToFire`", which is what
    /// `DetectorConfig` can express on its own today. Set it explicitly to bind
    /// single, double and triple independently. Counts outside
    /// `DetectorConfig.supportedTapCounts` are ignored.
    ///
    /// Arming 1 is a different risk class from arming 2: every mug set down,
    /// every footfall and every hard keystroke is one transient, so single-tap
    /// false triggers must be measured on their own before shipping the binding.
    public var armedTapCounts: Set<Int>? {
        didSet { refreshDerivedConfig() }
    }

    /// The config actually in force: `config` with its incoherent combinations
    /// clamped. Read this for a UI readout, not `config`.
    public private(set) var effectiveConfig: DetectorConfig

    /// Filter design constants. Not user-facing, not part of `DetectorConfig`,
    /// and not a duplicate of anything in it. Exposed so the scoring harness can
    /// sweep the front end offline.
    public let tuning: DSPTuning

    public init(config: DetectorConfig = .default,
                tuning: DSPTuning = .default,
                armedTapCounts: Set<Int>? = nil) {
        self.config = config
        self.armedTapCounts = armedTapCounts
        self.tuning = tuning
        self.chain = SignalChain(tuning: tuning)
        self.effectiveConfig = config.madeCoherent()
        self.firingCounts = Self.resolveFiringCounts(config: self.effectiveConfig,
                                                     armed: armedTapCounts)
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

    /// Members of the live group, kept only while the group could still fire.
    /// A rhythmic disturbance can chain hundreds of onsets, and once the count
    /// is past `DetectorConfig.supportedTapCounts` the members are dead weight,
    /// so storage stops while `groupCount` keeps counting.
    private var group: [GroupOnset] = []
    private var groupCount: Int = 0
    private var groupLastOnsetNs: Int64?
    private var groupDeadlineNs: Int64?
    /// Time of the last ungated onset, group member or not. A new group may not
    /// start closer than `minInterTapNs` to it, so a burst of fumbled strikes
    /// cannot reassemble itself into a legal-looking pair.
    private var lastGroupingOnsetNs: Int64?

    private var refractoryUntilNs: Int64 = Int64.min
    private var gateUntilNs: Int64 = Int64.min
    /// The adaptive noise floor is frozen until this instant, so the strike that
    /// disarmed the detector cannot lift the floor it is measured against. It is
    /// a fixed span from the crossing, never "until we re-arm" — see
    /// `DSPTuning.noiseFloorHoldNs`.
    private var noiseFloorHoldUntilNs: Int64 = Int64.min

    private var onsetLog: [OnsetEvent] = []
    private var groupLog: [TapGroupEvent] = []
    private var firingCounts: Set<Int>

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
                                     holdNoiseFloor: sample.tNs < noiseFloorHoldUntilNs)

        if pending != nil {
            pending!.peak = max(pending!.peak, envelope)
            if sample.tNs - pending!.tNs >= tuning.peakHoldNs { publishPending() }
        }

        let threshold = currentThreshold()
        envelopeForTesting = envelope
        var onsetTrigger: Trigger?

        if armed {
            if sampleIndex > tuning.warmupSamples && envelope >= threshold {
                armed = false
                lastOnsetNs = sample.tNs
                noiseFloorHoldUntilNs = sample.tNs + tuning.noiseFloorHoldNs

                // The chassis is in motion, not merely ringing. Lifting the
                // machine or setting it down swings the gravity vector across
                // the axes and holds it there, and the case rings the whole
                // time — those rings are individually tap-sized, which is why
                // amplitude alone cannot reject them. A real tap leaves the
                // resting attitude where it found it.
                let moving = effectiveConfig.motionGateG > 0
                    && chain.bulkMotion > effectiveConfig.motionGateG
                if moving {
                    append(OnsetEvent(tNs: sample.tNs, strength: envelope, suppressedByGate: true))
                    clearGroup()
                } else {
                    onsetTrigger = acceptOnset(at: sample.tNs, strength: envelope)
                }
            }
        } else if envelope <= releaseLevel(threshold: threshold),
                  let onset = lastOnsetNs,
                  sample.tNs - onset >= tuning.onsetDebounceNs {
            armed = true
        }

        // Onsets first, deadlines second: an onset landing on the same sample as
        // an expiring wait window is inside the window, per "min...max join".
        // `acceptOnset` closes any group that the onset is too late to join, so
        // the two paths cannot both produce a trigger on one sample — a group
        // started here has its deadline a whole confirm window away.
        let deadlineTrigger = checkGroupDeadline(now: sample.tNs)
        return onsetTrigger ?? deadlineTrigger
    }

    public func ingest(input: InputEvent) {
        guard input.kind.gatesDetection else { return }
        gateUntilNs = max(gateUntilNs, input.tNs + effectiveConfig.gateWindowNs)

        // Retroactive gate: kill an onset that landed just before this event.
        if let last = groupLastOnsetNs, input.tNs >= last, input.tNs - last <= tuning.preGateNs {
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

    /// Groups closed since the last drain, fired or not. The tap monitor can say
    /// "saw three taps, nothing bound to three" instead of going quiet, and the
    /// scoring harness can count what a count would have cost before it is
    /// armed. Not required for correctness; not part of `TapDetecting`.
    ///
    /// Only groups that reached their confirm deadline appear. A group killed
    /// early — a bounce inside `minInterTapNs`, a retroactive gate, a sensor gap
    /// — never had a count worth reporting, though its onsets still reach
    /// `drainOnsets()`.
    public func drainGroups() -> [TapGroupEvent] {
        let out = groupLog
        groupLog.removeAll(keepingCapacity: true)
        return out
    }

    public func reset() {
        chain.reset()
        sampleIndex = 0
        lastSampleNs = nil
        armed = true
        lastOnsetNs = nil
        pending = nil
        clearGroup()
        lastGroupingOnsetNs = nil
        refractoryUntilNs = Int64.min
        gateUntilNs = Int64.min
        noiseFloorHoldUntilNs = Int64.min
        onsetLog.removeAll(keepingCapacity: true)
        groupLog.removeAll(keepingCapacity: true)
    }

    // MARK: - Readouts for the tap monitor and the harness

    /// Current transient envelope, in g. For the live monitor readout only.
    public var envelope: Double { chain.envelope }
    /// Current adaptive noise floor, in g.
    public var noiseFloor: Double { chain.noiseFloor }

    // Diagnostic only. Reading the arm state and the last envelope value is the
    // only way to tell "the tap was too weak" apart from "the detector was
    // still disarmed when it arrived", and those two have opposite fixes.
    public var isArmedForTesting: Bool { armed }
    public private(set) var envelopeForTesting: Double = 0
    /// The threshold an onset would have to beat right now, in g.
    public var activeThreshold: Double { currentThreshold() }
    /// The counts that can actually fire, after unsupported ones are dropped.
    public var effectiveArmedTapCounts: Set<Int> { firingCounts }

    // MARK: - Internals

    private static func resolveFiringCounts(config: DetectorConfig, armed: Set<Int>?) -> Set<Int> {
        // Read the whole armed set, never `tapCountToFire`. That accessor is
        // `armedTapCounts.min()`, so going through it silently drops every count
        // above the lowest: with single and double both bound it armed single
        // only and double-tap went dead without a word.
        //
        // An empty set means nothing is bound, and that is a real state the
        // settings panel can produce. It must fire nothing, not fall back to a
        // default — firing a count the user did not arm is worse than silence.
        let requested = armed ?? config.armedTapCounts
        return requested.filter { DetectorConfig.supportedTapCounts.contains($0) }
    }

    private func refreshDerivedConfig() {
        effectiveConfig = config.madeCoherent()
        firingCounts = Self.resolveFiringCounts(config: effectiveConfig, armed: armedTapCounts)
    }

    private func currentThreshold() -> Double {
        let base = max(effectiveConfig.effectiveThreshold,
                       max(tuning.noiseSnrMultiple * chain.noiseFloor, tuning.minThresholdG))
        // While a gesture is in flight, the bar for the NEXT onset comes down.
        //
        // A first onset is strong evidence that a second is about to arrive, and
        // asking the second strike to clear the same bar as the first throws
        // away that evidence. Measured across 80 lap onsets, roughly one second
        // tap in ten falls under the shipped threshold, which matched exactly
        // the ten lap gestures missed with both onsets inside the join window
        // and the reason given as "only 1 ungated onset; a 2-tap needs 2".
        //
        // Cheap in false positives because it costs nothing on its own: the
        // reduction only exists inside `maxInterTapNs` of an onset that already
        // cleared the full bar, and a lone reduced-threshold onset still fires
        // nothing unless single-tap is armed.
        guard !group.isEmpty, let last = groupLastOnsetNs else { return base }
        let openUntil = last + effectiveConfig.maxInterTapNs
        guard let now = lastSampleNs, now <= openUntil else { return base }
        return base * tuning.inGestureThresholdFraction
    }

    /// The envelope level the detector re-arms under, in g.
    ///
    /// Two terms, larger wins. `releaseFraction * T` is the fixed one and is a
    /// fraction of a CALIBRATED number, so it carries no information about the
    /// surface. `releaseFloorMultiple * noiseFloor` is the adaptive one and
    /// carries nothing else: it is the running noise floor, which is the only
    /// thing in the chain that describes the surface the machine is sitting on.
    ///
    /// Capped at the threshold, and the cap is not cosmetic. A release line at
    /// or above the admission line means the detector re-arms while the envelope
    /// is still over the bar, so the very next sample declares another onset and
    /// a live surface produces one onset per debounce period forever. Below the
    /// cap the hysteresis band always has width.
    @inline(__always)
    private func releaseLevel(threshold: Double) -> Double {
        let fixed = threshold * tuning.releaseFraction
        guard tuning.releaseFloorMultiple > 0 else { return fixed }
        return min(max(fixed, tuning.releaseFloorMultiple * chain.noiseFloor), threshold)
    }

    /// Drop everything derived from the sample stream, keeping gate and
    /// refractory (they are driven by wall-order events, not by the filters).
    private func dropSignalState() {
        chain.reset()
        sampleIndex = 0
        armed = true
        lastOnsetNs = nil
        lastGroupingOnsetNs = nil
        noiseFloorHoldUntilNs = Int64.min
        publishPending()
        clearGroup()
    }

    private func publishPending() {
        guard let p = pending else { return }

        // The ceiling can only be applied here. At the crossing all we have is
        // the first sample over the line; the strike's true peak is not known
        // until the ring has been tracked for `peakHoldNs`. So an onset can be
        // accepted and then turn out to be too big to be a finger, and it has to
        // be retractable — which it is, because a group does not fire until a
        // whole confirm window after its last onset.
        let tooLarge = effectiveConfig.onsetCeilingG.map { p.peak > $0 } ?? false
        append(OnsetEvent(tNs: p.tNs, strength: p.peak,
                          suppressedByGate: p.suppressedByGate || tooLarge))
        if tooLarge {
            clearGroup()
        } else if p.joinedGroup, let i = group.indices.last, group[i].tNs == p.tNs {
            group[i].strength = p.peak
        }
        pending = nil
    }

    private func append(_ event: TapGroupEvent) {
        groupLog.append(event)
        if groupLog.count > tuning.groupLogCapacity {
            groupLog.removeFirst(groupLog.count - tuning.groupLogCapacity)
        }
    }

    private func append(_ event: OnsetEvent) {
        onsetLog.append(event)
        if onsetLog.count > tuning.onsetLogCapacity {
            onsetLog.removeFirst(onsetLog.count - tuning.onsetLogCapacity)
        }
    }

    /// Returns a trigger if taking this onset closed a live group that fired.
    private func acceptOnset(at tNs: Int64, strength: Double) -> Trigger? {
        publishPending()

        let suppressed = tNs < gateUntilNs
        var joined = false
        var trigger: Trigger?

        if !suppressed {
            // Nothing can join the live group any more: this onset is past
            // `maxInterTapNs` and every later one is further still, so the
            // group's count is final. Close it here.
            //
            // This is where a gesture used to vanish. With `maxInterTapNs ==
            // confirmWindowNs` the group's deadline falls inside the sample
            // interval that carries such an onset, and onsets are handled before
            // deadlines, so `join` reached the group first and deleted it: no
            // `TapGroupEvent`, no trigger, nothing in the tap monitor. The
            // window is one sample period wide (~1.26 ms at 796 Hz) but it is a
            // silent loss, and with count 1 armed it is a dropped trigger.
            // Measured on two SYNTHETIC 0.5 g thumps: 220 and 221 ms apart gave
            // groups [1], 222 ms and wider gave [1, 1].
            if let last = groupLastOnsetNs, tNs - last > effectiveConfig.maxInterTapNs {
                trigger = closeGroup(now: tNs)
            }
            if tNs >= refractoryUntilNs {
                joined = join(onset: tNs, strength: strength)
            }
            lastGroupingOnsetNs = tNs
        }

        pending = PendingOnset(tNs: tNs, peak: strength,
                               suppressedByGate: suppressed, joinedGroup: joined)
        return trigger
    }

    /// Returns true if the onset is now a member of the live group.
    ///
    /// Any onset too late to join has already closed the live group in
    /// `acceptOnset`, so a group that is still live here is one this onset can
    /// legally extend, or one it is too *early* to extend.
    private func join(onset tNs: Int64, strength: Double) -> Bool {
        guard let last = groupLastOnsetNs else {
            if let previous = lastGroupingOnsetNs, tNs - previous < effectiveConfig.minInterTapNs {
                // Still inside the wreckage of a burst. Do not let its tail
                // become the head of a fresh group.
                return false
            }
            startGroup(at: tNs, strength: strength)
            return true
        }
        if tNs - last < effectiveConfig.minInterTapNs {
            // Too close to be a second deliberate tap. Bounce, double-strike, or
            // a fumble. Kill the whole group; do not start a new one from it.
            // Nothing is published: a group aborted this early never had a count
            // worth reporting, unlike one that reaches a confirm decision.
            clearGroup()
            return false
        }
        extendGroup(to: tNs, strength: strength)
        return true
    }

    private func startGroup(at tNs: Int64, strength: Double) {
        group.removeAll(keepingCapacity: true)
        groupCount = 0
        extendGroup(to: tNs, strength: strength)
    }

    /// Add an onset to the live group and push its deadline out. The group
    /// always fires one confirm window after its last onset, whatever the count;
    /// `maxInterTapNs <= confirmWindowNs` is what makes that safe.
    private func extendGroup(to tNs: Int64, strength: Double) {
        groupCount += 1
        if groupCount <= Self.groupOnsetRetentionLimit {
            group.append(GroupOnset(tNs: tNs, strength: strength))
        }
        groupLastOnsetNs = tNs
        groupDeadlineNs = tNs + effectiveConfig.confirmWindowNs
    }

    /// How many members are worth keeping. One past the largest bindable count,
    /// so an over-long group is still recognisably over-long.
    private static let groupOnsetRetentionLimit =
        DetectorConfig.supportedTapCounts.upperBound + 1

    private func clearGroup() {
        group.removeAll(keepingCapacity: true)
        groupCount = 0
        groupLastOnsetNs = nil
        groupDeadlineNs = nil
    }

    private func checkGroupDeadline(now tNs: Int64) -> Trigger? {
        guard let deadline = groupDeadlineNs, tNs >= deadline else { return nil }
        return closeGroup(now: tNs)
    }

    /// Give the live group its confirm decision and retire it. The group is gone
    /// afterwards either way, and it always leaves a `TapGroupEvent` behind, so
    /// the tap monitor sees every gesture that got as far as being counted.
    ///
    /// Called from two places: the deadline expiring, and an onset arriving too
    /// late to join. Both mean the same thing — no further onset can change this
    /// group's count.
    private func closeGroup(now tNs: Int64) -> Trigger? {
        guard groupDeadlineNs != nil else { return nil }
        // Normally the peak window closed long ago; it only bites if someone
        // configures a confirm window shorter than the peak hold.
        if pending?.joinedGroup == true { publishPending() }
        let members = group
        let count = groupCount
        clearGroup()

        // Score is the weakest tap in the gesture, in g. The harness can sweep a
        // score cutoff offline and get exactly what raising the threshold would
        // have done.
        let score = members.map(\.strength).min() ?? 0
        let fires = firingCounts.contains(count) && members.count == count
        append(TapGroupEvent(tNs: tNs, tapOnsets: members.map(\.tNs),
                             tapCount: count, score: score, fired: fires))

        guard fires else {
            // Either nothing is bound to this count, or the group ran past the
            // longest gesture we can tell apart. A rhythmic disturbance lands
            // here, which is the whole point.
            return nil
        }

        refractoryUntilNs = tNs + effectiveConfig.refractoryNs
        return Trigger(tNs: tNs, tapOnsets: members.map(\.tNs), score: score)
    }
}

/// A group of onsets that reached its confirm deadline, whether or not anything
/// was bound to its count. For the tap monitor and for offline scoring; the
/// action path uses `Trigger`.
public struct TapGroupEvent: Sendable, Equatable {
    /// When the group closed. Equals `Trigger.tNs` when it fired.
    public var tNs: Int64
    /// Onsets that made up the group, ascending. Truncated for a group longer
    /// than any bindable gesture; `tapCount` is always the true count.
    public var tapOnsets: [Int64]
    public var tapCount: Int
    public var score: Double
    /// Whether this group produced a `Trigger`.
    public var fired: Bool

    public init(tNs: Int64, tapOnsets: [Int64], tapCount: Int, score: Double, fired: Bool) {
        self.tNs = tNs
        self.tapOnsets = tapOnsets
        self.tapCount = tapCount
        self.score = score
        self.fired = fired
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
                              tuning: DSPTuning = .default,
                              armedTapCounts: Set<Int>? = nil)
        -> (triggers: [Trigger], onsets: [OnsetEvent])
    {
        let full = replayGroups(samples: samples, inputs: inputs, config: config,
                                tuning: tuning, armedTapCounts: armedTapCounts)
        return (full.triggers, full.onsets)
    }

    /// Same replay, also returning every closed group.
    ///
    /// Arm all of `DetectorConfig.supportedTapCounts` and the groups carry each
    /// gesture's count, so one pass over a recording yields the false-trigger
    /// rate for single, double and triple **separately**. Pooling them would
    /// flatter single, which is the count most likely to misfire: one mug set
    /// down is one transient.
    public static func replayGroups(samples: [AccelSample],
                                    inputs: [InputEvent],
                                    config: DetectorConfig = .default,
                                    tuning: DSPTuning = .default,
                                    armedTapCounts: Set<Int>? = nil)
        -> (triggers: [Trigger], onsets: [OnsetEvent], groups: [TapGroupEvent])
    {
        let detector = TapDetector(config: config, tuning: tuning,
                                   armedTapCounts: armedTapCounts)
        var triggers: [Trigger] = []
        var onsets: [OnsetEvent] = []
        var groups: [TapGroupEvent] = []
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
                groups.append(contentsOf: detector.drainGroups())
            }
        }
        onsets.append(contentsOf: detector.drainOnsets())
        groups.append(contentsOf: detector.drainGroups())
        return (triggers, onsets, groups)
    }
}
