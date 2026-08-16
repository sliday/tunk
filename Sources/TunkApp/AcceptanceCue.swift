import AVFoundation
import Foundation

/// The beep the live acceptance test cues each tap with, when it is recording.
///
/// A copy of `TunkCapture`'s `Cue` tone, not a shared type: `TunkCapture` is an
/// executable target and `TunkApp` cannot import it. What matters is that the
/// contract is the same, because the labeller reads the mark this beep is
/// stamped next to.
///
/// `play()` is documented as returning immediately and does not always. On this
/// machine, with virtual audio drivers installed, it stalled about 16 s per
/// call, which is why `beep()` reports how long it took and why callers stamp
/// the mark AFTER it returns. A mark 16 s ahead of the sound the operator heard
/// puts every gesture outside the labeller's window and turns a session into
/// labels for silence.
final class AcceptanceCue {
    /// Longest a beep may take to start before the cue is called unreliable.
    /// Same budget as `TunkCapture`'s.
    static let startBudget: TimeInterval = 0.25
    private(set) var unreliable = false

    private var player: AVAudioPlayer?

    init(volume: Float = 0.35) {
        player = try? AVAudioPlayer(data: AcceptanceCue.tone(hz: 1000, ms: 70))
        player?.volume = volume
        player?.prepareToPlay()
    }

    var isAvailable: Bool { player != nil }

    /// Starts the tone and reports how long that took, in seconds.
    @discardableResult
    func beep() -> TimeInterval {
        guard let p = player else { return 0 }
        p.currentTime = 0
        let t0 = Date()
        p.play()
        let took = Date().timeIntervalSince(t0)
        if took > AcceptanceCue.startBudget { unreliable = true }
        return took
    }

    /// 16-bit mono PCM WAV, 44.1 kHz, with a 5 ms raised edge so it does not click.
    static func tone(hz: Double, ms: Int, sampleRate: Int = 44_100) -> Data {
        let n = max(1, sampleRate * ms / 1000)
        let edge = Double(sampleRate) * 0.005
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            var env = 1.0
            if Double(i) < edge { env = Double(i) / edge }
            let tail = Double(n - i)
            if tail < edge { env = min(env, tail / edge) }
            let v = Int16(clamping: Int(30_000 * env * sin(2 * .pi * hz * t)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}
