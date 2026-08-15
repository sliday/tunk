import Foundation
import TunkCore
import TunkFormat

/// `tunk-score noise` — the noise distribution the admission rule is fitted to.
///
/// Every admission constant in `DSPTuning` (`noiseSnrMultiple`, `minThresholdG`,
/// `releaseFraction`, `onsetDebounceNs`) was fitted against the BROADBAND
/// envelope. The resonator front end replaces that envelope with a narrow-band
/// one whose gain is ~0.079 rather than ~0.68, so every one of those constants is
/// being read against a signal it was never measured on. This command measures
/// the distribution rather than assuming it: it runs the real detector over each
/// session, records the envelope, the adaptive floor and the threshold in force
/// at every sample, and reports the quiet-stretch statistics separately from the
/// strike statistics.
///
/// "Quiet" means: past warm-up, and at least `--guard-ms` away from any labelled
/// onset AND from any onset the detector itself declared. Both exclusions are
/// needed — a labelled onset marks where the operator says a strike is, a
/// declared onset marks where the detector found one, and on a lap those disagree
/// often enough that using either alone leaves strike energy in the "noise" set.
enum NoiseProbe {

    struct SessionStats {
        let id: String
        let surface: String
        let category: String
        let quietSamples: Int
        let totalSamples: Int
        let envelope: [Double]      // percentiles of the quiet envelope, in g
        let floor: [Double]         // percentiles of the quiet adaptive floor, in g
        let threshold: [Double]     // percentiles of the threshold in force, in g
        /// Fraction of quiet samples where the adaptive term actually set the
        /// threshold, i.e. `noiseSnrMultiple * floor` beat the absolute term.
        let adaptiveInForce: Double
        /// Fraction of quiet samples where `minThresholdG` set the threshold.
        let minInForce: Double
        /// Quiet-envelope excursions above the threshold in force. These are the
        /// admissions the noise floor is supposed to be stopping.
        let quietCrossings: Int
        /// Strength of every onset the detector declared, for the overlap read.
        let onsetStrengths: [Double]
        /// For every pair of consecutive declared onsets that a group could
        /// legally join (`minInterTapNs ... maxInterTapNs` apart), the LOWEST
        /// envelope between them, as a fraction of the threshold. This is the
        /// statistic `releaseFraction` has to clear: the envelope must fall under
        /// `releaseFraction * T` between two strikes or the second one is merged
        /// into the first and the gesture never reaches a count of two.
        let interOnsetValleyFractions: [Double]
    }

    static let quantiles: [Double] = [0.5, 0.9, 0.99, 0.999, 1.0]

    static func percentiles(_ xs: [Double], _ qs: [Double]) -> [Double] {
        guard !xs.isEmpty else { return qs.map { _ in 0 } }
        let s = xs.sorted()
        return qs.map { q in
            let i = Int((Double(s.count - 1) * q).rounded())
            return s[min(max(i, 0), s.count - 1)]
        }
    }

