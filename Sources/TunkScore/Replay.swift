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
    /// Records the harness had to reorder because the file was not ascending.
    var unsortedSamples = 0
    var unsortedInputs = 0
    /// Delivery-order violations. Must be 0: the detector contract says `t_ns`
    /// arrives non-decreasing, and the merge is what guarantees it.
    var deliveryOrderViolations = 0
    /// Wall-clock seconds the replay itself took. Diagnostics only.
    var replaySeconds = 0.0

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
        result.replaySeconds = Date().timeIntervalSince(started)
        return result
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
