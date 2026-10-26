import Accelerate
import Foundation

/// Stateful real-coefficient FIR filter applied independently to I and Q.
///
/// The filter keeps the last `taps.count − 1` input samples between calls, so a
/// long stream can be processed block-by-block with output identical to
/// filtering the whole stream at once. Convolution runs on `vDSP_conv`, using a
/// negative filter stride to turn vDSP's correlation into true convolution:
///
///     y(n) = Σₖ h(k) · x(n − k),   k = 0 … P−1
nonisolated struct FIRFilter: Sendable {
    let taps: [Float]
    private var historyReal: [Float]
    private var historyImag: [Float]

    init(taps: [Float]) {
        precondition(!taps.isEmpty, "FIR filter requires at least one tap")
        self.taps = taps
        self.historyReal = [Float](repeating: 0, count: taps.count - 1)
        self.historyImag = [Float](repeating: 0, count: taps.count - 1)
    }

    /// Clears the delay line.
    mutating func reset() {
        vDSP.fill(&historyReal, with: 0)
        vDSP.fill(&historyImag, with: 0)
    }

    /// Filters one block, carrying state into the next call.
    mutating func process(_ block: ComplexSignalBlock) -> ComplexSignalBlock {
        guard !block.isEmpty else { return block }
        let outReal = Self.convolve(block.real, history: &historyReal, taps: taps)
        let outImag = Self.convolve(block.imag, history: &historyImag, taps: taps)
        return ComplexSignalBlock(real: outReal, imag: outImag, sampleRate: block.sampleRate)
    }

    /// One-shot, zero-initial-state convolution returning `x.count` samples.
    static func filter(_ x: [Float], taps: [Float]) -> [Float] {
        var history = [Float](repeating: 0, count: taps.count - 1)
        return convolve(x, history: &history, taps: taps)
    }

    private static func convolve(_ x: [Float], history: inout [Float], taps: [Float]) -> [Float] {
        let n = x.count
        let p = taps.count

        // Single-tap fast path: pure gain.
        guard p > 1 else { return vDSP.multiply(taps[0], x) }

        // Extended input = [history (P−1) | block (N)].
        var extended = [Float]()
        extended.reserveCapacity(history.count + n)
        extended.append(contentsOf: history)
        extended.append(contentsOf: x)

        var output = [Float](repeating: 0, count: n)
        extended.withUnsafeBufferPointer { xPtr in
            taps.withUnsafeBufferPointer { hPtr in
                output.withUnsafeMutableBufferPointer { yPtr in
                    // Point at the last tap and walk backwards (stride −1) for convolution.
                    vDSP_conv(
                        xPtr.baseAddress!, 1,
                        hPtr.baseAddress! + (p - 1), -1,
                        yPtr.baseAddress!, 1,
                        vDSP_Length(n), vDSP_Length(p)
                    )
                }
            }
        }

        // Retain the most recent P−1 inputs for the next block.
        history = Array(extended[(extended.count - (p - 1))...])
        return output
    }
}
