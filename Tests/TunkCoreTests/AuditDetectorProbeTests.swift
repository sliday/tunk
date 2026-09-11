import XCTest
@testable import TunkCore

/// Audit probe: one non-finite sample must not deafen the detector.
///
/// All fixtures are SYNTHETIC (see SyntheticSignal.swift). A NaN or Inf value
/// entering the one-pole high pass poisons `prevIn`/`prevOut`; every later
/// output is NaN, the noise floor becomes NaN, and `envelope >= threshold` is
/// false forever. The gap-reset path covers dropped samples but not bad values,
/// so a corrupted value has to be treated like a dropout.
final class AuditDetectorProbeTests: XCTestCase {

    private func poison(_ samples: [AccelSample], atNs tNs: Int64,
                        _ mutate: (inout AccelSample) -> Void) -> [AccelSample] {
        var out = samples
        guard let i = out.firstIndex(where: { $0.tNs >= tNs }) else {
            XCTFail("no sample at \(tNs)")
            return out
        }
        mutate(&out[i])
        return out
    }

    func testANaNSampleDoesNotDeafenTheDetectorForever() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let clean = stream.samples()
        let control = TapDetector.replay(samples: clean, inputs: [])
        XCTAssertEqual(control.triggers.count, 1)
        XCTAssertEqual(control.onsets.count, 2)

        // One bad value 376.8 ms in; the double-tap lands 1.1 s later.
        let poisoned = poison(clean, atNs: 376_800_000) { $0.z = .nan }
        let result = TapDetector.replay(samples: poisoned, inputs: [])
        XCTAssertEqual(result.triggers.count, control.triggers.count,
                       "one NaN sample must not silence the detector for the session")
        XCTAssertEqual(result.onsets.count, control.onsets.count)
    }

    func testAnInfiniteSampleDoesNotDeafenTheDetectorForever() {
        let (stream, _) = SyntheticStream.gesture(count: 2, spacingNs: 150_000_000)
        let clean = stream.samples()
        let control = TapDetector.replay(samples: clean, inputs: [])
        XCTAssertEqual(control.triggers.count, 1)

        let poisoned = poison(clean, atNs: 376_800_000) { $0.x = .infinity }
        let result = TapDetector.replay(samples: poisoned, inputs: [])
        XCTAssertEqual(result.triggers.count, control.triggers.count,
                       "one Inf sample must not silence the detector for the session")
    }

    func testANaNSampleAfterAGestureDoesNotDeafenTheNext() {
        let lead = SyntheticStream.leadInNs
        let second = lead + 2_500_000_000
        var stream = SyntheticStream(durationNs: second + 150_000_000 + 1_000_000_000)
        stream.taps = [lead, lead + 150_000_000, second, second + 150_000_000]
            .map { SyntheticStream.Tap(tNs: $0, amplitude: 0.9) }
        let clean = stream.samples()
        XCTAssertEqual(TapDetector.replay(samples: clean, inputs: []).triggers.count, 2)

        let poisoned = poison(clean, atNs: lead + 1_000_000_000) { $0.z = .nan }
        let detector = TapDetector()
        var fired = 0
        for s in poisoned where detector.ingest(sample: s) != nil { fired += 1 }
        XCTAssertEqual(fired, 2, "the gesture after the bad sample must still fire")
        XCTAssertTrue(detector.envelope.isFinite, "envelope must not stay NaN")
        XCTAssertTrue(detector.noiseFloor.isFinite, "noise floor must not stay NaN")
    }
}
