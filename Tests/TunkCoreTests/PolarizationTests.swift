import XCTest
@testable import TunkCore

/// The polarization statistic on its own, before any question of what the
/// detector does with it.
///
/// A rate measured end to end cannot tell "the statistic is right" from "the
/// statistic is wrong and the thresholds absorb it", and this mechanism rests
/// entirely on one number meaning what it claims. So: eigenvalues against a
/// matrix whose answer is known by hand, rectilinearity against motion built to
/// be rectilinear or not, and the window's own edges.
final class PolarizationTests: XCTestCase {

    // MARK: - The eigen solver

    func testEigenvaluesOfADiagonalMatrixAreItsDiagonalSorted() {
        let e = SymmetricEigen3.decompose(xx: 1, xy: 0, xz: 0, yy: 7, yz: 0, zz: 3)
        XCTAssertEqual(e.lambda1, 7, accuracy: 1e-12)
        XCTAssertEqual(e.lambda2, 3, accuracy: 1e-12)
        XCTAssertEqual(e.lambda3, 1, accuracy: 1e-12)
        XCTAssertEqual(abs(e.uy), 1, accuracy: 1e-12, "the largest eigenvalue is on y")
    }

    /// `u u^T` for a unit vector `u` has eigenvalues 1, 0, 0 and eigenvector
    /// `u`. This is exactly the shape a single decaying chassis mode produces,
    /// so it is the case the whole mechanism turns on.
    ///
    /// The tolerance is 1e-7 rather than machine epsilon, and that is a property
    /// of the closed form, not sloppiness: a repeated eigenvalue puts the cubic's
    /// discriminant at the edge of `acos`'s domain, where a rounding error of
    /// 1e-16 in the argument becomes ~1e-8 in the root. It costs nothing here.
    /// The rectilinearities this mechanism separates differ by 6e-2 (lap ring
    /// lobes p50 0.9955 against real strikes 0.9310), four orders of magnitude
    /// above the error, and the ranking is by comparison, not by absolute value.
    func testARankOneMatrixIsPerfectlyRectilinear() {
        let n = (0.3, -0.5, 0.81)
        let len = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
        let u = (n.0 / len, n.1 / len, n.2 / len)
        let e = SymmetricEigen3.decompose(xx: u.0 * u.0, xy: u.0 * u.1, xz: u.0 * u.2,
                                          yy: u.1 * u.1, yz: u.1 * u.2, zz: u.2 * u.2)
        XCTAssertEqual(e.lambda1, 1, accuracy: 1e-7)
        XCTAssertEqual(e.lambda2, 0, accuracy: 1e-7)
        XCTAssertEqual(e.lambda3, 0, accuracy: 1e-7)
        XCTAssertEqual(abs(e.ux * u.0 + e.uy * u.1 + e.uz * u.2), 1, accuracy: 1e-9)
        XCTAssertEqual(1 - e.lambda2 / e.lambda1, 1, accuracy: 1e-7)
    }

    /// Random symmetric matrices, checked against the definitions rather than
    /// against another implementation: the eigenvalues must satisfy the trace
    /// and determinant identities, and the reported eigenvector must actually be
    /// one, `A u = lambda1 u`.
    func testEigenDecompositionSatisfiesItsOwnDefinition() {
        var rng = SyntheticNoise(seed: 20260816)
        for _ in 0..<500 {
            // Build A = M M^T so it is symmetric positive semi-definite, which
            // is what a covariance is.
            var m = [[Double]](repeating: [0, 0, 0], count: 3)
            for r in 0..<3 { for c in 0..<3 { m[r][c] = rng.next(1.0) } }
            func dot(_ a: Int, _ b: Int) -> Double {
                (0..<3).reduce(0) { $0 + m[a][$1] * m[b][$1] }
            }
            let xx = dot(0, 0), xy = dot(0, 1), xz = dot(0, 2)
            let yy = dot(1, 1), yz = dot(1, 2), zz = dot(2, 2)
            let e = SymmetricEigen3.decompose(xx: xx, xy: xy, xz: xz, yy: yy, yz: yz, zz: zz)

            XCTAssertGreaterThanOrEqual(e.lambda1, e.lambda2 - 1e-12)
            XCTAssertGreaterThanOrEqual(e.lambda2, e.lambda3 - 1e-12)
            XCTAssertGreaterThanOrEqual(e.lambda3, -1e-9, "a covariance has no negative eigenvalue")

            let trace = xx + yy + zz
            XCTAssertEqual(e.lambda1 + e.lambda2 + e.lambda3, trace, accuracy: 1e-9 * max(1, trace))

            let det = xx * (yy * zz - yz * yz) - xy * (xy * zz - yz * xz) + xz * (xy * yz - yy * xz)
            XCTAssertEqual(e.lambda1 * e.lambda2 * e.lambda3, det,
                           accuracy: 1e-8 * max(1, abs(det)))

            let au = (xx * e.ux + xy * e.uy + xz * e.uz,
                      xy * e.ux + yy * e.uy + yz * e.uz,
                      xz * e.ux + yz * e.uy + zz * e.uz)
            let residual = ((au.0 - e.lambda1 * e.ux) * (au.0 - e.lambda1 * e.ux)
                            + (au.1 - e.lambda1 * e.uy) * (au.1 - e.lambda1 * e.uy)
                            + (au.2 - e.lambda1 * e.uz) * (au.2 - e.lambda1 * e.uz)).squareRoot()
            XCTAssertLessThan(residual, 1e-7 * max(1, e.lambda1))
            XCTAssertEqual((e.ux * e.ux + e.uy * e.uy + e.uz * e.uz).squareRoot(), 1, accuracy: 1e-9)
        }
    }

