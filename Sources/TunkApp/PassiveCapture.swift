import Foundation
import TunkCore
import TunkFormat

/// Keeps a rolling window of the accelerometer and writes out the seconds
/// surrounding anything tap-shaped, so ordinary use of the app produces real
/// recordings without a scripted session.
///
/// ## Why this exists
///
/// Detection rate, the typing false-positive rate and the two other surfaces
/// cannot be measured from synthetic signals — the Taptic Engine is two orders
/// of magnitude too weak, speaker impulses ring instead of striking, and
/// synthetic key events move no mass. All three need a hand on the chassis. What
/// this removes is the need for that hand to follow a twenty-minute script:
/// leave the app running, tap it when you would have anyway, and the waveforms
/// accumulate.
///
/// ## What its output is and is not good for
///
/// **Good for:** the tap profile. Amplitude distribution, rise time, decay,
/// spectral content, and the inter-tap interval of a real person on a real
/// machine. Those come out of the waveform itself and owe nothing to how the
/// snippet was selected. They are what `calibratedThreshold`,
/// `onsetCeilingG` and `calibratedInterTapNs` should be fitted to, and every one
/// of those is currently a number somebody guessed.
///
/// **Not good for: detection rate.** The snippets are selected BY the detector,
/// so scoring the detector against them asks whether it agrees with itself. A
/// tap it missed entirely leaves no snippet and cannot appear in the
/// denominator. Detection rate needs prompted sessions where the ground truth is
/// "the operator was asked to tap here", independent of whether anything fired.
/// `tunk-capture guide` is still the only source of that.
///
/// ## Verification status, stated plainly
///
/// Wired and confirmed receiving: the collector is constructed at engine start
/// and takes every sample and every input event. **The onset-to-snippet path has
/// not been exercised end to end**, because doing so needs an onset, and an
/// onset needs a real tap. Speaker impulses at full volume, sparse enough not to
/// lift the adaptive noise floor, still fall under `DSPTuning.minThresholdG`;
/// the Taptic Engine measures 2.5x the noise floor against the ~6x needed. The
/// format contract a snippet must satisfy is under test in
/// `PassiveCaptureTests`; the trigger path is not, and one real tap settles it.
///
/// The written session is marked `passive` in its notes and carries
/// `expected_triggers = 0`, so the harness treats it as a false-positive set
/// rather than a detection set. Nothing downstream can mistake it for prompted
/// ground truth.
final class PassiveCapture {
    struct Config {
        /// Seconds kept before a candidate. Long enough to hold the run-up and
        /// the quiet before it.
        var preRollSeconds: Double = 2.0
        /// Seconds kept after, which must cover the confirm window and the ring
        /// of a second tap.
        var postRollSeconds: Double = 2.0
        /// Stop after this many snippets, so an afternoon of use does not fill
        /// the disk unattended.
        var maxSnippets: Int = 200
        var outputRoot: URL
    }

    private let config: Config
    private var ring: [AccelSample] = []
    private let ringCapacity: Int
    private var inputs: [InputRecord] = []
    private var marks: [Mark] = []
    private var pendingUntilNs: Int64?
    private var written = 0
    private let lock = NSLock()

    /// Snippets are only interesting if something tap-shaped happened, and the
    /// detector's own onset log is the cheapest available definition of that.
    /// Deliberately looser than a trigger: a single onset is enough, because a
    /// tap the grouping logic rejected is exactly the kind of waveform worth
    /// having.
    init(config: Config, sampleRateHz: Double = 796.3) {
        self.config = config
        self.ringCapacity = Int((config.preRollSeconds + config.postRollSeconds) * sampleRateHz) + 64
    }

    var snippetsWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    var isFull: Bool { snippetsWritten >= config.maxSnippets }

    func ingest(sample: AccelSample) {
        lock.lock()
        ring.append(sample)
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
        let due = pendingUntilNs
        lock.unlock()

        if let due, sample.tNs >= due { flush(triggeredAt: due) }
    }

