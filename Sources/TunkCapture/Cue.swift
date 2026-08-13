import AVFoundation
import Foundation

/// Spoken prompts and the beep cue.
///
/// The operator's hands are on the laptop, not the keyboard, so every instruction
/// is spoken as well as printed. The beep is pre-decoded and pre-rolled so that
/// `beep()` starts sound within a few milliseconds of the mark written next to it.
///
/// Both the beep and the speech physically shake the chassis through the built-in
/// speakers, which is a signal the accelerometer will see. Use headphones for tap
/// sessions; the guide says so out loud before it starts.
final class Cue {
    private var player: AVAudioPlayer?
    let beepEnabled: Bool
    let speechEnabled: Bool
    private let rate: Int

    init(beepEnabled: Bool, speechEnabled: Bool, volume: Float = 0.35, rate: Int = 190) {
        self.beepEnabled = beepEnabled
        self.speechEnabled = speechEnabled
        self.rate = rate
        if beepEnabled {
            player = try? AVAudioPlayer(data: Cue.tone(hz: 1000, ms: 70))
            player?.volume = volume
            player?.prepareToPlay()
        }
    }

    /// Starts the tone. Returns immediately; stamp the mark right before calling.
    func beep() {
        guard let p = player else { return }
        p.currentTime = 0
        p.play()
    }

    /// Speaks and blocks until done, so prompts stay in order with the script.
    func say(_ text: String) {
        guard speechEnabled else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-r", String(rate), text]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // No speech available; the printed prompt still stands.
        }
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

// MARK: - Console

enum Console {
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let inverse = "\u{1B}[7m"

    nonisolated(unsafe) static var useColor = isatty(STDOUT_FILENO) == 1

    static func line(_ s: String = "") {
        print(s)
        fflush(stdout)
    }

    /// Big and unmissable, because the operator is reading it from across the desk.
    static func banner(_ text: String) {
        let width = max(40, min(74, text.count + 6))
        let bar = String(repeating: "=", count: width)
        let pad = max(0, (width - text.count) / 2)
        let body = String(repeating: " ", count: pad) + text
        if useColor {
            line("\n\(bold)\(bar)\(reset)")
            line("\(bold)\(inverse) \(body.padding(toLength: max(body.count, width - 2), withPad: " ", startingAt: 0)) \(reset)")
            line("\(bold)\(bar)\(reset)\n")
        } else {
            line("\n\(bar)\n\(body)\n\(bar)\n")
        }
    }

    static func status(_ s: String) {
        guard useColor else { return }
        print("\r\u{1B}[2K\(s)", terminator: "")
        fflush(stdout)
    }

    static func endStatus() {
        guard useColor else { return }
        print("")
        fflush(stdout)
    }

    static func err(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
