import Accelerate
import Foundation

/// Adjacent-channel leakage measured on a two-sided PSD.
nonisolated struct ACLRMeasurement: Sendable, Equatable {
    /// Integrated main-channel power (linear).
    let mainPower: Double
    /// Lower / upper adjacent-channel power relative to the main channel (dBc).
    let lowerDBc: Double
    let upperDBc: Double

    /// Worst (highest) of the two adjacent channels.
    var worstDBc: Double { max(lowerDBc, upperDBc) }

    static let unavailable = ACLRMeasurement(mainPower: 0, lowerDBc: .nan, upperDBc: .nan)
}

/// Channel plan for ACLR: main channel centred at DC, adjacent channels at ±spacing.
nonisolated struct ChannelPlan: Sendable, Equatable {
    let bandwidth: Double
    let spacing: Double

    static func forSignal(_ s: SignalConfiguration) -> ChannelPlan {
        switch s.kind {
        case .multiTone:
            // Tone span plus one bin either side so edge tones are inside the channel.
            let bw = s.toneSpan + 2 * s.sampleRate / 1_024
            return ChannelPlan(bandwidth: bw, spacing: bw)
        case .qam16, .qam64:
            let bw = s.occupiedBandwidth
            return ChannelPlan(bandwidth: bw, spacing: bw)
        }
    }
}

