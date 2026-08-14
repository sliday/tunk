import Foundation
import TunkCore
import TunkFormat

/// How the harness hands the two streams to the detector.
///
/// `.interleaved` is the only correct one and the only one `run`, `sweep` and
/// `explain` ever use. The two broken modes exist so `selftest` can prove the
/// interleaving actually matters: if a bug turned merging into "samples first,
/// then inputs", the gate would never be armed while the accelerometer was being
/// replayed and typing false positives would silently vanish from the report.
enum ReplayOrder: String {
    case interleaved
    case samplesFirstBroken
    case inputsFirstBroken
}

/// Everything one replay produced, plus the bookkeeping the report needs to be
/// honest about the data it was fed.
struct ReplayResult {
    var triggers: [Trigger] = []
    var onsets: [OnsetEvent] = []
    var sampleCount = 0
    var inputCount = 0
    var gatingInputCount = 0
    /// `t_ns` steps larger than 1.5x the nominal interval, per FORMAT.md.
    var gapCount = 0
    var largestGapNs: Int64 = 0
    var firstNs: Int64 = 0
    var lastNs: Int64 = 0
    /// Seconds of the session during which the input gate had the detector
    /// switched off, and the seconds during which it could actually fire.
    ///
    /// "Zero false triggers in 11.7 minutes of typing" is the project's
    /// make-or-break claim, and it was measured: strip input.jsonl and the same
    /// detector fires 110 times on the same recording. But 86 % of that time the
    /// gate had it muted, so the honest exposure is about 1.6 minutes. The zero
    /// is real; the denominator was not being reported.
    var gatedSeconds = 0.0
    var ungatedSeconds = 0.0
    /// Records the harness had to reorder because the file was not ascending.
    var unsortedSamples = 0
    var unsortedInputs = 0
    /// Delivery-order violations. Must be 0: the detector contract says `t_ns`
    /// arrives non-decreasing, and the merge is what guarantees it.
    var deliveryOrderViolations = 0
    /// Wall-clock seconds the replay itself took. Diagnostics only.
    var replaySeconds = 0.0
    /// How hard the chassis was actually disturbed during the recording, in g
    /// between consecutive samples, at the 99.9th percentile.
    ///
    /// A first difference rather than the shipped filter chain, deliberately:
    /// this number has to answer "did anything happen in the room" for a
    /// recording the detector is *supposed* to ignore, so it must not depend on
    /// any threshold the detector is being graded on. `data/raw` separates
    /// cleanly — idle 0.0014 and 0.0026, a real music session 0.0076, and one
    /// `confound_music` session at 0.0007, quieter than an empty room.
    var disturbanceP999 = 0.0

    var spanNs: Int64 { max(0, lastNs - firstNs) }
}

