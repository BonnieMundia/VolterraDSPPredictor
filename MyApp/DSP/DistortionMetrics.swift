import Accelerate
import Foundation

/// Figures of merit comparing a PA output y against its clean input x.
nonisolated struct DistortionMetrics: Sendable, Equatable {
    /// Least-squares complex linear gain ĝ = ⟨y, x⟩ / ⟨x, x⟩.
    let linearGain: DSPComplex
    /// Normalized mean-square error of y − ĝx relative to ĝx (dB).
    let nmseDB: Float
    /// Waveform EVM (%), √NMSE.
    let evmPercent: Float
    let inputPAPRdB: Float
    let outputPAPRdB: Float
    /// Average output power relative to linear prediction (dB). Negative = compression.
    let averageCompressionDB: Float

    var linearGainMagnitude: Float {
        (linearGain.real * linearGain.real + linearGain.imag * linearGain.imag).squareRoot()
    }

    static func == (lhs: DistortionMetrics, rhs: DistortionMetrics) -> Bool {
        lhs.linearGain.real == rhs.linearGain.real && lhs.linearGain.imag == rhs.linearGain.imag &&
        lhs.nmseDB == rhs.nmseDB && lhs.evmPercent == rhs.evmPercent &&
        lhs.inputPAPRdB == rhs.inputPAPRdB && lhs.outputPAPRdB == rhs.outputPAPRdB &&
        lhs.averageCompressionDB == rhs.averageCompressionDB
    }

    static func measure(input x: ComplexSignalBlock, output y: ComplexSignalBlock) -> DistortionMetrics {
        precondition(x.count == y.count, "Block length mismatch")
        let gain = linearGain(input: x, output: y)
        let linear = x.multiplied(by: gain)
        let error = y.subtracting(linear)

        let errorPower = error.meanPower
        let referencePower = max(linear.meanPower, .leastNormalMagnitude)
        let nmse = errorPower / referencePower

        return DistortionMetrics(
            linearGain: gain,
            nmseDB: 10 * log10(max(nmse, 1e-30)),
            evmPercent: nmse.squareRoot() * 100,
            inputPAPRdB: x.paprDB,
            outputPAPRdB: y.paprDB,
            averageCompressionDB: 10 * log10(max(y.meanPower, 1e-30) / referencePower)
        )
    }

    /// ĝ = Σ y·x* / Σ |x|²
    static func linearGain(input x: ComplexSignalBlock, output y: ComplexSignalBlock) -> DSPComplex {
        let energy = vDSP.sumOfSquares(x.real) + vDSP.sumOfSquares(x.imag)
        guard energy > 0 else { return DSPComplex(real: 1, imag: 0) }
        // Re{y·x*} = yr·xr + yi·xi,   Im{y·x*} = yi·xr − yr·xi
        let re = vDSP.dot(y.real, x.real) + vDSP.dot(y.imag, x.imag)
        let im = vDSP.dot(y.imag, x.real) - vDSP.dot(y.real, x.imag)
        return DSPComplex(real: re / energy, imag: im / energy)
    }

    /// Per-sample phase of y relative to x, ∠(x*·y), in degrees.
    static func relativePhaseDegrees(input x: ComplexSignalBlock, output y: ComplexSignalBlock) -> [Float] {
        precondition(x.count == y.count, "Block length mismatch")
        guard !x.isEmpty else { return [] }
        var product = ComplexSignalBlock(count: x.count, sampleRate: x.sampleRate)
        var phase = [Float](repeating: 0, count: x.count)
        x.withUnsafeSplitComplex { xs in
            y.withUnsafeSplitComplex { ys in
                product.withUnsafeMutableSplitComplex { ps in
                    var a = xs
                    var b = ys
                    // vDSP_zvcmul computes C = conj(A) · B
                    vDSP_zvcmul(&a, 1, &b, 1, &ps, 1, vDSP_Length(x.count))
                    vDSP_zvphas(&ps, 1, &phase, 1, vDSP_Length(x.count))
                }
            }
        }
        return vDSP.multiply(180 / Float.pi, phase)
    }
}
