import Foundation
import TunkFormat

/// Process lifecycle for the capture tool.
///
/// The main thread runs a CFRunLoop because the CGEventTap delivers there. The
/// capture script runs on a worker thread. SIGINT is handled on a dispatch source
/// (not in a C signal handler), so it can safely flush the session and write
/// meta.json before exiting — the operator must be able to Ctrl-C mid-take and
/// still keep everything recorded so far.
enum Runtime {
    nonisolated(unsafe) private static var recorder: SessionRecorder?
    nonisolated(unsafe) private static var sigintSource: DispatchSourceSignal?
    nonisolated(unsafe) private static var sigtermSource: DispatchSourceSignal?
    nonisolated(unsafe) private static var aborting = false
    private static let lock = NSLock()

    static var isAborting: Bool {
        lock.lock(); defer { lock.unlock() }
        return aborting
    }

    static func adopt(_ r: SessionRecorder?) {
        lock.lock(); recorder = r; lock.unlock()
    }

    static var current: SessionRecorder? {
        lock.lock(); defer { lock.unlock() }
        return recorder
    }

    /// Start the worker script and hand the main thread to the run loop. Never returns.
    static func run(_ script: @escaping () -> Void) -> Never {
        installSignals()
        let t = Thread {
            script()
            Runtime.exitNow(0)
        }
        t.stackSize = 1 << 20
        t.start()
        CFRunLoopRun()
        // The run loop only falls through if every source went away; keep the
        // process alive for the script rather than exiting under it.
        while true { Thread.sleep(forTimeInterval: 0.25) }
    }

    private static func installSignals() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let q = DispatchQueue(label: "dev.tunk.capture.signal")
        let si = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
        si.setEventHandler { Runtime.handleAbort(name: "SIGINT") }
        si.resume()
        sigintSource = si
        let st = DispatchSource.makeSignalSource(signal: SIGTERM, queue: q)
        st.setEventHandler { Runtime.handleAbort(name: "SIGTERM") }
        st.resume()
        sigtermSource = st
    }

    private static func handleAbort(name: String) {
        lock.lock()
        if aborting { lock.unlock(); return }
        aborting = true
        let r = recorder
        lock.unlock()

        Console.endStatus()
        Console.line("\n\(name) — flushing the session, do not kill again.")
        if let r {
            let s = r.finish(reason: "interrupted")
            printSummary(s)
            Console.line("Session is valid on disk. Check it with:")
            Console.line("  tunk-capture verify \(s.dir.path)")
        } else {
            Console.line("no session was open.")
        }
        // Non-zero, because an interrupt is not a success.
        //
        // This exited 0, and a shell script running several captures in sequence
        // therefore saw a clean finish and ran the NEXT one. Measured: SIGINT
        // 22 s into phase A flushed a valid session, exited 0, and bash went
        // straight into phase B and recorded an empty room as the next surface,
        // reaching the end of the script and exiting 0. The operator, who had
        // been told "Ctrl-C at any point flushes the stream and writes a valid
        // session", pressed it once and got a full run of stub sessions.
        //
        // 130 is the shell convention for SIGINT (128 + 2), so `set -e` stops
        // the script and the session on disk stays valid either way.
        exitNow(130)
    }

    static func exitNow(_ code: Int32) -> Never {
        fflush(stdout)
        exit(code)
    }

    /// Sleep in slices so the script notices an abort promptly. Returns false if
    /// the process is shutting down.
    @discardableResult
    static func sleep(_ seconds: Double) -> Bool {
        var left = seconds
        while left > 0 {
            if isAborting { return false }
            let slice = min(0.05, left)
            Thread.sleep(forTimeInterval: slice)
            left -= slice
        }
        return !isAborting
    }

    /// Sleep while showing a live status line driven by the open recorder.
    @discardableResult
    static func countdown(_ seconds: Double, label: String, recorder r: SessionRecorder?) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isAborting { return false }
            let left = end.timeIntervalSinceNow
            if let r {
                let c = r.liveCounts
                Console.status(String(format: "  %@  %5.1fs left   %d samples  %d input events",
                                      label, max(0, left), c.samples, c.inputs))
            } else {
                Console.status(String(format: "  %@  %5.1fs left", label, max(0, left)))
            }
            Thread.sleep(forTimeInterval: min(0.1, max(0.01, left)))
        }
        Console.endStatus()
        return !isAborting
    }

    static func printSummary(_ s: SessionRecorder.Summary) {
        Console.line("")
        Console.line("  dir       \(s.dir.path)")
        Console.line(String(format: "  duration  %.2f s", Double(s.durationNs) / 1e9))
        Console.line(String(format: "  samples   %d  (%.1f Hz measured, %d gaps)",
                            s.sampleCount, s.measuredHz, Int(s.gapCount)))
        Console.line("  input     \(s.inputCount) events\(s.inputTapActive ? "" : "   <-- TAP DEGRADED")")
        Console.line("  marks     \(s.markCount)")
        Console.line("")
    }
}
