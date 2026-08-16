import Foundation

// The axis structure of a transient, which every earlier stage threw away.
//
// `SignalChain` collapses the three high-passed axes to a vector magnitude on
// the sample it reads them, so nothing downstream can tell a transient that
// moves the chassis along ONE line from one that moves it along several. That
// difference is physical: a ring lobe is a single chassis mode decaying, so its
// 3-axis covariance is nearly rank one, while a fresh contact is broadband and
// excites several modes at once.
//
// Measured on `data/raw` over the 10 ms after a crest, against amplitude-matched
// lobes: lap ring lobes rect p50 0.9955, lap real strikes rect p50 0.9310.

/// Eigenvalues and the principal eigenvector of a symmetric 3x3 matrix, in
/// closed form.
///
/// Closed form rather than power iteration for two reasons. It is exactly
/// reproducible — the same six numbers give the same answer bit for bit, with no
/// iteration count to tune and no convergence test that could behave differently
/// on a degenerate matrix — and it touches no heap: every intermediate is a
/// scalar on the stack.
///
/// Eigenvalues come from Smith's trigonometric solution of the characteristic
/// cubic (`Communications of the ACM 4(4), 1961`), which is stable for the
/// positive semi-definite matrices a covariance produces. The eigenvector is the
/// null space of `A - lam1 I`, taken as the largest of the three cross products
/// of that matrix's rows: for a rank-one covariance two rows are parallel, so
/// picking the largest cross product is what keeps the answer well conditioned.
public enum SymmetricEigen3 {

    /// `lambda1 >= lambda2 >= lambda3`, plus a unit eigenvector for `lambda1`.
    ///
    /// The eigenvector's sign is fixed by making its largest-magnitude component
    /// positive, so the same matrix always yields the same vector rather than
    /// one of its two antipodes. Callers compare directions with `abs(dot)`
    /// anyway; the convention exists so logs and tests are stable.
    public struct Result: Sendable, Equatable {
        public var lambda1: Double
        public var lambda2: Double
        public var lambda3: Double
        public var ux: Double
        public var uy: Double
        public var uz: Double
    }

    public static func decompose(xx: Double, xy: Double, xz: Double,
                                 yy: Double, yz: Double, zz: Double) -> Result {
        let offDiagonal = xy * xy + xz * xz + yz * yz
        if !(offDiagonal > 0) {
            // Already diagonal. Sorting three numbers beats running the cubic on
            // a matrix whose answer is written on its face, and it dodges the
            // division by `p` below, which is zero here.
            return diagonalResult(xx: xx, yy: yy, zz: zz)
        }

        let q = (xx + yy + zz) / 3.0
        let dxx = xx - q, dyy = yy - q, dzz = zz - q
        let p2 = dxx * dxx + dyy * dyy + dzz * dzz + 2.0 * offDiagonal
        let p = (p2 / 6.0).squareRoot()
        guard p > 0 else { return diagonalResult(xx: xx, yy: yy, zz: zz) }

        let b00 = dxx / p, b11 = dyy / p, b22 = dzz / p
        let b01 = xy / p, b02 = xz / p, b12 = yz / p
        let detB = b00 * (b11 * b22 - b12 * b12)
                 - b01 * (b01 * b22 - b12 * b02)
                 + b02 * (b01 * b12 - b11 * b02)
        // `detB / 2` is a cosine by construction; rounding can push it a hair
        // outside the domain of `acos` on a near-degenerate matrix.
        let r = min(max(detB / 2.0, -1.0), 1.0)
        let phi = acos(r) / 3.0

        let lambda1 = q + 2.0 * p * cos(phi)
        let lambda3 = q + 2.0 * p * cos(phi + 2.0 * Double.pi / 3.0)
        // The trace is exact, so deriving the middle eigenvalue from it is more
        // accurate than evaluating a third cosine.
        let lambda2 = 3.0 * q - lambda1 - lambda3

        let (ux, uy, uz) = principalAxis(xx: xx, xy: xy, xz: xz, yy: yy, yz: yz, zz: zz,
                                         lambda: lambda1)
        return Result(lambda1: lambda1, lambda2: lambda2, lambda3: lambda3,
                      ux: ux, uy: uy, uz: uz)
    }

    private static func diagonalResult(xx: Double, yy: Double, zz: Double) -> Result {
        var v0 = xx, v1 = yy, v2 = zz
        if v1 > v0 { swap(&v0, &v1) }
        if v2 > v1 { swap(&v1, &v2) }
        if v1 > v0 { swap(&v0, &v1) }
        let axis: (Double, Double, Double)
        if xx >= yy && xx >= zz {
            axis = (1, 0, 0)
        } else if yy >= zz {
            axis = (0, 1, 0)
        } else {
            axis = (0, 0, 1)
        }
        return Result(lambda1: v0, lambda2: v1, lambda3: v2,
                      ux: axis.0, uy: axis.1, uz: axis.2)
    }

