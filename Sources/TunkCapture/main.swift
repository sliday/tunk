import Foundation
import TunkCore
import TunkIMU

// Temporary smoke test: prove the Swift/C accelerometer bridge works.
let source = AccelSource(reportIntervalUs: 1250)
var count = 0
var first: AccelSample?
var last: AccelSample?
let lock = NSLock()
do {
    try source.start { s in
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = s }
        last = s
        count += 1
    }
} catch {
    FileHandle.standardError.write("start failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
Thread.sleep(forTimeInterval: 3.0)
source.stop()
lock.lock()
let secs = Double((last?.tNs ?? 0) - (first?.tNs ?? 0)) / 1e9
print(String(format: "smoke: %d samples in %.3f s => %.1f Hz", count, secs, secs > 0 ? Double(count - 1) / secs : 0))
print(String(format: "rest reading: x=%+.4f y=%+.4f z=%+.4f", last?.x ?? 0, last?.y ?? 0, last?.z ?? 0))
let st = source.snapshotStats()
print("gaps=\(st.gapCount) maxLag=\(Double(st.maxLagNs)/1e6) ms")
lock.unlock()
