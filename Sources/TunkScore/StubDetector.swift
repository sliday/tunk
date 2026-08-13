import Foundation
import TunkCore

/// STUB. Not the shipping detector.
///
/// The real detector lives in `Sources/TunkCore/Detector*.swift` and is written by
/// another agent. Until it exists, the harness needs *something* that conforms to
/// `TapDetecting` so it can compile, run its own self-tests, and prove the replay
/// and scoring logic is correct. This is that something.
///
/// It obeys the same hard rules the real one must obey: no clock, no timers, state
/// advances only inside `ingest`. Swap it out in `DetectorFactory.swift` (one line).
///
/// Method, deliberately plain: slow per-axis baseline, 3-axis deviation magnitude,
/// threshold crossing with a re-arm requirement, input gate, two-onset grouping with
/// a confirm window.
final class StubTapDetector: TapDetecting {
    var config: DetectorConfig

    /// Deviation must fall below `threshold * rearmFraction` before another onset
    /// can be declared, so one tap's ringing is not counted as many taps.
    private let rearmFraction = 0.4
    /// Hard minimum spacing between onsets, independent of re-arm.
    private let onsetHoldoffNs: Int64 = 25_000_000
    /// Baseline smoothing per sample. ~0.005 is a ~300 ms time constant at 796 Hz.
    private let baselineAlpha = 0.005

    private var haveBaseline = false
    private var bx = 0.0, by = 0.0, bz = 0.0

    private var gateUntilNs = Int64.min
    private var armed = true
    private var lastOnsetNs: Int64?
    private var refractoryUntilNs = Int64.min

    private var pendingOnsets: [Int64] = []
    private var pendingStrengths: [Double] = []
    private var fireAtNs: Int64?

    private var onsetLog: [OnsetEvent] = []
    private var lastSeenNs = Int64.min

    init(config: DetectorConfig) {
        self.config = config
    }

    func reset() {
        haveBaseline = false
        bx = 0; by = 0; bz = 0
        gateUntilNs = .min
        armed = true
        lastOnsetNs = nil
        refractoryUntilNs = .min
        pendingOnsets.removeAll()
        pendingStrengths.removeAll()
        fireAtNs = nil
        onsetLog.removeAll()
        lastSeenNs = .min
    }

    func drainOnsets() -> [OnsetEvent] {
        let out = onsetLog
        onsetLog.removeAll(keepingCapacity: true)
        return out
    }

    func ingest(input: InputEvent) {
        lastSeenNs = max(lastSeenNs, input.tNs)
        guard input.kind.gatesDetection else { return }
        gateUntilNs = max(gateUntilNs, input.tNs + config.gateWindowNs)
    }

    func ingest(sample: AccelSample) -> Trigger? {
        lastSeenNs = max(lastSeenNs, sample.tNs)
        let x = Double(sample.x), y = Double(sample.y), z = Double(sample.z)

        if !haveBaseline {
            bx = x; by = y; bz = z
            haveBaseline = true
            return nil
        }

        let dx = x - bx, dy = y - by, dz = z - bz
        let dev = (dx * dx + dy * dy + dz * dz).squareRoot()
        let thr = config.effectiveThreshold

        // Freeze the baseline while a transient is in progress, otherwise the tap
        // pulls the baseline toward itself and shortens its own visibility.
        if dev < thr * rearmFraction {
            bx += baselineAlpha * dx
            by += baselineAlpha * dy
            bz += baselineAlpha * dz
            armed = true
        }

        let farEnough = lastOnsetNs.map { sample.tNs - $0 >= onsetHoldoffNs } ?? true
        if dev >= thr, armed, farEnough {
            armed = false
            lastOnsetNs = sample.tNs
            let suppressed = sample.tNs <= gateUntilNs || sample.tNs <= refractoryUntilNs
            onsetLog.append(OnsetEvent(tNs: sample.tNs, strength: dev, suppressedByGate: suppressed))
            if !suppressed { accept(onset: sample.tNs, strength: dev) }
        }

        return maybeFire(atSampleNs: sample.tNs)
    }

    private func accept(onset tNs: Int64, strength: Double) {
        // Drop a stale lone onset before considering this one part of a group.
        if pendingOnsets.count == 1, tNs - pendingOnsets[0] > config.maxInterTapNs {
            pendingOnsets.removeAll(); pendingStrengths.removeAll(); fireAtNs = nil
        }

        if let last = pendingOnsets.last {
            let gap = tNs - last
            if gap >= config.minInterTapNs && gap <= config.maxInterTapNs {
                pendingOnsets.append(tNs)
                pendingStrengths.append(strength)
                // More taps than we fire on: this is a triple (or worse). Abandon
                // the group rather than firing a double. Triple wiring goes here.
                if pendingOnsets.count > config.tapCountToFire {
                    pendingOnsets.removeAll(); pendingStrengths.removeAll(); fireAtNs = nil
                    return
                }
                fireAtNs = pendingOnsets.count == config.tapCountToFire
                    ? tNs + config.confirmWindowNs : nil
                return
            }
        }
        pendingOnsets = [tNs]
        pendingStrengths = [strength]
        fireAtNs = config.tapCountToFire == 1 ? tNs + config.confirmWindowNs : nil
    }

    private func maybeFire(atSampleNs tNs: Int64) -> Trigger? {
        if pendingOnsets.count == 1, let first = pendingOnsets.first,
           tNs - first > config.maxInterTapNs, fireAtNs == nil {
            pendingOnsets.removeAll(); pendingStrengths.removeAll()
            return nil
        }
        guard let fireAt = fireAtNs, tNs >= fireAt,
              pendingOnsets.count == config.tapCountToFire else { return nil }
        let onsets = pendingOnsets
        let score = (pendingStrengths.min() ?? 0) / max(config.effectiveThreshold, 1e-9)
        pendingOnsets.removeAll(); pendingStrengths.removeAll(); fireAtNs = nil
        refractoryUntilNs = tNs + config.refractoryNs
        return Trigger(tNs: tNs, tapOnsets: onsets, score: score)
    }
}