    /// Same matrix, same answer, every time and in either order of arrival.
    /// The detector's contract is that replay reproduces live exactly, and an
    /// eigen solver that iterated to a tolerance could break that quietly.
    func testTheSolverIsBitReproducible() {
        var rng = SyntheticNoise(seed: 7)
        for _ in 0..<200 {
            let a = abs(rng.next(1.0)), b = rng.next(1.0), c = rng.next(1.0)
            let d = abs(rng.next(1.0)), f = rng.next(1.0), g = abs(rng.next(1.0))
            let first = SymmetricEigen3.decompose(xx: a, xy: b, xz: c, yy: d, yz: f, zz: g)
            let second = SymmetricEigen3.decompose(xx: a, xy: b, xz: c, yy: d, yz: f, zz: g)
            XCTAssertEqual(first, second)
        }
    }

    // MARK: - The tracker

    /// Motion along one line, whatever its waveform, is rectilinear. This is the
    /// ring-lobe case: one mode, decaying.
    func testMotionAlongOneLineReadsAsRectilinear() {
        var tracker = PolarizationTracker(window: 8)
        let axis = (0.35, 0.25, 1.0)
        let norm = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot()
        for i in 0..<40 {
            let s = exp(-Double(i) / 6) * sin(Double(i) * 1.3)
            tracker.process(x: axis.0 * s, y: axis.1 * s, z: axis.2 * s)
        }
        XCTAssertEqual(tracker.rectilinearity, 1, accuracy: 1e-9)
        XCTAssertEqual(tracker.alignment(withX: axis.0 / norm, y: axis.1 / norm, z: axis.2 / norm),
                       1, accuracy: 1e-9)
    }

    /// Two independent modes of equal power drive the second eigenvalue up to
    /// the first, and rectilinearity to zero. This is the fresh-contact case:
    /// broadband, several modes at once.
    func testTwoModesOfEqualPowerReadAsNotRectilinear() {
        var tracker = PolarizationTracker(window: 8)
        for i in 0..<64 {
            let phase = Double(i) * Double.pi / 4
            tracker.process(x: cos(phase), y: sin(phase), z: 0)
        }
        XCTAssertLessThan(tracker.rectilinearity, 0.05)
    }

    func testARingLobeScoresHigherThanABroadbandContact() {
        // Deliberately the comparison the mechanism makes, at the shipped
        // window, with the same amplitude on both so only the axis structure
        // can separate them.
        var lobe = PolarizationTracker(window: 8)
        var contact = PolarizationTracker(window: 8)
        var rng = SyntheticNoise(seed: 4242)
        for i in 0..<8 {
            let s = exp(-Double(i) / 5)
            lobe.process(x: 0.35 * s, y: 0.25 * s, z: s)
            contact.process(x: rng.next(1.0) * s, y: rng.next(1.0) * s, z: rng.next(1.0) * s)
        }
        XCTAssertGreaterThan(lobe.rectilinearity, 0.99)
        XCTAssertLessThan(contact.rectilinearity, lobe.rectilinearity)
    }

    /// The window is trailing and finite: what happened before it cannot reach
    /// the value it publishes. Without this the statistic would carry a tail of
    /// the previous transient into the next one's reading.
    func testTheValueDependsOnlyOnTheLastWindowSamples() {
        var polluted = PolarizationTracker(window: 8)
        var clean = PolarizationTracker(window: 8)
        var rng = SyntheticNoise(seed: 99)
        for _ in 0..<50 { polluted.process(x: rng.next(1.0), y: rng.next(1.0), z: rng.next(1.0)) }
        for i in 0..<8 {
            let s = exp(-Double(i) / 4)
            polluted.process(x: 0.2 * s, y: -0.9 * s, z: 0.3 * s)
            clean.process(x: 0.2 * s, y: -0.9 * s, z: 0.3 * s)
        }
        XCTAssertEqual(polluted.rectilinearity, clean.rectilinearity, accuracy: 1e-12)
        XCTAssertEqual(polluted.axisX, clean.axisX, accuracy: 1e-12)
        XCTAssertEqual(polluted.axisY, clean.axisY, accuracy: 1e-12)
        XCTAssertEqual(polluted.axisZ, clean.axisZ, accuracy: 1e-12)
    }

