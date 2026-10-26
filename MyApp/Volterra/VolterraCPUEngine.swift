import Accelerate
import Foundation

/// CPU evaluators for the truncated complex Volterra series.
///
/// Every evaluator takes an *extended* block: the previous M−1 input samples
/// followed by the N new samples, so that
///
///     x(n − τ) = extended[n + (M − 1) − τ],   n ∈ 0 ..< N.
///
/// A delay τ is therefore just a pointer offset of (M − 1 − τ) into the
/// extended buffer — no shifted copies of the input are ever materialized.
nonisolated enum VolterraCPUEngine {

    // MARK: - Scalar reference (direct multidimensional convolution)

    /// Literal evaluation of the multidimensional kernel sums, one output
    /// sample at a time. Ground truth for every optimized backend.
    static func evaluateScalar(extended e: ComplexSignalBlock, kernels k: VolterraKernels) -> ComplexSignalBlock {
        let layout = k.layout
        let m = layout.memoryDepth
        let n = e.count - (m - 1)
        guard n > 0 else { return ComplexSignalBlock(count: 0, sampleRate: e.sampleRate) }

        var yr = [Float](repeating: 0, count: n)
        var yi = [Float](repeating: 0, count: n)

        e.real.withUnsafeBufferPointer { xr in
            e.imag.withUnsafeBufferPointer { xi in
                k.real.withUnsafeBufferPointer { hr in
                    k.imag.withUnsafeBufferPointer { hi in
                        for i in 0..<n {
                            let base = i + m - 1
                            var accR: Float = 0
                            var accI: Float = 0

                            if layout.includeConstant {
                                accR += hr[0]
                                accI += hi[0]
                            }

                            // Σ h₁(τ)·x(n−τ)
                            for t in 0..<m {
                                let h = layout.linearOffset + t
                                let ar = xr[base - t], ai = xi[base - t]
                                accR += hr[h] * ar - hi[h] * ai
                                accI += hr[h] * ai + hi[h] * ar
                            }

                            // Σ_{τ₁≤τ₂} Σ_{τ₃} h₃·x(n−τ₁)·x(n−τ₂)·x*(n−τ₃)
                            if layout.order == .third {
                                var h = layout.cubicOffset
                                for a in 0..<m {
                                    let ar = xr[base - a], ai = xi[base - a]
                                    for b in a..<m {
                                        let br = xr[base - b], bi = xi[base - b]
                                        let pr = ar * br - ai * bi
                                        let pi = ar * bi + ai * br
                                        for c in 0..<m {
                                            // conj(x_c) = (cr, −ci)
                                            let cr = xr[base - c], ci = -xi[base - c]
                                            let qr = pr * cr - pi * ci
                                            let qi = pr * ci + pi * cr
                                            accR += hr[h] * qr - hi[h] * qi
                                            accI += hr[h] * qi + hi[h] * qr
                                            h += 1
                                        }
                                    }
                                }
                            }

                            yr[i] = accR
                            yi[i] = accI
                        }
                    }
                }
            }
        }
        return ComplexSignalBlock(real: yr, imag: yi, sampleRate: e.sampleRate)
    }

    // MARK: - vDSP factored convolution

    /// Factorizes the cubic sum per (τ₁, τ₂) pair:
    ///
    ///     y₃(n) = Σ_{τ₁≤τ₂} x(n−τ₁)·x(n−τ₂) · g_{τ₁τ₂}(n),
    ///     g_{τ₁τ₂}(n) = Σ_{τ₃} h₃(τ₁,τ₂;τ₃)·x*(n−τ₃)
    ///
    /// Each g is a 1-D complex FIR of the conjugated input (`vDSP_zconv`), the
    /// pair product is one `vDSP_zvmul`, and accumulation is one `vDSP_zvma`.
    /// Work is O(N·M²(M+1)/2) with every inner loop running on NEON vectors.
    static func evaluateFactored(extended e: ComplexSignalBlock, kernels k: VolterraKernels) -> ComplexSignalBlock {
        let layout = k.layout
        let m = layout.memoryDepth
        let n = e.count - (m - 1)
        guard n > 0 else { return ComplexSignalBlock(count: 0, sampleRate: e.sampleRate) }
        let length = vDSP_Length(n)

        // vDSP_zconv computes correlation C[i] = Σ_p A[i+p]·F[p]. With A = extended,
        // A[i+p] = x(i − (M−1−p)), so F[p] = h(M−1−p): kernels are time-reversed once here.
        let reversed = reversedTaps(k)
        let conjImag = vDSP.negative(e.imag)

        var y = ComplexSignalBlock(count: n, sampleRate: e.sampleRate)
        let pairBuffer = SplitBuffer(count: n)
        let filterBuffer = SplitBuffer(count: n)
        defer {
            pairBuffer.deallocate()
            filterBuffer.deallocate()
        }

        e.real.withUnsafeBufferPointer { er in
            e.imag.withUnsafeBufferPointer { ei in
                conjImag.withUnsafeBufferPointer { ci in
                    reversed.real.withUnsafeBufferPointer { rr in
                        reversed.imag.withUnsafeBufferPointer { ri in
                            y.withUnsafeMutableSplitComplex { ys in
                                let xr = UnsafeMutablePointer(mutating: er.baseAddress!)
                                let xi = UnsafeMutablePointer(mutating: ei.baseAddress!)
                                let xci = UnsafeMutablePointer(mutating: ci.baseAddress!)
                                let hr = UnsafeMutablePointer(mutating: rr.baseAddress!)
                                let hi = UnsafeMutablePointer(mutating: ri.baseAddress!)

                                /// Split view of x(n − τ).
                                func delayed(_ tau: Int) -> DSPSplitComplex {
                                    DSPSplitComplex(realp: xr + (m - 1 - tau), imagp: xi + (m - 1 - tau))
                                }

                                // Linear part: y = h₁ ∗ x
                                var x0 = DSPSplitComplex(realp: xr, imagp: xi)
                                var h1 = DSPSplitComplex(realp: hr + layout.linearOffset, imagp: hi + layout.linearOffset)
                                vDSP_zconv(&x0, 1, &h1, 1, &ys, 1, length, vDSP_Length(m))

                                if layout.includeConstant {
                                    var h0r = k.real[0], h0i = k.imag[0]
                                    vDSP_vsadd(ys.realp, 1, &h0r, ys.realp, 1, length)
                                    vDSP_vsadd(ys.imagp, 1, &h0i, ys.imagp, 1, length)
                                }

                                guard layout.order == .third else { return }

                                var xConj = DSPSplitComplex(realp: xr, imagp: xci)
                                var pair = pairBuffer.split
                                var g = filterBuffer.split

                                for (p, (a, b)) in layout.pairs.enumerated() {
                                    var xa = delayed(a)
                                    var xb = delayed(b)
                                    vDSP_zvmul(&xa, 1, &xb, 1, &pair, 1, length, 1)

                                    let tapOffset = layout.cubicOffset + p * m
                                    var h3 = DSPSplitComplex(realp: hr + tapOffset, imagp: hi + tapOffset)
                                    vDSP_zconv(&xConj, 1, &h3, 1, &g, 1, length, vDSP_Length(m))

                                    // y += pair ⊙ g
                                    vDSP_zvma(&pair, 1, &g, 1, &ys, 1, &ys, 1, length)
                                }
                            }
                        }
                    }
                }
            }
        }
        return y
    }

    // MARK: - Regression matrix + matrix multiply

    /// Builds the Volterra regression matrix Φ (N × K) so that y = Φ·h.
    ///
    /// Stored column-major in split layout: column k occupies
    /// `[k·N, (k+1)·N)` of both the real and imaginary arrays, so each column
    /// is filled by one contiguous vector op. Phase 3 reuses Φ directly for
    /// LMS/RLS identification (gradient Φᴴe, normal equations ΦᴴΦ).
    static func regressionMatrix(extended e: ComplexSignalBlock, layout: VolterraKernelLayout) -> (real: [Float], imag: [Float], rows: Int) {
        let m = layout.memoryDepth
        let n = e.count - (m - 1)
        let kTerms = layout.termCount
        guard n > 0 else { return ([], [], 0) }
        let length = vDSP_Length(n)

        var phiR = [Float](repeating: 0, count: n * kTerms)
        var phiI = [Float](repeating: 0, count: n * kTerms)
        let pairBuffer = SplitBuffer(count: n)
        defer { pairBuffer.deallocate() }

        e.real.withUnsafeBufferPointer { er in
            e.imag.withUnsafeBufferPointer { ei in
                phiR.withUnsafeMutableBufferPointer { pr in
                    phiI.withUnsafeMutableBufferPointer { pi in
                        let xr = UnsafeMutablePointer(mutating: er.baseAddress!)
                        let xi = UnsafeMutablePointer(mutating: ei.baseAddress!)
                        let colR = pr.baseAddress!
                        let colI = pi.baseAddress!

                        func delayed(_ tau: Int) -> DSPSplitComplex {
                            DSPSplitComplex(realp: xr + (m - 1 - tau), imagp: xi + (m - 1 - tau))
                        }
                        func column(_ index: Int) -> DSPSplitComplex {
                            DSPSplitComplex(realp: colR + index * n, imagp: colI + index * n)
                        }

                        if layout.includeConstant {
                            var one: Float = 1
                            vDSP_vfill(&one, colR, 1, length)   // imaginary column already zero
                        }

                        for t in 0..<m {
                            let dst = column(layout.linearOffset + t)
                            let src = delayed(t)
                            dst.realp.update(from: src.realp, count: n)
                            dst.imagp.update(from: src.imagp, count: n)
                        }

                        guard layout.order == .third else { return }
                        var pair = pairBuffer.split
                        for (p, (a, b)) in layout.pairs.enumerated() {
                            var xa = delayed(a)
                            var xb = delayed(b)
                            vDSP_zvmul(&xa, 1, &xb, 1, &pair, 1, length, 1)
                            for c in 0..<m {
                                var xc = delayed(c)
                                var dst = column(layout.cubicOffset + p * m + c)
                                // Conjugate = −1 → dst = conj(x_c) · pair
                                vDSP_zvmul(&xc, 1, &pair, 1, &dst, 1, length, -1)
                            }
                        }
                    }
                }
            }
        }
        return (phiR, phiI, n)
    }

    /// y = Φ·h via two real matrix multiplies on Accelerate's BLAS-backed `vDSP_mmul`.
    ///
    /// Φ is column-major N×K, i.e. row-major Φᵀ (K×N). With H = [h_r; h_i] (2×K):
    ///
    ///     C_r = H·Φ_rᵀ = [ (Φ_r h_r)ᵀ ; (Φ_r h_i)ᵀ ]
    ///     C_i = H·Φ_iᵀ = [ (Φ_i h_r)ᵀ ; (Φ_i h_i)ᵀ ]
    ///     y_r = Φ_r h_r − Φ_i h_i,   y_i = Φ_r h_i + Φ_i h_r
    static func evaluateRegression(extended e: ComplexSignalBlock, kernels k: VolterraKernels) -> ComplexSignalBlock {
        let phi = regressionMatrix(extended: e, layout: k.layout)
        return multiply(phiReal: phi.real, phiImag: phi.imag, rows: phi.rows, kernels: k, sampleRate: e.sampleRate)
    }

    static func multiply(phiReal: [Float], phiImag: [Float], rows n: Int, kernels k: VolterraKernels, sampleRate: Double) -> ComplexSignalBlock {
        let kTerms = k.layout.termCount
        guard n > 0 else { return ComplexSignalBlock(count: 0, sampleRate: sampleRate) }

        let h = k.real + k.imag                     // 2×K row-major
        var cr = [Float](repeating: 0, count: 2 * n)
        var ci = [Float](repeating: 0, count: 2 * n)
        vDSP_mmul(h, 1, phiReal, 1, &cr, 1, 2, vDSP_Length(n), vDSP_Length(kTerms))
        vDSP_mmul(h, 1, phiImag, 1, &ci, 1, 2, vDSP_Length(n), vDSP_Length(kTerms))

        let yr = vDSP.subtract(cr[0..<n], ci[n..<(2 * n)])
        let yi = vDSP.add(cr[n..<(2 * n)], ci[0..<n])
        return ComplexSignalBlock(real: yr, imag: yi, sampleRate: sampleRate)
    }

    // MARK: - Helpers

    /// Kernel vector with every M-tap run (h₁ and each h₃ pair) time-reversed,
    /// so `vDSP_zconv`'s correlation becomes convolution.
    static func reversedTaps(_ k: VolterraKernels) -> (real: [Float], imag: [Float]) {
        var r = k.real
        var i = k.imag
        let m = k.layout.memoryDepth
        var runStarts = [k.layout.linearOffset]
        runStarts += (0..<k.layout.cubicPairCount).map { k.layout.cubicOffset + $0 * m }
        for start in runStarts {
            r[start..<(start + m)].reverse()
            i[start..<(start + m)].reverse()
        }
        return (r, i)
    }
}

/// Uninitialized split-complex scratch buffer with manual lifetime, avoiding
/// zero-fill and nested closures in hot loops.
nonisolated struct SplitBuffer {
    let real: UnsafeMutablePointer<Float>
    let imag: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        real = .allocate(capacity: max(count, 1))
        imag = .allocate(capacity: max(count, 1))
    }

    var split: DSPSplitComplex { DSPSplitComplex(realp: real, imagp: imag) }

    func deallocate() {
        real.deallocate()
        imag.deallocate()
    }
}
