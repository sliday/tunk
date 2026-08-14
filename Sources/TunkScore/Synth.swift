import Foundation
import TunkCore
import TunkFormat

/// SYNTHETIC data generation. Nothing here is a recording.
///
/// The harness has to be provable before the operator records anything, so
/// `selftest` plants a known number of double-taps into a made-up signal, writes
/// it to disk in the real FORMAT.md layout, and then checks that the harness
/// reports exactly what was planted. Any file this produces carries
/// `"synthetic": true` in its notes and a `tool_version` that says so.
///
/// The waveform is a damped sinusoid, which is what a struck plate does; it is not
/// claimed to match the real chassis response, and no metric from these files says
/// anything about the real detector.
enum Synth {
    static let intervalNs: Int64 = 1_256_000
    static let toolVersion = "tunk-score selftest (SYNTHETIC) \(TunkScoreVersion.string)"

    /// Deterministic PRNG so two selftest runs produce byte-identical sessions.
    struct RNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x1 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
        /// Box-Muller, one value per call. Plenty for noise floor.
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
        }
    }

    struct Burst {
        var tNs: Int64
        /// Peak deviation in g. Fixtures state these as MULTIPLES of the shipped
        /// threshold via `Synth.times(_:)` rather than as bare numbers.
        var amplitude: Double
        var freqHz: Double = 180
        var tauMs: Double = 6
    }

    /// A burst amplitude expressed as a multiple of the shipped onset threshold.
    ///
    /// Fixture amplitudes used to be absolute, which tied every planted session
    /// to whatever `defaultThreshold` happened to be. Moving that default from
    /// the invented 0.30 g to a fitted value broke five tests the first time and
    /// ten the second — none of them because behaviour regressed, all of them
    /// because "a tap" and "a tap too weak to count" had been written down as
    /// numbers that only meant anything next to the old threshold.
    ///
    /// Stating them as multiples makes a fixture say what it means: `times(3)`
    /// is comfortably a tap at any threshold, `times(0.6)` is comfortably not.
    ///
    /// The measured envelope is roughly 0.68x the burst amplitude through the
    /// filter chain (synthetic amplitude 0.05 -> 0.0333 g envelope, 0.08 ->
    /// 0.0534 g), so the conversion accounts for that gain.
    static func times(_ multiple: Double,
                      of threshold: Double = DetectorConfig.default.defaultThreshold) -> Double {
        threshold * multiple / 0.68
    }

    struct Plan {
        var category: TunkFormat.Category
        var surface: Surface
        var durationSec: Double
        var bursts: [Burst] = []
        var labels: [TapLabel] = []
        var inputs: [InputRecord] = []
        var marks: [Mark] = []
        var expectedTriggers: Int = 0
        var notes: String = ""
        var seed: UInt64 = 1
        /// Only the holdout-guard check writes `.test`; every scored session is train.
        var split: Split = .train
    }

    /// Build a session directory under `root` and return its URL.
    @discardableResult
    static func write(_ plan: Plan, root: URL, stamp: String, shortId: String) throws -> URL {
        let name = "\(plan.category.rawValue)__\(plan.surface.rawValue)__\(stamp)__\(shortId)"
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let n = Int((plan.durationSec * 1e9) / Double(intervalNs))
        var rng = RNG(seed: plan.seed)
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        var zs = [Double](repeating: 0, count: n)
        for i in 0..<n {
            xs[i] = 0.0180 + 0.0030 * rng.gaussian()
            ys[i] = 0.0090 + 0.0030 * rng.gaussian()
            zs[i] = -0.9796 + 0.0030 * rng.gaussian()
        }

        // A tap couples into all three axes; z hardest for a strike on the deck.
        for b in plan.bursts {
            let start = Int(b.tNs / intervalNs)
            let tau = b.tauMs * 1e-3
            let len = Int((tau * 6) / (Double(intervalNs) * 1e-9))
            for k in 0..<len {
                let idx = start + k
                guard idx >= 0, idx < n else { continue }
                let dt = Double(k) * Double(intervalNs) * 1e-9
                let env = Foundation.exp(-dt / tau)
                let s = Foundation.sin(2 * Double.pi * b.freqHz * dt) * env * b.amplitude
                xs[idx] += 0.30 * s
                ys[idx] += 0.25 * s
                zs[idx] += 1.00 * s
            }
        }

        let writer = try AccelWriter(url: dir.appendingPathComponent("accel.bin"))
        for i in 0..<n {
            let t = Int64(i) * intervalNs
            // Arrival lag mirrors the measured p50 of 0.27 ms.
            writer.append(AccelSample(tNs: t, arrivalNs: t + 270_000,
                                      x: Float(xs[i]), y: Float(ys[i]), z: Float(zs[i])))
        }
        writer.close()

        try JSONL.write(plan.inputs.sorted { $0.tNs < $1.tNs }, to: dir.appendingPathComponent("input.jsonl"))
        try JSONL.write(plan.labels.sorted { $0.tNs < $1.tNs }, to: dir.appendingPathComponent("labels.jsonl"))
        try JSONL.write(plan.marks.sorted { $0.tNs < $1.tNs }, to: dir.appendingPathComponent("marks.jsonl"))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let meta = SessionMeta(
            sessionId: name,
            category: plan.category,
            surface: plan.surface,
            epochMachNs: 0,
            epochWallIso: iso.string(from: Date()),
            reportIntervalUs: 1250,
            nominalRateHz: 1e9 / Double(intervalNs),
            nominalIntervalNs: intervalNs,
            durationNs: Int64(n) * intervalNs,
            sampleCount: n,
            machine: MachineInfo.current(),
            split: plan.split,
            expectedTriggers: plan.expectedTriggers,
            operatorNotes: "SYNTHETIC — generated by tunk-score selftest, not a recording. " + plan.notes,
            toolVersion: toolVersion
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        try ("# SYNTHETIC session\n\nGenerated by `tunk-score selftest`. Not a recording. "
             + "Do not use for tuning or for any claim about detector quality.\n\n\(plan.notes)\n")
            .write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - The planted scenarios

    /// Clean multi-taps, no input activity. `tapsPerGesture` onsets per group, all
    /// labelled, so the group's tap count is unambiguous.
    static func multiTaps(count: Int, tapsPerGesture: Int, surface: Surface = .desk,
                          firstAtNs: Int64 = 3_000_000_000,
                          spacingNs: Int64 = 5_000_000_000,
                          interTapNs: Int64 = 160_000_000,
                          category: TunkFormat.Category = .tapDeck,
                          seed: UInt64 = 11) -> Plan {
        var p = Plan(category: category, surface: surface,
                     durationSec: Double(firstAtNs + Int64(count) * spacingNs) / 1e9 + 3,
                     expectedTriggers: count, seed: seed)
        p.notes = "\(count) clean \(tapsPerGesture)-tap gestures, inter-tap "
            + "\(interTapNs / 1_000_000) ms, no input activity."
        // FORMAT.md's TapIntent vocabulary is single/double/none, so a 3-tap gesture
        // has no word yet. The onset count is what the harness scores against; the
        // mismatch is reported, not hidden. See the change request in the report.
        let intent: TapIntent = tapsPerGesture == 1 ? .single : .double
        for g in 0..<count {
            let t0 = firstAtNs + Int64(g) * spacingNs
            for k in 0..<tapsPerGesture {
                let t = t0 + Int64(k) * interTapNs
                p.bursts.append(Burst(tNs: t, amplitude: k == 0 ? times(3.0) : times(2.7)))
                p.labels.append(TapLabel(tNs: t, group: g, indexInGroup: k,
                                         intent: intent, confidence: .autoRefined))
            }
            p.marks.append(Mark(tNs: t0 - 500_000_000, kind: "beep", group: g))
        }
        return p
    }

    /// Clean double-taps, no input activity. Everything should be detected.
    static func cleanTaps(count: Int, surface: Surface = .desk,
                          firstAtNs: Int64 = 3_000_000_000,
                          spacingNs: Int64 = 5_000_000_000,
                          interTapNs: Int64 = 160_000_000) -> Plan {
        multiTaps(count: count, tapsPerGesture: 2, surface: surface, firstAtNs: firstAtNs,
                  spacingNs: spacingNs, interTapNs: interTapNs)
    }

    /// The scenario the old scorer swallowed.
    ///
    /// Each gesture is one **deliberate single tap**, labelled as `intent: single`
    /// with one onset. A stray knock lands `leadNs` earlier — a bounce, a knuckle,
    /// the case settling. A double-tap detector pairs the two and fires, and its
    /// second onset sits exactly on the labelled single onset.
    ///
    /// Planted expectation with single **not** armed: zero detections, one false
    /// trigger per gesture, every one attributed to the 2-tap count.
    ///
    /// Arming single does NOT change that, which is worth stating because the
    /// obvious guess is wrong. This comment used to claim the gestures "become
    /// the 1-tap detection denominator instead"; measured against both the real
    /// detector and the stub with `--armed 1,2,3`, they do not. The detector
    /// fires one confirm window after its **last** onset, so the stray knock and
    /// the deliberate tap 160 ms later always close as a group of two whatever
    /// is armed. Result either way: 0/5 singles detected, 5 false triggers on
    /// count 2.
    static func singleTapsWithBounce(count: Int, surface: Surface = .desk,
                                     leadNs: Int64 = 160_000_000,
                                     firstAtNs: Int64 = 3_000_000_000,
                                     spacingNs: Int64 = 5_000_000_000) -> Plan {
        var p = Plan(category: .tapPalmrest, surface: surface,
                     durationSec: Double(firstAtNs + Int64(count) * spacingNs) / 1e9 + 3,
                     expectedTriggers: 0, seed: 91)
        p.notes = "\(count) deliberate SINGLE taps, each preceded \(leadNs / 1_000_000) ms earlier by "
            + "a stray knock. A double-tap detector pairs knock+tap and fires with its second onset "
            + "on the labelled single onset. Planted: 0 detections, \(count) false triggers while "
            + "1-tap is not armed."
        for g in 0..<count {
            let knock = firstAtNs + Int64(g) * spacingNs
            let tap = knock + leadNs
            p.bursts.append(Burst(tNs: knock, amplitude: times(2.85)))
            p.bursts.append(Burst(tNs: tap, amplitude: times(3.15)))
            // Only the deliberate tap is labelled, and it is labelled `single`.
            p.labels.append(TapLabel(tNs: tap, group: g, indexInGroup: 0,
                                     intent: .single, confidence: .humanVerified))
            p.marks.append(Mark(tNs: knock - 500_000_000, kind: "beep", group: g))
        }
        return p
    }

    /// Typing: hard key strikes that would pair up into "double-taps" if the gate
    /// were not there. Each strike carries its `key_down` / `key_up`.
    static func typing(strikes: Int, surface: Surface = .desk, amplitude: Double = times(1.35)) -> Plan {
        var p = Plan(category: .typing, surface: surface, durationSec: 0, expectedTriggers: 0, seed: 23)
        var rng = RNG(seed: 77)
        var t: Int64 = 2_000_000_000
        var i = 0
        var words = 0
        // Prose comes in words: a burst of keys, then a pause at the space bar and
        // the next word. The pause is what turns the last two strikes of a word into
        // something a double-tap grouper will happily accept.
        while i < strikes {
            let wordLength = 3 + Int(rng.uniform() * 5)
            for _ in 0..<wordLength where i < strikes {
                p.bursts.append(Burst(tNs: t, amplitude: amplitude * (0.85 + 0.3 * rng.uniform())))
                p.inputs.append(InputRecord(tNs: t, kind: .keyDown, code: Int32(4 + i % 20)))
                p.inputs.append(InputRecord(tNs: t + 55_000_000, kind: .keyUp, code: Int32(4 + i % 20)))
                t += 110_000_000 + Int64(rng.uniform() * 60_000_000)
                i += 1
            }
            t += 300_000_000 + Int64(rng.uniform() * 300_000_000)
            words += 1
        }
        p.durationSec = Double(t) / 1e9 + 2
        p.notes = "\(strikes) hard key strikes in \(words) word-like bursts of 3-7 keys at ~110-170 ms "
            + "spacing, separated by 300-600 ms pauses, each strike with its key_down/key_up. "
            + "Ungated, the last two strikes of every word pair into a double-tap; the gate is the "
            + "only thing stopping them."
        return p
    }

    /// Real double-taps that land inside a gate window, because a key went down
    /// just before each one. Planted expectation: zero detections.
    static func gatedTaps(count: Int, surface: Surface = .soft,
                          leadNs: Int64 = 15_000_000) -> Plan {
        var p = cleanTaps(count: count, surface: surface)
        p.category = .tapDeck
        p.seed = 37
        p.notes = "\(count) double-taps, each tap preceded by a key_down \(leadNs / 1_000_000) ms earlier. "
            + "The gate should eat every one of them: planted detections = 0."
        for (i, b) in p.bursts.enumerated() {
            p.inputs.append(InputRecord(tNs: b.tNs - leadNs, kind: .keyDown, code: Int32(30 + i % 5)))
            p.inputs.append(InputRecord(tNs: b.tNs - leadNs + 50_000_000, kind: .keyUp, code: Int32(30 + i % 5)))
        }
        return p
    }

    /// Isolated single transients, far apart. A double-tap detector must ignore them.
    static func isolatedThumps(count: Int, surface: Surface = .lap) -> Plan {
        var p = Plan(category: .confoundMug, surface: surface,
                     durationSec: Double(count) * 2 + 4, expectedTriggers: 0, seed: 53)
        for i in 0..<count {
            p.bursts.append(Burst(tNs: 2_000_000_000 + Int64(i) * 2_000_000_000, amplitude: times(3.75), tauMs: 9))
        }
        p.notes = "\(count) isolated hard thumps 2 s apart. No pairing is possible: planted triggers = 0."
        return p
    }
}