    func ingest(input: InputRecord) {
        lock.lock()
        inputs.append(input)
        // Keep only what the ring can still be about.
        if let oldest = ring.first?.tNs {
            inputs.removeAll { $0.tNs < oldest }
        }
        lock.unlock()
    }

    /// Call when the detector reports an onset. Starts or extends the window.
    func noteCandidate(atNs tNs: Int64, strength: Double, suppressed: Bool) {
        guard !isFull else { return }
        lock.lock()
        marks.append(Mark(tNs: tNs,
                          kind: suppressed ? "onset_suppressed" : "onset",
                          text: String(format: "%.4f g", strength)))
        // Extend rather than restart, so both taps of a double land in one file.
        let end = tNs + Int64(config.postRollSeconds * 1e9)
        pendingUntilNs = max(pendingUntilNs ?? end, end)
        lock.unlock()
    }

    private func flush(triggeredAt: Int64) {
        lock.lock()
        let samples = ring
        let localInputs = inputs
        let localMarks = marks
        pendingUntilNs = nil
        marks.removeAll()
        written += 1
        let index = written
        lock.unlock()

        guard let first = samples.first, let last = samples.last else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let id = "idle__desk__passive-\(stamp)-\(index)"
        let dir = config.outputRoot.appendingPathComponent(id)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let writer = try AccelWriter(url: dir.appendingPathComponent("accel.bin"))
            for s in samples { writer.append(s) }
            writer.close()

            try JSONL.write(localInputs, to: dir.appendingPathComponent("input.jsonl"))
            try JSONL.write(localMarks, to: dir.appendingPathComponent("marks.jsonl"))
            try JSONL.write([TapLabel](), to: dir.appendingPathComponent("labels.jsonl"))

            let meta = SessionMeta(
                sessionId: id,
                category: .idle,
                surface: .desk,
                epochMachNs: 0,
                epochWallIso: ISO8601DateFormatter().string(from: Date()),
                reportIntervalUs: 1250,
                nominalRateHz: 796.3,
                nominalIntervalNs: 1_256_000,
                durationNs: last.tNs - first.tNs,
                sampleCount: samples.count,
                machine: .current(),
                split: .train,
                // Zero, always. These snippets are selected by the detector, so
                // they cannot serve as a detection denominator — see the type
                // comment. Declaring any other number here would let a passive
                // capture masquerade as prompted ground truth.
                expectedTriggers: 0,
                operatorNotes: "PASSIVE capture: written automatically around a "
                    + "detector onset during ordinary use. Surface is a guess — "
                    + "correct it before using this for anything surface-specific. "
                    + "Usable for tap PROFILE (amplitude, rise, decay, interval), "
                    + "NOT for detection rate.",
                toolVersion: "tunk passive 0.1.0")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        } catch {
            NSLog("passive capture failed: \(error)")
        }
    }
}

/// Wiring for `tunk --collect-taps [dir]`. Kept apart from `PassiveCapture` so
/// the capture logic has no opinion about how it is switched on.
enum PassiveCollection {
    nonisolated(unsafe) private(set) static var requestedRoot: URL?

    static func enable(at path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        requestedRoot = url
        FileHandle.standardError.write(Data("""
        collecting tap samples into \(url.path)
          Use the machine normally and tap it when you would anyway. Each
          tap-shaped transient writes the seconds around it.
          Good for the tap profile: amplitude, rise, decay, inter-tap interval.
          NOT a detection-rate denominator — the snippets are chosen by the
          detector, so a tap it missed leaves no trace. Prompted sessions from
          `tunk-capture guide` remain the only source of that.

        """.utf8))
    }

    static func makeIfRequested() -> PassiveCapture? {
        guard let root = requestedRoot else { return nil }
        return PassiveCapture(config: .init(outputRoot: root))
    }
}
