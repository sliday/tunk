import XCTest
@testable import TunkCore
@testable import TunkLabelCore

/// The labeller decides where ground truth sits, so if it is wrong every metric
/// downstream is wrong in a way no other test would catch. These signals are
/// SYNTHETIC — shaped to look like the real stream measured on this machine
/// (796 Hz, resting near 1 g on z, sensor dither around 0.002 g) but they are
/// not recordings.
final class OnsetPickerTests: XCTestCase {

    private let rateHz = 796.0
    private var intervalNs: Int64 { Int64(1e9 / rateHz) }

    /// A decaying ring, which is what a chassis does when struck.
    private func stream(seconds: Double,
                        taps: [(tNs: Int64, amplitude: Double)],
                        noise: Double = 0.002,
                        seed: UInt64 = 42) -> [AccelSample] {
        var rng = SplitMix64(seed: seed)
        let n = Int(seconds * rateHz)
        var out: [AccelSample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Int64(i) * intervalNs
            var ax = 0.0, ay = 0.0, az = -0.9796
            // Dither, so the noise floor is realistic rather than zero.
            ax += (rng.nextDouble() - 0.5) * noise
            ay += (rng.nextDouble() - 0.5) * noise
            az += (rng.nextDouble() - 0.5) * noise
            for tap in taps where t >= tap.tNs {
                let dt = Double(t - tap.tNs) / 1e9
                guard dt < 0.030 else { continue }
                // ~450 Hz ring decaying over ~30 ms.
                let ring = exp(-dt * 140.0) * sin(dt * 2 * .pi * 450.0) * tap.amplitude
                ax += ring * 0.6
                az += ring
            }
            out.append(AccelSample(tNs: t, arrivalNs: t, x: Float(ax), y: Float(ay), z: Float(az)))
        }
        return out
    }

    private func ms(_ v: Double) -> Int64 { Int64(v * 1e6) }

    func testRecoversACleanDoubleTapAtTheRightTimes() {
        let first = ms(500), second = ms(640)
        let samples = stream(seconds: 2.0, taps: [(first, 0.30), (second, 0.28)])
        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let floor = picker.noiseFloor(env)
        let peaks = picker.peaks(in: samples, env: env, floor: floor, from: 0, to: ms(2000))

        XCTAssertEqual(peaks.count, 2, "expected exactly two transients, got \(peaks.count)")
        let times = peaks.map(\.tNs).sorted()
        // Within 10 ms of truth is far tighter than the +/-150 ms matching
        // window the harness uses, so labelling error cannot dominate scoring.
        XCTAssertLessThan(abs(times[0] - first), ms(10), "first onset off by \((times[0] - first) / 1_000_000) ms")
        XCTAssertLessThan(abs(times[1] - second), ms(10), "second onset off by \((times[1] - second) / 1_000_000) ms")
    }

    func testNoiseFloorIsNotDraggedUpByTheTapsThemselves() {
        let quiet = stream(seconds: 2.0, taps: [])
        let withTaps = stream(seconds: 2.0, taps: [(ms(500), 0.30), (ms(640), 0.28)])
        let picker = OnsetPicker()
        let a = picker.noiseFloor(picker.envelope(quiet))
        let b = picker.noiseFloor(picker.envelope(withTaps))
        // A mean would move here; a median should barely notice two events in
        // 1600 samples.
        XCTAssertEqual(a, b, accuracy: a * 0.5, "median floor moved from \(a) to \(b)")
    }

    /// The failure this whole tool exists to catch: prompted taps that never
    /// happened must not look like taps.
    func testSilenceYieldsNoPeaks() {
        let samples = stream(seconds: 2.0, taps: [])
        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let peaks = picker.peaks(in: samples, env: env, floor: picker.noiseFloor(env),
                                 from: 0, to: ms(2000))
        XCTAssertTrue(peaks.isEmpty, "found \(peaks.count) phantom peaks in a silent stream")
    }

    /// A tap far below the noise floor is not a tap. On a lap or a cushion this
    /// is what a real but badly coupled tap looks like.
    func testTapBuriedInNoiseIsRejected() {
        let samples = stream(seconds: 2.0, taps: [(ms(500), 0.004)], noise: 0.02)
        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let peaks = picker.peaks(in: samples, env: env, floor: picker.noiseFloor(env),
                                 from: 0, to: ms(2000))
        XCTAssertTrue(peaks.isEmpty, "a tap under the noise floor was accepted")
    }

    /// One physical strike rings for milliseconds. It must stay one peak, or a
    /// single tap gets labelled as a double.
    func testOneStrikeIsOnePeak() {
        let samples = stream(seconds: 1.0, taps: [(ms(400), 0.40)])
        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let peaks = picker.peaks(in: samples, env: env, floor: picker.noiseFloor(env),
                                 from: 0, to: ms(1000))
        XCTAssertEqual(peaks.count, 1, "one strike produced \(peaks.count) peaks")
    }

    /// Amplitude ordering drives pair selection, so it has to be right.
    func testPeaksComeBackStrongestFirst() {
        let samples = stream(seconds: 2.0, taps: [(ms(400), 0.15), (ms(900), 0.45)])
        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let peaks = picker.peaks(in: samples, env: env, floor: picker.noiseFloor(env),
                                 from: 0, to: ms(2000))
        XCTAssertEqual(peaks.count, 2)
        XCTAssertGreaterThan(peaks[0].amplitude, peaks[1].amplitude)
        XCTAssertLessThan(abs(peaks[0].tNs - ms(900)), ms(10), "the louder tap should sort first")
    }

    func testTapsOutsideTheWindowAreNotReturned() {
        let samples = stream(seconds: 3.0, taps: [(ms(500), 0.30), (ms(2500), 0.30)])
        let picker = OnsetPicker()
        let env = picker.envelope(samples)
        let peaks = picker.peaks(in: samples, env: env, floor: picker.noiseFloor(env),
                                 from: ms(300), to: ms(1200))
        XCTAssertEqual(peaks.count, 1)
        XCTAssertLessThan(abs(peaks[0].tNs - ms(500)), ms(10))
    }

    func testIsDeterministic() {
        let samples = stream(seconds: 2.0, taps: [(ms(500), 0.30), (ms(640), 0.28)])
        let picker = OnsetPicker()
        let a = picker.peaks(in: samples, env: picker.envelope(samples),
                             floor: picker.noiseFloor(picker.envelope(samples)),
                             from: 0, to: ms(2000)).map(\.tNs)
        let b = picker.peaks(in: samples, env: picker.envelope(samples),
                             floor: picker.noiseFloor(picker.envelope(samples)),
                             from: 0, to: ms(2000)).map(\.tNs)
        XCTAssertEqual(a, b)
    }
}

/// Deterministic PRNG so a failure is always reproducible.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}
