import XCTest
@testable import TunkCore
import TunkFormat

/// Measurement only: what does the envelope do AFTER a strike, per surface?
/// Prints the median normalised decay curve and the exponential fit that curve
/// admits. Asserts only that the measurement ran.
final class TauMeasurementTests: XCTestCase {
    private func dataRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/raw").path + "/"
    }

    func testMeasureRingDownTau() throws {
        let root = dataRoot()
        let fm = FileManager.default
        let dirs = try fm.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()

        let binMs = 10, bins = 26
        // curves[surface][bin] = normalised envelope samples across gestures
        var curves: [String: [[Double]]] = [:]
        var perGestureTau: [String: [Double]] = [:]
        var perGestureR2: [String: [Double]] = [:]

        for name in dirs {
            let surface = String(name.split(separator: "_").filter { !$0.isEmpty }[2])
            let session = try Session(directory: URL(fileURLWithPath: root + name))
            let samples = try session.samples()
            let groups = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !groups.isEmpty else { continue }

            var chain = SignalChain(tuning: .default)
            var env = [Double](); env.reserveCapacity(samples.count)
            var ts = [Int64](); ts.reserveCapacity(samples.count)
            for s in samples {
                env.append(chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                         holdNoiseFloor: false))
                ts.append(s.tNs)
            }
            func index(atOrAfter t: Int64) -> Int {
                var lo = 0, hi = ts.count
                while lo < hi { let m = (lo + hi) / 2; if ts[m] < t { lo = m + 1 } else { hi = m } }
                return lo
            }

            if curves[surface] == nil { curves[surface] = Array(repeating: [], count: bins) }

            for g in groups {
                let first = g[0].tNs
                let second = g[1].tNs

                var i = index(atOrAfter: first - 5_000_000)
                let iEnd = index(atOrAfter: first + 20_000_000)
                var peak = 0.0, peakT: Int64 = first
                while i < iEnd { if env[i] > peak { peak = env[i]; peakT = ts[i] }; i += 1 }
                guard peak > 0 else { continue }

                // Bin maxima from the peak, stopping 8 ms short of the next strike.
                var fit: [(Double, Double)] = []
                for b in 0..<bins {
                    let start = peakT + Int64(b * binMs) * 1_000_000
                    let end = start + Int64(binMs) * 1_000_000
                    if end > second - 8_000_000 { break }
                    var k = index(atOrAfter: start)
                    let kEnd = index(atOrAfter: end)
                    var m = 0.0
                    while k < kEnd { m = max(m, env[k]); k += 1 }
                    guard m > 0 else { continue }
                    curves[surface]![b].append(m / peak)
                    // Fit window starts past the documented second lobe (+26 ms).
                    if b >= 4 { fit.append((Double(b * binMs), log(m))) }
                }
                guard fit.count >= 6 else { continue }
                var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0
                for (x, y) in fit { n += 1; sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y }
                let denom = n * sxx - sx * sx
                guard denom > 0 else { continue }
                let slope = (n * sxy - sx * sy) / denom
                let r = (n * sxy - sx * sy) / (sqrt(denom) * sqrt(max(n * syy - sy * sy, 1e-12)))
                perGestureTau[surface, default: []].append(slope < 0 ? -1.0 / slope : .infinity)
                perGestureR2[surface, default: []].append(r * r)
            }
        }

        func pct(_ a: [Double], _ p: Double) -> Double {
            guard !a.isEmpty else { return .nan }
            let s = a.sorted()
            return s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))]
        }

        print("\n  MEDIAN NORMALISED ENVELOPE AFTER A STRIKE (fraction of that strike's peak)")
        print("  ms from peak:  " + (0..<bins).map { String(format: "%5d", $0 * binMs) }.joined())
        for (surface, c) in curves.sorted(by: { $0.key < $1.key }) {
            let med = c.map { pct($0, 0.5) }
            let n = c.first?.count ?? 0
            print("  \(surface) n=\(n)".padding(toLength: 17, withPad: " ", startingAt: 0)
                  + med.map { $0.isNaN ? "    -" : String(format: "%5.2f", $0) }.joined())
        }
        print("\n  per-gesture exponential fit from +40 ms")
        for (surface, taus) in perGestureTau.sorted(by: { $0.key < $1.key }) {
            let finite = taus.filter { $0.isFinite }
            print(String(format: "  %-5@ n=%3d  rising(no decay) %2d  tau ms p10 %6.1f median %6.1f p90 %7.1f   R2 p10 %.2f median %.2f p90 %.2f",
                         surface as NSString, taus.count, taus.count - finite.count,
                         pct(finite, 0.1), pct(finite, 0.5), pct(finite, 0.9),
                         pct(perGestureR2[surface] ?? [], 0.1),
                         pct(perGestureR2[surface] ?? [], 0.5),
                         pct(perGestureR2[surface] ?? [], 0.9)))
        }
        XCTAssertFalse(curves.isEmpty)
    }

    /// The bound on any rule of the form "an onset must beat what the previous
    /// strike's tail could still be producing": how often is the second strike
    /// actually louder than the loudest thing the tail does before it?
    func testSecondStrikeAgainstTheLoudestTailExcursion() throws {
        let root = dataRoot()
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix("tap_deck__") }.sorted()

        var tailMax: [String: [Double]] = [:]     // fraction of first peak
        var secondPeak: [String: [Double]] = [:]  // fraction of first peak
        var separable: [String: (Int, Int)] = [:] // second strictly louder / total

        for name in dirs {
            let surface = String(name.split(separator: "_").filter { !$0.isEmpty }[2])
            let session = try Session(directory: URL(fileURLWithPath: root + name))
            let samples = try session.samples()
            let groups = try session.labelGroups().filter { $0.count >= 2 }
            guard !samples.isEmpty, !groups.isEmpty else { continue }

            var chain = SignalChain(tuning: .default)
            var env = [Double](); var ts = [Int64]()
            for s in samples {
                env.append(chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z),
                                         holdNoiseFloor: false))
                ts.append(s.tNs)
            }
            func index(atOrAfter t: Int64) -> Int {
                var lo = 0, hi = ts.count
                while lo < hi { let m = (lo + hi) / 2; if ts[m] < t { lo = m + 1 } else { hi = m } }
                return lo
            }
            func peak(_ from: Int64, _ to: Int64) -> Double {
                var k = index(atOrAfter: from); let kEnd = index(atOrAfter: to)
                var m = 0.0
                while k < kEnd { m = max(m, env[k]); k += 1 }
                return m
            }

            for g in groups {
                let first = g[0].tNs, second = g[1].tNs
                let p1 = peak(first - 5_000_000, first + 20_000_000)
                // The window the detector could possibly re-arm in: past the
                // 100 ms debounce, up to just before the second strike.
                guard second - 20_000_000 > first + 100_000_000, p1 > 0 else { continue }
                let tail = peak(first + 100_000_000, second - 20_000_000)
                let p2 = peak(second - 5_000_000, second + 20_000_000)
                tailMax[surface, default: []].append(tail / p1)
                secondPeak[surface, default: []].append(p2 / p1)
                var s = separable[surface] ?? (0, 0)
                if p2 > tail { s.0 += 1 }
                s.1 += 1
                separable[surface] = s
            }
        }

        func pct(_ a: [Double], _ p: Double) -> Double {
            guard !a.isEmpty else { return .nan }
            let s = a.sorted()
            return s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))]
        }

        print("\n  SECOND STRIKE vs LOUDEST TAIL EXCURSION, both as a fraction of the first strike's peak")
        for (surface, tails) in tailMax.sorted(by: { $0.key < $1.key }) {
            let seconds = secondPeak[surface] ?? []
            let s = separable[surface] ?? (0, 0)
            print(String(format: "  %-5@ n=%3d   tail p50 %.2f p90 %.2f   2nd strike p50 %.2f p10 %.2f   2nd louder than tail: %3d/%3d (%.0f %%)",
                         surface as NSString, tails.count, pct(tails, 0.5), pct(tails, 0.9),
                         pct(seconds, 0.5), pct(seconds, 0.1),
                         s.0, s.1, 100 * Double(s.0) / Double(max(s.1, 1))))
        }
        XCTAssertFalse(tailMax.isEmpty)
    }
}