    func testTheTrackerPublishesNothingUntilItsWindowIsFull() {
        var tracker = PolarizationTracker(window: 8)
        for i in 0..<7 {
            tracker.process(x: 1, y: 0, z: 0)
            XCTAssertEqual(tracker.rectilinearity, 0, "sample \(i) is inside the fill")
        }
        tracker.process(x: 1, y: 0, z: 0)
        XCTAssertEqual(tracker.rectilinearity, 1, accuracy: 1e-12)
    }

    func testResetReturnsTheTrackerToItsOpeningState() {
        var tracker = PolarizationTracker(window: 8)
        var rng = SyntheticNoise(seed: 5)
        for _ in 0..<40 { tracker.process(x: rng.next(1.0), y: rng.next(1.0), z: rng.next(1.0)) }
        tracker.reset()
        XCTAssertEqual(tracker.rectilinearity, 0)
        XCTAssertEqual(PolarizationTracker(window: 8), tracker)
    }

    /// Sign is not information here: two strikes that shake the chassis along
    /// one line agree whichever way each one happened to start.
    func testAlignmentIgnoresSign() {
        var tracker = PolarizationTracker(window: 8)
        for i in 0..<8 {
            let s = exp(-Double(i) / 5)
            tracker.process(x: 0, y: 0, z: s)
        }
        XCTAssertEqual(tracker.alignment(withX: 0, y: 0, z: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(tracker.alignment(withX: 0, y: 0, z: -1), 1, accuracy: 1e-12)
        XCTAssertEqual(tracker.alignment(withX: 1, y: 0, z: 0), 0, accuracy: 1e-12)
    }

    /// A window request outside what the tracker will build is clamped rather
    /// than trusted, so a config typo cannot ask for an unbounded buffer.
    func testTheWindowIsClamped() {
        XCTAssertEqual(PolarizationTracker(window: 0).window, 2)
        XCTAssertEqual(PolarizationTracker(window: 10_000).window, PolarizationTracker.maxWindow)
    }

    /// The chain hands the tracker the SAME three numbers it is about to
    /// collapse into the magnitude, so the statistic describes the signal the
    /// threshold is applied to and not some parallel copy of it.
    func testTheSignalChainFeedsTheTrackerItsOwnHighPassedAxes() {
        var tuning = DSPTuning.default
        tuning.pairRescueEnabled = true
        var chain = SignalChain(tuning: tuning)
        var reference = PolarizationTracker(window: tuning.polarizationWindowSamples)
        var hpX = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        var hpY = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)
        var hpZ = OnePoleHighPass(cutoffHz: tuning.highPassHz, sampleRateHz: tuning.sampleRateHz)

        var stream = SyntheticStream(durationNs: SyntheticStream.leadInNs + 500_000_000)
        stream.taps = [.init(tNs: SyntheticStream.leadInNs, amplitude: 0.9)]
        for s in stream.samples() {
            _ = chain.process(x: Double(s.x), y: Double(s.y), z: Double(s.z), holdNoiseFloor: false)
            reference.process(x: hpX.process(Double(s.x)),
                              y: hpY.process(Double(s.y)),
                              z: hpZ.process(Double(s.z)))
            XCTAssertEqual(chain.rectilinearity, reference.rectilinearity, accuracy: 1e-12)
        }
    }

    /// Off, the tracker is not merely ignored: it is absent, and reads as a
    /// fixed neutral value. Nothing downstream can accidentally act on a stale
    /// number when the mechanism is disabled.
    func testTheTrackerIsAbsentWhenTheMechanismIsOff() {
        var chain = SignalChain(tuning: .default)
        XCTAssertFalse(DSPTuning.default.pairRescueEnabled)
        var rng = SyntheticNoise(seed: 3)
        for _ in 0..<100 {
            _ = chain.process(x: rng.next(0.5), y: rng.next(0.5), z: -0.98 + rng.next(0.5),
                              holdNoiseFloor: false)
        }
        XCTAssertEqual(chain.rectilinearity, 0)
        XCTAssertEqual(chain.polarizationAxis.z, 1)
    }
}
