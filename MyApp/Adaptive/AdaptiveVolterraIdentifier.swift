import Accelerate
import Foundation

nonisolated enum AdaptiveAlgorithm: String, CaseIterable, Identifiable, Sendable {
    /// Normalized LMS — O(K) per sample, step size μ ∈ (0, 2).
    case nlms = "NLMS"
    /// Exponentially weighted RLS — O(K²) per sample, converges in ≈ 2K samples.
    case rls = "RLS"
    /// Same exponentially weighted LS cost as RLS, solved once per block from the
    /// accumulated normal equations (R ← λᴺR + ΦᴴΦ, b ← λᴺb + Φᴴd). The O(N·K²)
    /// work runs as BLAS matrix products instead of N sequential rank-1 updates.
    case blockRLS = "Block RLS"

    var id: String { rawValue }

    /// Whether λ / δ apply (both RLS variants).
    var usesForgettingFactor: Bool { self != .nlms }

    /// Sample-by-sample RLS is kept as the textbook reference, but it is O(K²) per
    /// sample: 25.8 ms per 4096-sample frame at K = 44 and 350 ms at K = 296 (Release,
    /// Apple M5). Above K ≈ 60 it misses a 50 ms frame budget, so flag it from there.
    static let rlsCostWarningTermCount = 60

    func costWarning(termCount: Int) -> String? {
        guard self == .rls, termCount > Self.rlsCostWarningTermCount else { return nil }
        return "Sample-by-sample RLS is O(K²) per sample and slow at K = \(termCount). " +
            "Block RLS solves the same least-squares problem several times faster."
    }
}

nonisolated struct AdaptationParameters: Sendable, Equatable, Hashable {
    var algorithm: AdaptiveAlgorithm = .rls
    /// NLMS step size μ.
    var stepSize: Double = 0.25
    /// NLMS regularization ε added to ‖φ‖².
    var epsilon: Double = 1e-6
    /// RLS forgetting factor λ.
    var forgettingFactor: Double = 0.9995
    /// RLS initialization P(0) = δ⁻¹·I. δ acts as a ridge prior δ·λⁿ‖h‖²: larger
    /// values bias coefficients that the (oversampled, correlated) input barely excites.
    var delta: Double = 1e-4

    var seriesLabel: String {
        switch algorithm {
        case .nlms: "NLMS μ = \(stepSize.formatted(.number.precision(.significantDigits(2))))"
        case .rls: "RLS λ = \(forgettingFactor.formatted(.number.precision(.fractionLength(4))))"
        case .blockRLS: "Block RLS λ = \(forgettingFactor.formatted(.number.precision(.fractionLength(4))))"
        }
    }
}

/// Row-major Volterra regressors φ(n) (N × K, split complex, Double precision).
/// Row n satisfies ŷ(n) = φ(n)ᵀ·h for the layout's coefficient order.
nonisolated struct RegressorRows: Sendable {
    let real: [Double]
    let imag: [Double]
    let count: Int
    let width: Int

    /// Builds Φ with the vectorized Phase 2 column filler, then transposes so
    /// every per-sample regressor is contiguous for the adaptive update.
    static func build(extended: ComplexSignalBlock, layout: VolterraKernelLayout) -> RegressorRows {
        let phi = VolterraCPUEngine.regressionMatrix(extended: extended, layout: layout)
        let n = phi.rows
        let k = layout.termCount
        guard n > 0 else { return RegressorRows(real: [], imag: [], count: 0, width: k) }

        // Column-major N×K ≡ row-major K×N; vDSP_mtrans gives row-major N×K.
        var rowR = [Float](repeating: 0, count: n * k)
        var rowI = [Float](repeating: 0, count: n * k)
        vDSP_mtrans(phi.real, 1, &rowR, 1, vDSP_Length(n), vDSP_Length(k))
        vDSP_mtrans(phi.imag, 1, &rowI, 1, vDSP_Length(n), vDSP_Length(k))
        return RegressorRows(real: vDSP.floatToDouble(rowR), imag: vDSP.floatToDouble(rowI), count: n, width: k)
    }
}

