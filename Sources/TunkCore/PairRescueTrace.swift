import Foundation

/// Diagnostic side channel for retrospective pairing. Nothing in the detector's
/// own decision path reads it, and nothing installs a sink unless a harness or a
/// test asks for one.
///
/// It exists because the number `pairRescueAnchorFraction` is set from — the
/// ratio a rescued crest bears to the onset that anchored it — appears in no
/// artefact the harness already writes. `explain` prints onsets and triggers; it
/// cannot say which of a trigger's two onsets was a real onset and which one was
/// pulled out of the sub-threshold crest buffer.
///
/// This file is deliberately NOT named `Detector*` or `DSP*`. Those files are
/// held to a structural no-clock, no-process-state rule that
/// `DetectorTests.testDetectorSourceHasNoClockCalls` enforces by reading their
/// text, and reading an environment variable belongs on the harness's side of
/// that line, not the detector's.
public enum PairRescueTrace {

    /// One rescue: the anchor onset, the crest taken as its partner, and the
    /// ratio between them.
    public struct Record: Sendable, Equatable {
        public var anchorTNs: Int64
        /// Peak envelope of the anchor onset, in g.
        public var anchorAmplitude: Double
        public var crestTNs: Int64
        /// Envelope at the rescued crest, in g.
        public var crestAmplitude: Double
        /// Live onset threshold at the crest's own sample, in g.
        public var threshold: Double
        public var rect: Double

        /// The quantity the anchor floor tests. Infinite for a zero anchor,
        /// which cannot happen for a published onset but is not worth a crash.
        public var ratio: Double {
            anchorAmplitude > 0 ? crestAmplitude / anchorAmplitude : .infinity
        }

        public var interTapNs: Int64 { crestTNs - anchorTNs }

        /// The line `tunk-score` writes to stderr under `TUNK_RESCUE_TRACE`.
        public var line: String {
            String(format: "RESCUE anchorTNs=%lld anchorAmp=%.6f crestTNs=%lld crestAmp=%.6f "
                         + "ratio=%.4f thr=%.6f rect=%.4f dtMs=%.1f",
                   anchorTNs, anchorAmplitude, crestTNs, crestAmplitude,
                   ratio, threshold, rect, Double(interTapNs) / 1e6)
        }
    }

    /// Installed by `tunk-score` when `TUNK_RESCUE_TRACE` is in the environment,
    /// and by tests that want the ratios. Nil everywhere else, including in the
    /// app, so a shipped build carries a nil check and nothing more.
    public static var sink: ((Record) -> Void)?

    static func record(anchorTNs: Int64, anchorAmplitude: Double,
                       crest: PairRescueCandidate) {
        guard let sink else { return }
        sink(Record(anchorTNs: anchorTNs, anchorAmplitude: anchorAmplitude,
                    crestTNs: crest.tNs, crestAmplitude: crest.amplitude,
                    threshold: crest.threshold, rect: crest.rect))
    }
}