/// Welch power-spectral-density estimator for complex baseband, built on `vDSP_fft_zrip`.
///
/// `vDSP_fft_zrip` is a *real* FFT. A complex block x = xᵢ + j·x_q is transformed
/// with two real FFTs, A = FFT(xᵢ) and B = FFT(x_q), and the full two-sided
/// spectrum is reassembled from their Hermitian symmetry:
///
///     X[k]     = A[k] + j·B[k]
///     X[N − k] = A*[k] + j·B*[k]        k = 1 … N/2 − 1
///
/// so positive and negative frequencies (upper/lower sidebands) stay distinct.
/// Segments are Hann-windowed with 50 % overlap; the result is a density
/// (power / Hz) such that Σ PSD·Δf equals the mean signal power.
nonisolated final class WelchSpectrumAnalyzer: @unchecked Sendable {
    let fftLength: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let windowEnergy: Float

    init(fftLength: Int = 1_024) {
        precondition(fftLength >= 8 && fftLength & (fftLength - 1) == 0, "FFT length must be a power of two")
        self.fftLength = fftLength
        log2n = vDSP_Length(log2(Double(fftLength)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for N = \(fftLength)")
        }
        self.setup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftLength, isHalfWindow: false)
        windowEnergy = vDSP.sumOfSquares(window)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Bin centre frequencies in Hz, ordered −fs/2 … +fs/2 (matches `psd` output).
    func frequencies(sampleRate fs: Double) -> [Double] {
        let n = fftLength
        return (0..<n).map { Double($0 - n / 2) * fs / Double(n) }
    }

    /// Two-sided PSD (linear, power/Hz), fft-shifted so index 0 is −fs/2.
    func psd(_ x: ComplexSignalBlock) -> [Float] {
        let n = fftLength
        let half = n / 2
        guard x.count >= n else { return [Float](repeating: 0, count: n) }

        let hop = n / 2
        let segments = (x.count - n) / hop + 1
        var accumulator = [Float](repeating: 0, count: n)

        // Scratch: packed half-length split buffers for the I and Q real FFTs.
        let aBuf = SplitBuffer(count: half)
        let bBuf = SplitBuffer(count: half)
        defer { aBuf.deallocate(); bBuf.deallocate() }
        var segmentI = [Float](repeating: 0, count: n)
        var segmentQ = [Float](repeating: 0, count: n)
        var positive = [Float](repeating: 0, count: half - 1)
        var negative = [Float](repeating: 0, count: half - 1)

        for s in 0..<segments {
            let start = s * hop
            x.real.withUnsafeBufferPointer { r in
                vDSP_vmul(r.baseAddress! + start, 1, window, 1, &segmentI, 1, vDSP_Length(n))
            }
            x.imag.withUnsafeBufferPointer { i in
                vDSP_vmul(i.baseAddress! + start, 1, window, 1, &segmentQ, 1, vDSP_Length(n))
            }
            realFFT(segmentI, into: aBuf)
            realFFT(segmentQ, into: bBuf)

            // zrip output is 2 × DFT; DC in realp[0], Nyquist in imagp[0].
            let ar = UnsafeBufferPointer(start: aBuf.real, count: half)
            let ai = UnsafeBufferPointer(start: aBuf.imag, count: half)
            let br = UnsafeBufferPointer(start: bBuf.real, count: half)
            let bi = UnsafeBufferPointer(start: bBuf.imag, count: half)

            // DC and Nyquist: X = A + jB with A, B real.
            accumulator[0] += ar[0] * ar[0] + br[0] * br[0]
            accumulator[half] += ai[0] * ai[0] + bi[0] * bi[0]

            // k = 1 … N/2−1, vectorized over the slices.
            let arS = Array(ar[1...]), aiS = Array(ai[1...]), brS = Array(br[1...]), biS = Array(bi[1...])
            // X[k]   = (ar − bi) + j(ai + br)
            let p1 = vDSP.subtract(arS, biS), p2 = vDSP.add(aiS, brS)
            vDSP.add(vDSP.square(p1), vDSP.square(p2), result: &positive)
            // X[N−k] = (ar + bi) + j(br − ai)
            let n1 = vDSP.add(arS, biS), n2 = vDSP.subtract(brS, aiS)
            vDSP.add(vDSP.square(n1), vDSP.square(n2), result: &negative)

            accumulator.withUnsafeMutableBufferPointer { acc in
                let base = acc.baseAddress!
                vDSP_vadd(base + 1, 1, positive, 1, base + 1, 1, vDSP_Length(half - 1))
                // X[N−k] for k = 1 … N/2−1 occupies indices N−1 … N/2+1: write reversed.
                vDSP_vadd(base + (n - 1), -1, negative, 1, base + (n - 1), -1, vDSP_Length(half - 1))
            }
        }

        // Undo zrip's ×2 (power ×4), average segments, normalize to density.
        let scale = 1 / (4 * Float(segments) * Float(x.sampleRate) * windowEnergy)
        let density = vDSP.multiply(scale, accumulator)

        // fftshift: [N/2 … N−1, 0 … N/2−1]
        return Array(density[half...] + density[..<half])
    }

    /// Packs a length-N real sequence as N/2 complex and runs the in-place real FFT.
    private func realFFT(_ input: [Float], into buffer: SplitBuffer) {
        var split = buffer.split
        input.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftLength / 2) { complex in
                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftLength / 2))
            }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    // MARK: - Band power & ACLR

    /// Integrated power of `psd` over [low, high] Hz (bins whose centres fall inside).
    func bandPower(_ psd: [Float], sampleRate fs: Double, from low: Double, to high: Double) -> Double {
        let df = fs / Double(fftLength)
        let first = max(0, Int(((low / df) + Double(fftLength / 2)).rounded(.up)))
        let last = min(fftLength - 1, Int(((high / df) + Double(fftLength / 2)).rounded(.down)))
        guard first <= last else { return 0 }
        return Double(vDSP.sum(psd[first...last])) * df
    }

    func aclr(_ psd: [Float], sampleRate fs: Double, plan: ChannelPlan) -> ACLRMeasurement {
        let halfBW = plan.bandwidth / 2
        let nyquist = fs / 2
        let main = bandPower(psd, sampleRate: fs, from: -halfBW, to: halfBW)
        guard main > 0 else { return .unavailable }
        // Adjacent channels are clipped at ±fs/2 when they extend past Nyquist.
        let lower = bandPower(psd, sampleRate: fs, from: max(-plan.spacing - halfBW, -nyquist), to: -plan.spacing + halfBW)
        let upper = bandPower(psd, sampleRate: fs, from: plan.spacing - halfBW, to: min(plan.spacing + halfBW, nyquist))
        return ACLRMeasurement(
            mainPower: main,
            lowerDBc: 10 * log10(max(lower / main, 1e-30)),
            upperDBc: 10 * log10(max(upper / main, 1e-30))
        )
    }
}
