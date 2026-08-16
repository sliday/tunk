import XCTest
@testable import TunkCore

/// `DSPTuning.lapPairingExperiment` is what the app's experimental switch turns
/// on, and `notes/m26/G_m26_anchor030.json` is what a critic replays to check it.
/// Two copies of the same five numbers in two languages drift silently, and the
/// drift would be invisible: the switch would still work, the harness would still
/// pass, and the panel would be quoting a run of something else.
///
/// Nothing here re-grades the mechanism. It asserts the two copies agree, and
/// that the shipped default is untouched by its existence.
final class LapPairingExperimentTuningTests: XCTestCase {
    /// The five keys of notes/m26/G_m26_anchor030.json, transcribed. Everything
    /// absent from that file must equal `DSPTuning.default`.
    func testExperimentIsTheGradedConfigAndNothingElse() {
        let e = DSPTuning.lapPairingExperiment
        XCTAssertTrue(e.pairRescueEnabled)
        XCTAssertEqual(e.pairRescueCandidateFraction, 0.5)
        XCTAssertEqual(e.pairRescueCosMin, 0.7)
        XCTAssertTrue(e.pairRescueRankByRect)
        XCTAssertEqual(e.pairRescueAnchorFraction, 0.30)

        // Not in the config file, so it takes the shipped value. rectMax above 1
        // means the outright rectilinearity rejection never fires and the ranking
        // does the work, which is the configuration that was graded.
        let d = DSPTuning.default
        XCTAssertEqual(e.pairRescueRectMax, d.pairRescueRectMax)
        XCTAssertEqual(e.polarizationWindowSamples, d.polarizationWindowSamples)
        XCTAssertEqual(e.polarizationLookaheadSamples, d.polarizationLookaheadSamples)

        // The whole front end, untouched. If a future round moves one of these
        // for the experiment, it moved it for the shipped detector too and this
        // catches which.
        XCTAssertEqual(e.sampleRateHz, d.sampleRateHz)
        XCTAssertEqual(e.highPassHz, d.highPassHz)
        XCTAssertEqual(e.envelopePeakSamples, d.envelopePeakSamples)
        XCTAssertEqual(e.noiseSnrMultiple, d.noiseSnrMultiple)
        XCTAssertEqual(e.minThresholdG, d.minThresholdG)
        XCTAssertEqual(e.releaseFraction, d.releaseFraction)
        XCTAssertEqual(e.onsetDebounceNs, d.onsetDebounceNs)
        XCTAssertEqual(e.peakHoldNs, d.peakHoldNs)
        XCTAssertEqual(e.preGateNs, d.preGateNs)
        XCTAssertEqual(e.resonatorHz, d.resonatorHz)
    }

    /// The claim the whole landing rests on: naming the experiment does not move
    /// what ships. `default` is the value every non-app caller still gets.
    func testDefaultStillShipsThePairRescueOff() {
        XCTAssertFalse(DSPTuning.default.pairRescueEnabled)
        XCTAssertEqual(DSPTuning.default.pairRescueAnchorFraction, 0.0)
        XCTAssertEqual(TapDetector().tuning, DSPTuning.default)
    }

    /// A detector built on the default allocates no polarization tracker, so the
    /// experiment costs the shipped path one branch per sample and no arithmetic.
    /// Asserted through the public readout rather than by reaching into storage.
    func testDefaultChainReportsNoPolarization() {
        var chain = SignalChain(tuning: .default)
        for i in 0..<64 {
            chain.process(x: Double(i % 3) * 0.01, y: 0.02, z: 1.0, holdNoiseFloor: false)
        }
        XCTAssertEqual(chain.rectilinearity, 0)
        XCTAssertEqual(chain.polarizationAxis.z, 1)

        var on = SignalChain(tuning: .lapPairingExperiment)
        for i in 0..<64 {
            on.process(x: Double(i % 3) * 0.01, y: 0.02, z: 1.0, holdNoiseFloor: false)
        }
        XCTAssertGreaterThan(on.rectilinearity, 0)
    }
}