/// Adaptive identification of complex Volterra kernels.
///
/// Model ŷ(n) = φ(n)ᵀh, a-priori error e(n) = d(n) − φ(n)ᵀh(n−1).
///
/// NLMS:  h ← h + μ·e·φ* / (ε + ‖φ‖²)
///
/// RLS (cost Σ λⁿ⁻ⁱ|e(i)|², P = R⁻¹, R = Σ λⁿ⁻ⁱ φ*φᵀ):
///     π = P·φ*
///     k = π / (λ + φᵀπ)
///     h ← h + k·e
///     P ← (P − k·πᴴ) / λ
///
/// All internal state is Double: single-precision RLS loses positive
/// definiteness of P within a few thousand updates when λ < 1.
nonisolated struct AdaptiveVolterraIdentifier: Sendable {
    let layout: VolterraKernelLayout
    var parameters: AdaptationParameters

    private(set) var hr: [Double]
    private(set) var hi: [Double]
    /// RLS: inverse correlation P. Block RLS: correlation R = Σ λⁿ⁻ⁱ φ*φᵀ.
    private var pr: [Double] = []
    private var pi: [Double] = []
    /// Block RLS cross-correlation b = Σ λⁿ⁻ⁱ φ*·d.
    private var br: [Double] = []
    private var bi: [Double] = []
    private var updatesSinceSymmetrize = 0
    private(set) var diverged = false
    private(set) var samplesProcessed = 0

    /// Re-impose Hermitian symmetry on P this often to stop round-off drift.
    private static let symmetrizeInterval = 256

    init(layout: VolterraKernelLayout, parameters: AdaptationParameters, initial: VolterraKernels? = nil) {
        self.layout = layout
        self.parameters = parameters
        let k = layout.termCount
        if let initial, initial.layout == layout {
            hr = vDSP.floatToDouble(initial.real)
            hi = vDSP.floatToDouble(initial.imag)
        } else {
            hr = [Double](repeating: 0, count: k)
            hi = [Double](repeating: 0, count: k)
        }
        if parameters.algorithm.usesForgettingFactor { resetCovariance() }
    }

    /// RLS: P = δ⁻¹·I.  Block RLS: R = 0, b = 0 (δ is applied as a ridge at solve time).
    mutating func resetCovariance() {
        let k = layout.termCount
        pr = [Double](repeating: 0, count: k * k)
        pi = [Double](repeating: 0, count: k * k)
        br = [Double](repeating: 0, count: k)
        bi = [Double](repeating: 0, count: k)
        if parameters.algorithm == .rls {
            let diagonal = 1 / max(parameters.delta, 1e-12)
            for i in 0..<k { pr[i * k + i] = diagonal }
        }
        updatesSinceSymmetrize = 0
    }

    var kernels: VolterraKernels {
        var k = VolterraKernels(layout: layout)
        k.real = vDSP.doubleToFloat(hr)
        k.imag = vDSP.doubleToFloat(hi)
        return k
    }

    /// Adapts sample-by-sample over one block. Returns the a-priori |e(n)|².
    @discardableResult
    mutating func adapt(regressors rows: RegressorRows, desired d: ComplexSignalBlock) -> [Double] {
        precondition(rows.width == layout.termCount && rows.count == d.count, "Regressor/desired mismatch")
        let n = rows.count
        let k = layout.termCount
        var errorPower = [Double](repeating: .nan, count: n)
        guard n > 0, !diverged else { return errorPower }
        if parameters.algorithm == .blockRLS { return adaptBlock(rows, desired: d) }

        // Move state into locals so the unsafe pointers below never alias `self`.
        var hr = [Double](), hi = [Double](), pr = [Double](), pi = [Double]()
        swap(&hr, &self.hr); swap(&hi, &self.hi); swap(&pr, &self.pr); swap(&pi, &self.pi)
        defer {
            swap(&hr, &self.hr); swap(&hi, &self.hi); swap(&pr, &self.pr); swap(&pi, &self.pi)
        }

        let desiredReal = vDSP.floatToDouble(d.real)
        let desiredImag = vDSP.floatToDouble(d.imag)
        let params = parameters
        let len = vDSP_Length(k)

        // RLS scratch (uninitialized, manually managed to keep the per-sample loop allocation-free):
        //   piRI   = [πR ; πI]            2×K row-major (rank-1 right factor)
        //   gainA  = [kR kI] interleaved  K×2 row-major (left factor for PR)
        //   gainB  = [kI −kR] interleaved K×2 row-major (left factor for PI)
        //   outer  = K×K product scratch, also used for the transpose in re-symmetrization
        let isRLS = params.algorithm == .rls
        let scratchCount = isRLS ? k : 1
        let piRI = UnsafeMutablePointer<Double>.allocate(capacity: 2 * scratchCount)
        let gainA = UnsafeMutablePointer<Double>.allocate(capacity: 2 * scratchCount)
        let gainB = UnsafeMutablePointer<Double>.allocate(capacity: 2 * scratchCount)
        let t1 = UnsafeMutablePointer<Double>.allocate(capacity: scratchCount)
        let t2 = UnsafeMutablePointer<Double>.allocate(capacity: scratchCount)
        let outer = UnsafeMutablePointer<Double>.allocate(capacity: scratchCount * scratchCount)
        defer {
            piRI.deallocate(); gainA.deallocate(); gainB.deallocate()
            t1.deallocate(); t2.deallocate(); outer.deallocate()
        }
        let piR = piRI, piI = piRI + scratchCount
        var updates = updatesSinceSymmetrize
        var divergedHere = false

        rows.real.withUnsafeBufferPointer { arBuf in
        rows.imag.withUnsafeBufferPointer { aiBuf in
        hr.withUnsafeMutableBufferPointer { hrBuf in
        hi.withUnsafeMutableBufferPointer { hiBuf in
        pr.withUnsafeMutableBufferPointer { prBuf in
        pi.withUnsafeMutableBufferPointer { piBuf in
            let hR = hrBuf.baseAddress!, hI = hiBuf.baseAddress!

            for s in 0..<n {
                let aR = arBuf.baseAddress! + s * k
                let aI = aiBuf.baseAddress! + s * k

                // ŷ = φᵀh = (aR·hR − aI·hI) + j(aR·hI + aI·hR)
                var rr = 0.0, ii = 0.0, ri = 0.0, ir = 0.0
                vDSP_dotprD(aR, 1, hR, 1, &rr, len)
                vDSP_dotprD(aI, 1, hI, 1, &ii, len)
                vDSP_dotprD(aR, 1, hI, 1, &ri, len)
                vDSP_dotprD(aI, 1, hR, 1, &ir, len)
                let er = desiredReal[s] - (rr - ii)
                let ei = desiredImag[s] - (ri + ir)
                let e2 = er * er + ei * ei
                errorPower[s] = e2
                if !e2.isFinite || e2 > 1e8 {
                    divergedHere = true
                    break
                }

                switch params.algorithm {
                case .nlms:
                    var normR = 0.0, normI = 0.0
                    vDSP_svesqD(aR, 1, &normR, len)
                    vDSP_svesqD(aI, 1, &normI, len)
                    let g = params.stepSize / (params.epsilon + normR + normI)
                    // h += g·e·φ*:  Re = g(er·aR + ei·aI),  Im = g(ei·aR − er·aI)
                    var c1 = g * er, c2 = g * ei, c3 = -g * er
                    vDSP_vsmaD(aR, 1, &c1, hR, 1, hR, 1, len)
                    vDSP_vsmaD(aI, 1, &c2, hR, 1, hR, 1, len)
                    vDSP_vsmaD(aR, 1, &c2, hI, 1, hI, 1, len)
                    vDSP_vsmaD(aI, 1, &c3, hI, 1, hI, 1, len)

                case .blockRLS:
                    break   // dispatched to adaptBlock before the sample loop

                case .rls:
                    let pR = prBuf.baseAddress!, pI = piBuf.baseAddress!
                    let lambda = params.forgettingFactor

                    // π = P·φ*:  πR = PR·aR + PI·aI,  πI = PI·aR − PR·aI
                    vDSP_mmulD(pR, 1, aR, 1, t1, 1, len, 1, len)
                    vDSP_mmulD(pI, 1, aI, 1, t2, 1, len, 1, len)
                    vDSP_vaddD(t1, 1, t2, 1, piR, 1, len)
                    vDSP_mmulD(pI, 1, aR, 1, t1, 1, len, 1, len)
                    vDSP_mmulD(pR, 1, aI, 1, t2, 1, len, 1, len)
                    vDSP_vsubD(t2, 1, t1, 1, piI, 1, len)          // t1 − t2

                    // φᵀπ = φᴴ-quadratic form of P: real and positive.
                    var q1 = 0.0, q2 = 0.0
                    vDSP_dotprD(aR, 1, piR, 1, &q1, len)
                    vDSP_dotprD(aI, 1, piI, 1, &q2, len)
                    let denominator = lambda + (q1 - q2)
                    guard denominator.isFinite, denominator > 0 else {
                        divergedHere = true
                        break
                    }

                    // Gain k = π / den, written straight into the interleaved rank-1 factors:
                    //   gainA = [kR, kI] per row,  gainB = [kI, −kR] per row.
                    var invDen = 1 / denominator, negInvDen = -invDen
                    vDSP_vsmulD(piR, 1, &invDen, gainA, 2, len)
                    vDSP_vsmulD(piI, 1, &invDen, gainA + 1, 2, len)
                    vDSP_vsmulD(piI, 1, &invDen, gainB, 2, len)
                    vDSP_vsmulD(piR, 1, &negInvDen, gainB + 1, 2, len)
                    let kR = gainA, kI = gainA + 1          // stride-2 views of the gain

                    // h += k·e:  hR += kR·er − kI·ei,  hI += kR·ei + kI·er
                    var cer = er, cei = ei, nei = -ei
                    vDSP_vsmaD(kR, 2, &cer, hR, 1, hR, 1, len)
                    vDSP_vsmaD(kI, 2, &nei, hR, 1, hR, 1, len)
                    vDSP_vsmaD(kR, 2, &cei, hI, 1, hI, 1, len)
                    vDSP_vsmaD(kI, 2, &cer, hI, 1, hI, 1, len)

                    // P ← (P − k·πᴴ)/λ as two K×2·2×K outer products (BLAS-backed) and one
                    // fused subtract-scale each, instead of 4K per-row vector calls:
                    //   Re(k·πᴴ) = [kR kI]·[πR; πI],   Im(k·πᴴ) = [kI −kR]·[πR; πI]
                    var invLambda = 1 / lambda
                    let kk = vDSP_Length(k * k)
                    vDSP_mmulD(gainA, 1, piRI, 1, outer, 1, len, len, 2)
                    vDSP_vsbsmD(pR, 1, outer, 1, &invLambda, pR, 1, kk)
                    vDSP_mmulD(gainB, 1, piRI, 1, outer, 1, len, len, 2)
                    vDSP_vsbsmD(pI, 1, outer, 1, &invLambda, pI, 1, kk)

                    // Hermitian re-symmetrization: PR ← (PR + PRᵀ)/2, PI ← (PI − PIᵀ)/2.
                    updates += 1
                    if updates >= Self.symmetrizeInterval {
                        updates = 0
                        var half = 0.5
                        vDSP_mtransD(pR, 1, outer, 1, len, len)
                        vDSP_vaddD(pR, 1, outer, 1, pR, 1, kk)
                        vDSP_vsmulD(pR, 1, &half, pR, 1, kk)
                        vDSP_mtransD(pI, 1, outer, 1, len, len)
                        vDSP_vsubD(outer, 1, pI, 1, pI, 1, kk)   // PI − PIᵀ
                        vDSP_vsmulD(pI, 1, &half, pI, 1, kk)
                    }
                }
                if divergedHere { break }
            }
        }}}}}}

        updatesSinceSymmetrize = updates
        samplesProcessed += n
        if divergedHere { diverged = true }
        return errorPower
    }

    // MARK: - Block RLS

    /// One block of exponentially weighted least squares:
    ///
    ///     R ← λᴺ·R + ΦᴴΦ,   b ← λᴺ·b + Φᴴd,   h = (R + δI)⁻¹·b
    ///
    /// with ΦᴴΦ = (ΦᵣᵀΦᵣ + ΦᵢᵀΦᵢ) + j(ΦᵣᵀΦᵢ − ΦᵢᵀΦᵣ) and Φᴴd = (Φᵣᵀdᵣ + Φᵢᵀdᵢ) + j(Φᵣᵀdᵢ − Φᵢᵀdᵣ)
    /// as four N-deep real matrix products. The complex system is solved as the
    /// equivalent real symmetric positive-definite system [[Rᵣ, −Rᵢ], [Rᵢ, Rᵣ]]·[hᵣ; hᵢ] = [bᵣ; bᵢ].
    private mutating func adaptBlock(_ rows: RegressorRows, desired d: ComplexSignalBlock) -> [Double] {
        let n = rows.count
        let k = layout.termCount
        let nL = vDSP_Length(n), kL = vDSP_Length(k)
        let dr = vDSP.floatToDouble(d.real)
        let di = vDSP.floatToDouble(d.imag)

        // A-priori prediction with the previous block's solution: ŷ = Φh.
        let mm = Self.matmul
        let yr = vDSP.subtract(mm(rows.real, hr, n, 1, k), mm(rows.imag, hi, n, 1, k))
        let yi = vDSP.add(mm(rows.real, hi, n, 1, k), mm(rows.imag, hr, n, 1, k))
        let er = vDSP.subtract(dr, yr), ei = vDSP.subtract(di, yi)
        let errorPower = vDSP.add(vDSP.square(er), vDSP.square(ei))
        guard errorPower.allSatisfy({ $0.isFinite && $0 < 1e8 }) else {
            diverged = true
            return errorPower
        }

        // Φᵀ (K×N) for the Gram products.
        var phiRT = [Double](repeating: 0, count: n * k), phiIT = [Double](repeating: 0, count: n * k)
        vDSP_mtransD(rows.real, 1, &phiRT, 1, kL, nL)
        vDSP_mtransD(rows.imag, 1, &phiIT, 1, kL, nL)

        let decay = pow(parameters.forgettingFactor, Double(n))
        // R ← λᴺR + ΦᴴΦ
        pr = vDSP.add(vDSP.multiply(decay, pr), vDSP.add(mm(phiRT, rows.real, k, k, n), mm(phiIT, rows.imag, k, k, n)))
        pi = vDSP.add(vDSP.multiply(decay, pi), vDSP.subtract(mm(phiRT, rows.imag, k, k, n), mm(phiIT, rows.real, k, k, n)))
        // b ← λᴺb + Φᴴd
        br = vDSP.add(vDSP.multiply(decay, br), vDSP.add(mm(phiRT, dr, k, 1, n), mm(phiIT, di, k, 1, n)))
        bi = vDSP.add(vDSP.multiply(decay, bi), vDSP.subtract(mm(phiRT, di, k, 1, n), mm(phiIT, dr, k, 1, n)))

        // Real-ified 2K×2K system with ridge δ on the diagonal.
        let m = 2 * k
        var a = [Double](repeating: 0, count: m * m)
        for row in 0..<k {
            for col in 0..<k {
                let rr = pr[row * k + col], ri = pi[row * k + col]
                a[row * m + col] = rr                 // top-left      Rᵣ
                a[row * m + k + col] = -ri            // top-right    −Rᵢ
                a[(k + row) * m + col] = ri           // bottom-left   Rᵢ
                a[(k + row) * m + k + col] = rr       // bottom-right  Rᵣ
            }
        }
        let rhs = br + bi

        // Retry with a stronger ridge if R is not yet positive definite (first blocks).
        for ridge in [parameters.delta, parameters.delta * 1e3, parameters.delta * 1e6] {
            var regularized = a
            for i in 0..<m { regularized[i * m + i] += max(ridge, 1e-12) }
            if let x = Self.choleskySolve(regularized, rhs, n: m) {
                hr = Array(x[0..<k])
                hi = Array(x[k..<m])
                samplesProcessed += n
                return errorPower
            }
        }
        diverged = true
        return errorPower
    }

    /// C (m×n) = A (m×p) · B (p×n), row-major, via BLAS-backed `vDSP_mmulD`.
    private static func matmul(_ a: [Double], _ b: [Double], _ m: Int, _ n: Int, _ p: Int) -> [Double] {
        var c = [Double](repeating: 0, count: m * n)
        vDSP_mmulD(a, 1, b, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(p))
        return c
    }

    /// Solves A·x = b for symmetric positive-definite A (row-major n×n) by Cholesky
    /// A = L·Lᵀ, with every inner product vectorized through `vDSP_dotprD`.
    /// Returns `nil` if A is not numerically positive definite.
    static func choleskySolve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var l = a
        var x = b
        var ok = true
        l.withUnsafeMutableBufferPointer { lBuf in
            x.withUnsafeMutableBufferPointer { xBuf in
                let p = lBuf.baseAddress!, y = xBuf.baseAddress!

                // Factorization: L[j][j] = √(A[j][j] − ‖L[j][:j]‖²),
                //                L[i][j] = (A[i][j] − L[i][:j]·L[j][:j]) / L[j][j]
                for j in 0..<n {
                    var s = 0.0
                    if j > 0 { vDSP_dotprD(p + j * n, 1, p + j * n, 1, &s, vDSP_Length(j)) }
                    let diagonal = p[j * n + j] - s
                    guard diagonal > 0, diagonal.isFinite else { ok = false; return }
                    let ljj = diagonal.squareRoot()
                    p[j * n + j] = ljj
                    for i in (j + 1)..<n {
                        var t = 0.0
                        if j > 0 { vDSP_dotprD(p + i * n, 1, p + j * n, 1, &t, vDSP_Length(j)) }
                        p[i * n + j] = (p[i * n + j] - t) / ljj
                    }
                }
                // Forward substitution L·y = b (row prefix · solved prefix).
                for i in 0..<n {
                    var t = 0.0
                    if i > 0 { vDSP_dotprD(p + i * n, 1, y, 1, &t, vDSP_Length(i)) }
                    y[i] = (y[i] - t) / p[i * n + i]
                }
                // Back substitution Lᵀ·x = y (column of L below the diagonal, stride n).
                for i in stride(from: n - 1, through: 0, by: -1) {
                    var t = 0.0
                    let tail = n - 1 - i
                    if tail > 0 { vDSP_dotprD(p + (i + 1) * n + i, vDSP_Stride(n), y + i + 1, 1, &t, vDSP_Length(tail)) }
                    y[i] = (y[i] - t) / p[i * n + i]
                }
            }
        }
        return ok ? x : nil
    }
}