    private static func principalAxis(xx: Double, xy: Double, xz: Double,
                                      yy: Double, yz: Double, zz: Double,
                                      lambda: Double) -> (Double, Double, Double) {
        // Rows of A - lambda I. Two of them span the plane orthogonal to the
        // eigenvector, so their cross product is the eigenvector.
        let r0 = (xx - lambda, xy, xz)
        let r1 = (xy, yy - lambda, yz)
        let r2 = (xz, yz, zz - lambda)

        let c01 = cross(r0, r1)
        let c02 = cross(r0, r2)
        let c12 = cross(r1, r2)
        let n01 = norm2(c01), n02 = norm2(c02), n12 = norm2(c12)

        var best = c01
        var bestNorm = n01
        if n02 > bestNorm { best = c02; bestNorm = n02 }
        if n12 > bestNorm { best = c12; bestNorm = n12 }
        guard bestNorm > 0 else { return (0, 0, 1) }

        let inv = 1.0 / bestNorm.squareRoot()
        var (ux, uy, uz) = (best.0 * inv, best.1 * inv, best.2 * inv)
        // Fixed sign, so one matrix has one answer.
        let ax = abs(ux), ay = abs(uy), az = abs(uz)
        let dominant = ax >= ay && ax >= az ? ux : (ay >= az ? uy : uz)
        if dominant < 0 { ux = -ux; uy = -uy; uz = -uz }
        return (ux, uy, uz)
    }

    @inline(__always)
    private static func cross(_ a: (Double, Double, Double),
                              _ b: (Double, Double, Double)) -> (Double, Double, Double) {
        (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0)
    }

    @inline(__always)
    private static func norm2(_ v: (Double, Double, Double)) -> Double {
        v.0 * v.0 + v.1 * v.1 + v.2 * v.2
    }
}

/// Trailing covariance of the three high-passed axes over a short window,
/// reduced to the two numbers the pairing stage acts on.
///
/// - `rectilinearity` is `1 - lambda2 / lambda1`: 1 when the chassis is moving
///   along a single line, falling towards 0 as the motion spreads across a plane
///   or a sphere. Nothing else in the detector can express that.
/// - `axis` is the unit principal eigenvector, i.e. WHICH line.
///
/// The window is trailing and ends at the current sample, so the value published
/// after sample `n` describes samples `n-window+1 ... n`. Nothing here looks
/// ahead; the caller supplies the lag by reading the tracker a fixed number of
/// samples after the instant it cares about.
///
/// The six sums are recomputed from a ring each sample rather than carried as
/// running totals. At the shipped window that is 24 multiply-adds per sample,
/// under 20 000 per second at 796 Hz, and it cannot drift: a running total over
/// a million-sample session accumulates cancellation error that a fixed window
/// never sees. Allocation happens once, in `init`.
public struct PolarizationTracker: Sendable, Equatable {
    /// Largest window the tracker will build, so a bad config cannot ask for an
    /// unbounded buffer.
    public static let maxWindow = 64

    public let window: Int
    private var bufX: ContiguousArray<Double>
    private var bufY: ContiguousArray<Double>
    private var bufZ: ContiguousArray<Double>
    private var head: Int = 0
    private var filled: Int = 0

    /// `1 - lambda2 / lambda1` over the trailing window. 0 until the window has
    /// filled, which is well inside `DSPTuning.warmupSamples`.
    public private(set) var rectilinearity: Double = 0
    public private(set) var axisX: Double = 0
    public private(set) var axisY: Double = 0
    public private(set) var axisZ: Double = 1

    public init(window: Int) {
        let w = min(max(window, 2), Self.maxWindow)
        self.window = w
        bufX = ContiguousArray(repeating: 0, count: w)
        bufY = ContiguousArray(repeating: 0, count: w)
        bufZ = ContiguousArray(repeating: 0, count: w)
    }

    public mutating func reset() {
        for i in 0..<window { bufX[i] = 0; bufY[i] = 0; bufZ[i] = 0 }
        head = 0
        filled = 0
        rectilinearity = 0
        axisX = 0; axisY = 0; axisZ = 1
    }

    @inline(__always)
    public mutating func process(x: Double, y: Double, z: Double) {
        bufX[head] = x; bufY[head] = y; bufZ[head] = z
        head = (head + 1) % window
        if filled < window { filled += 1 }
        guard filled == window else {
            rectilinearity = 0
            axisX = 0; axisY = 0; axisZ = 1
            return
        }

        var sxx = 0.0, sxy = 0.0, sxz = 0.0, syy = 0.0, syz = 0.0, szz = 0.0
        // Oldest to newest, so the summation order is the sample order and does
        // not rotate with the ring.
        for k in 0..<window {
            let i = (head + k) % window
            let ax = bufX[i], ay = bufY[i], az = bufZ[i]
            sxx += ax * ax
            sxy += ax * ay
            sxz += ax * az
            syy += ay * ay
            syz += ay * az
            szz += az * az
        }

        let e = SymmetricEigen3.decompose(xx: sxx, xy: sxy, xz: sxz, yy: syy, yz: syz, zz: szz)
        rectilinearity = e.lambda1 > 0 ? 1.0 - e.lambda2 / e.lambda1 : 0
        axisX = e.ux; axisY = e.uy; axisZ = e.uz
    }

    /// `|u . v|`, the alignment of two axes ignoring sign. Two transients that
    /// shake the chassis along the same line score 1 whichever way each one
    /// happened to start.
    @inline(__always)
    public func alignment(withX x: Double, y: Double, z: Double) -> Double {
        abs(axisX * x + axisY * y + axisZ * z)
    }
}