enum Replay {
    /// Feed one session's two streams to a detector in strict `t_ns` order.
    ///
    /// Tie-break: an input event at exactly the same `t_ns` as a sample is
    /// delivered **first**, so a gate that arms at time T suppresses the sample at
    /// time T. That is the conservative choice — it can only ever hide a trigger,
    /// never invent one.
    ///
    /// - Parameter sleepEveryNSamples: injects a real sleep mid-stream. Used only
    ///   by `selftest` to catch a detector that secretly reads a wall clock: the
    ///   triggers must not change when replay takes longer.
    static func run(
        samples rawSamples: [AccelSample],
        inputs rawInputs: [InputEvent],
        detector: TapDetecting,
        order: ReplayOrder = .interleaved,
        nominalIntervalNs: Int64 = 1_256_000,
        sleepEveryNSamples: Int = 0,
        sleepNanos: UInt64 = 0
    ) -> ReplayResult {
        var result = ReplayResult()
        let started = Date()

        var samples = rawSamples
        result.unsortedSamples = countDescents(samples.map(\.tNs))
        if result.unsortedSamples > 0 { samples.sort { $0.tNs < $1.tNs } }

        var inputs = rawInputs
        result.unsortedInputs = countDescents(inputs.map(\.tNs))
        if result.unsortedInputs > 0 { inputs.sort { $0.tNs < $1.tNs } }

        result.sampleCount = samples.count
        result.inputCount = inputs.count
        result.gatingInputCount = inputs.filter { $0.kind.gatesDetection }.count
        // Union of the gate's shadow over every gating input, clipped to the
        // recorded span. Merged rather than summed: keystrokes overlap heavily
        // during real typing, and summing would double-count them into a
        // coverage above 100 %.
        do {
            let spanLo = samples.first?.tNs ?? 0
            let spanHi = samples.last?.tNs ?? 0
            let tuning = DSPTuning.default
            // Falls back to the shipped default for the stub detector, which
            // has no config; only the real detector's gate matters here.
            let gateWindowNs = (detector as? TapDetector)?.effectiveConfig.gateWindowNs
                ?? DetectorConfig.default.gateWindowNs
            var shadows: [(Int64, Int64)] = inputs.filter { $0.kind.gatesDetection }.map {
                (max(spanLo, $0.tNs - tuning.preGateNs),
                 min(spanHi, $0.tNs + gateWindowNs))
            }.filter { $0.0 < $0.1 }
            shadows.sort { $0.0 < $1.0 }
            var merged = 0.0
            var i = 0
            while i < shadows.count {
                var (lo, hi) = shadows[i]
                var j = i + 1
                while j < shadows.count, shadows[j].0 <= hi {
                    hi = max(hi, shadows[j].1); j += 1
                }
                merged += Double(hi - lo) / 1e9
                i = j
            }
            let span = Double(spanHi - spanLo) / 1e9
            result.gatedSeconds = merged
            result.ungatedSeconds = max(0, span - merged)
        }
        result.firstNs = samples.first?.tNs ?? inputs.first?.tNs ?? 0
        result.lastNs = samples.last?.tNs ?? inputs.last?.tNs ?? 0

        let gapLimit = Int64(Double(nominalIntervalNs) * 1.5)
        var prevSampleNs: Int64?
        var lastDeliveredNs = Int64.min
        var delivered = 0

        func deliver(sample: AccelSample) {
            if sample.tNs < lastDeliveredNs { result.deliveryOrderViolations += 1 }
            lastDeliveredNs = max(lastDeliveredNs, sample.tNs)
            if let p = prevSampleNs {
                let step = sample.tNs - p
                if step > gapLimit {
                    result.gapCount += 1
                    result.largestGapNs = max(result.largestGapNs, step)
                }
            }
            prevSampleNs = sample.tNs
            if let t = detector.ingest(sample: sample) { result.triggers.append(t) }
            delivered += 1
            if delivered % 4096 == 0 { result.onsets.append(contentsOf: detector.drainOnsets()) }
            if sleepEveryNSamples > 0, delivered % sleepEveryNSamples == 0, sleepNanos > 0 {
                var ts = timespec(tv_sec: 0, tv_nsec: Int(sleepNanos))
                nanosleep(&ts, nil)
            }
        }

        func deliver(input: InputEvent) {
            if input.tNs < lastDeliveredNs { result.deliveryOrderViolations += 1 }
            lastDeliveredNs = max(lastDeliveredNs, input.tNs)
            detector.ingest(input: input)
        }

        switch order {
        case .interleaved:
            var si = 0, ii = 0
            while si < samples.count || ii < inputs.count {
                if ii < inputs.count && (si >= samples.count || inputs[ii].tNs <= samples[si].tNs) {
                    deliver(input: inputs[ii]); ii += 1
                } else {
                    deliver(sample: samples[si]); si += 1
                }
            }
        case .samplesFirstBroken:
            for s in samples { deliver(sample: s) }
            for e in inputs { deliver(input: e) }
        case .inputsFirstBroken:
            for e in inputs { deliver(input: e) }
            for s in samples { deliver(sample: s) }
        }

        result.onsets.append(contentsOf: detector.drainOnsets())
        result.disturbanceP999 = disturbanceP999(of: samples)
        result.replaySeconds = Date().timeIntervalSince(started)
        return result
    }

    /// 99.9th percentile of the sample-to-sample acceleration step. The
    /// implementation lives in TunkFormat, because the capture tool needs the
    /// same number to warn an operator before they walk away from a dead phase.
    static func disturbanceP999(of samples: [AccelSample]) -> Double {
        Disturbance.p999(of: samples)
    }

    /// Convenience: load a session off disk and replay it with a fresh detector.
    static func run(session: Session, config: DetectorConfig,
                    order: ReplayOrder = .interleaved,
                    sleepEveryNSamples: Int = 0,
                    sleepNanos: UInt64 = 0) throws -> ReplayResult {
        let samples = try session.samples()
        let inputs = try session.inputs().map(\.event)
        let detector = DetectorFactory.make(config: config)
        detector.reset()
        return run(samples: samples, inputs: inputs, detector: detector, order: order,
                   nominalIntervalNs: max(1, session.meta.nominalIntervalNs),
                   sleepEveryNSamples: sleepEveryNSamples, sleepNanos: sleepNanos)
    }

    private static func countDescents(_ ts: [Int64]) -> Int {
        var n = 0
        for i in 1..<max(ts.count, 1) where ts[i] < ts[i - 1] { n += 1 }
        return n
    }
}