    static func measure(session: Session, config: DetectorConfig, tuning: DSPTuning,
                        guardNs: Int64) throws -> SessionStats {
        let samples = try session.samples()
        let labels = (try? session.labels()) ?? []

        // Pass 1: run the detector to find where IT thinks the strikes are.
        let first = TapDetector(config: config, tuning: tuning)
        first.reset()
        for s in samples { _ = first.ingest(sample: s) }
        let declared = first.drainOnsets().map(\.tNs).sorted()

        // Pass 2: same detector, same order, recording the admission state.
        let second = TapDetector(config: config, tuning: tuning)
        second.reset()
        var excluded = (labels.map(\.tNs) + declared).sorted()
        excluded = excluded.isEmpty ? [] : excluded

        func nearExcluded(_ t: Int64) -> Bool {
            guard !excluded.isEmpty else { return false }
            var lo = 0, hi = excluded.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if excluded[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            if lo < excluded.count && excluded[lo] - t <= guardNs { return true }
            if lo > 0 && t - excluded[lo - 1] <= guardNs { return true }
            return false
        }

        var env: [Double] = [], flr: [Double] = [], thr: [Double] = []
        var adaptive = 0, minimal = 0, crossings = 0, quiet = 0
        var index = 0
        var onsetStrengths: [Double] = []
        var trace: [(Int64, Double, Double)] = []   // t, envelope, threshold
        trace.reserveCapacity(samples.count)
        for s in samples {
            _ = second.ingest(sample: s)
            trace.append((s.tNs, second.envelope, second.activeThreshold))
            index += 1
            guard index > tuning.warmupSamples, !nearExcluded(s.tNs) else { continue }
            quiet += 1
            let e = second.envelope
            let f = second.noiseFloor
            let t = second.activeThreshold
            env.append(e); flr.append(f); thr.append(t)
            if tuning.noiseSnrMultiple * f >= max(config.effectiveThreshold, tuning.minThresholdG) {
                adaptive += 1
            } else if tuning.minThresholdG >= config.effectiveThreshold {
                minimal += 1
            }
            if e >= t { crossings += 1 }
        }
        onsetStrengths = second.drainOnsets().map(\.strength)

        // The re-arm line's own statistic: the valley between two onsets a group
        // could join. Taken from the same replay, so it is the envelope the
        // detector actually saw, not a reconstruction of it.
        var valleys: [Double] = []
        var cursor = 0
        for i in 1..<max(declared.count, 1) where declared.count > 1 {
            let a = declared[i - 1], b = declared[i]
            let gap = b - a
            guard gap >= config.minInterTapNs, gap <= config.maxInterTapNs else { continue }
            while cursor < trace.count && trace[cursor].0 < a { cursor += 1 }
            var j = cursor, low = Double.infinity, bar = 0.0
            while j < trace.count && trace[j].0 <= b {
                low = min(low, trace[j].1)
                bar = max(bar, trace[j].2)
                j += 1
            }
            if low.isFinite && bar > 0 { valleys.append(low / bar) }
        }

        return SessionStats(
            id: session.meta.sessionId,
            surface: session.meta.surface.rawValue,
            category: session.meta.category.rawValue,
            quietSamples: quiet, totalSamples: samples.count,
            envelope: percentiles(env, quantiles),
            floor: percentiles(flr, quantiles),
            threshold: percentiles(thr, quantiles),
            adaptiveInForce: quiet == 0 ? 0 : Double(adaptive) / Double(quiet),
            minInForce: quiet == 0 ? 0 : Double(minimal) / Double(quiet),
            quietCrossings: crossings,
            onsetStrengths: onsetStrengths,
            interOnsetValleyFractions: valleys)
    }

    static func report(_ stats: [SessionStats], config: DetectorConfig, tuning: DSPTuning,
                       guardMs: Double, root: URL) -> String {
        var out = "# tunk-score noise — admission statistics at the front end in force\n\n"
        out += "- data root: `\(root.path)` (\(stats.count) sessions)\n"
        out += "- front end: \(ConfigIO.describeFrontEnd(tuning))\n"
        out += String(format: "- absolute threshold %.4f g, noiseSnrMultiple %.2f, "
                      + "minThresholdG %.4f g, releaseFraction %.2f, onsetDebounce %.0f ms\n",
                      config.effectiveThreshold, tuning.noiseSnrMultiple, tuning.minThresholdG,
                      tuning.releaseFraction, Double(tuning.onsetDebounceNs) / 1e6)
        out += String(format: "- quiet = past warm-up and ≥ %.0f ms from every labelled "
                      + "and every declared onset\n\n", guardMs)

        out += "## Quiet-stretch envelope, in g (this is the noise the threshold sits above)\n\n"
        out += "| session | surface | quiet s | p50 | p90 | p99 | p99.9 | max | crossings |\n"
        out += "|---|---|---|---|---|---|---|---|---|\n"
        for s in stats {
            let secs = Double(s.quietSamples) / max(tuning.sampleRateHz, 1)
            out += "| \(s.id) | \(s.surface) | \(String(format: "%.1f", secs)) | "
            out += s.envelope.map { String(format: "%.5f", $0) }.joined(separator: " | ")
            out += " | \(s.quietCrossings) |\n"
        }

        out += "\n## Adaptive floor over the same stretches, in g\n\n"
        out += "| session | surface | floor p50 | p90 | p99 | p99.9 | max | snr×p99.9 | adaptive in force | min in force |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|\n"
        for s in stats {
            out += "| \(s.id) | \(s.surface) | "
            out += s.floor.map { String(format: "%.5f", $0) }.joined(separator: " | ")
            out += String(format: " | %.5f | %.1f %% | %.1f %% |\n",
                          tuning.noiseSnrMultiple * s.floor[3],
                          100 * s.adaptiveInForce, 100 * s.minInForce)
        }

        out += "\n## Re-arm line: inter-onset valley as a fraction of the threshold\n\n"
        out += "The envelope has to fall under `releaseFraction * T` between two strikes "
        out += "or the second one merges into the first. Every pair below is two declared "
        out += "onsets a group could legally join.\n\n"
        out += "| session | surface | pairs | min | p10 | p50 | p90 | max |\n"
        out += "|---|---|---|---|---|---|---|---|\n"
        for s in stats {
            let v = s.interOnsetValleyFractions
            let p = percentiles(v, [0.0, 0.1, 0.5, 0.9, 1.0])
            out += "| \(s.id) | \(s.surface) | \(v.count) | "
            out += p.map { String(format: "%.3f", $0) }.joined(separator: " | ") + " |\n"
        }

        out += "\n## Headroom: absolute threshold over the quiet envelope\n\n"
        out += "| session | surface | T / p99.9 | T / max | onsets | onset p50 |\n"
        out += "|---|---|---|---|---|---|\n"
        for s in stats {
            let t = config.effectiveThreshold
            let p50 = percentiles(s.onsetStrengths, [0.5])[0]
            out += String(format: "| %@ | %@ | %.2f× | %.2f× | %d | %.4f |\n",
                          s.id, s.surface,
                          s.envelope[3] > 0 ? t / s.envelope[3] : .infinity,
                          s.envelope[4] > 0 ? t / s.envelope[4] : .infinity,
                          s.onsetStrengths.count, p50)
        }
        return out
    }
}
