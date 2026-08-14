import Foundation
import TunkCore

/// How hard the chassis was actually disturbed during a recording.
///
/// Lives here rather than in the scorer because two callers need the same
/// number: the harness, to refuse to credit a confound session that recorded
/// nothing, and the capture tool, to tell the operator *while they are still
/// sitting there* that the phase they just recorded is empty.
public enum Disturbance {

    /// 99.9th percentile of the sample-to-sample acceleration step, in g.
    ///
    /// A first difference rather than the shipped filter chain, deliberately.
    /// This number has to answer "did anything happen in the room" about a
    /// recording the detector is *supposed* to ignore, so it must not depend on
    /// any threshold the detector is being graded on.
    ///
    /// Measured on `data/raw`: idle 0.0014 and 0.0026, a real bass-heavy music
    /// session 0.0076, and one `confound_music` session at 0.0007 — quieter
    /// than an empty room, and credited as evidence until this existed.
    ///
    /// Below 400 samples there is no p99.9 worth reading, so it reports 0,
    /// which reads as "no evidence" rather than "quiet".
    public static func p999(of samples: [AccelSample]) -> Double {
        guard samples.count >= 400 else { return 0 }
        var steps = [Double]()
        steps.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count {
            let dx = Double(samples[i].x - samples[i - 1].x)
            let dy = Double(samples[i].y - samples[i - 1].y)
            let dz = Double(samples[i].z - samples[i - 1].z)
            steps.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        steps.sort()
        return steps[min(steps.count - 1, Int(0.999 * Double(steps.count)))]
    }

    /// The floor a confound recording has to clear to count as evidence.
    ///
    /// Sits between the loudest idle session in `data/raw` (0.0026) and the one
    /// real music session (0.0076), with margin on both sides.
    public static let confoundFloor = 0.004
}
