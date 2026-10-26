import Accelerate
import Foundation

/// A block of complex baseband (I/Q) samples stored in split-complex
/// (structure-of-arrays) layout.
///
/// Split layout is the native format for `vDSP_z*` routines and keeps each
/// channel contiguous, so vector loads on Apple Silicon NEON / AMX units stream
/// straight from unified memory without de-interleaving.
nonisolated struct ComplexSignalBlock: Sendable, Equatable {
    /// In-phase component.
    var real: [Float]
    /// Quadrature component.
    var imag: [Float]
    /// Sample rate in Hz.
    let sampleRate: Double

    var count: Int { real.count }
    var isEmpty: Bool { real.isEmpty }

    init(real: [Float], imag: [Float], sampleRate: Double) {
        precondition(real.count == imag.count, "I and Q channels must be the same length")
        self.real = real
        self.imag = imag
        self.sampleRate = sampleRate
    }

    /// Zero-filled block.
    init(count: Int, sampleRate: Double) {
        self.real = [Float](repeating: 0, count: count)
        self.imag = [Float](repeating: 0, count: count)
        self.sampleRate = sampleRate
    }

    // MARK: - Unsafe split-complex access

    /// Read-only split-complex view. vDSP takes `DSPSplitComplex` with mutable
    /// pointers even for inputs, so the pointers are cast but must not be written.
    /// The block must be non-empty.
    func withUnsafeSplitComplex<R>(_ body: (DSPSplitComplex) throws -> R) rethrows -> R {
        precondition(!isEmpty, "Split-complex access requires a non-empty block")
        return try real.withUnsafeBufferPointer { r in
            try imag.withUnsafeBufferPointer { i in
                let split = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: r.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: i.baseAddress!)
                )
                return try body(split)
            }
        }
    }

    /// Mutable split-complex view. The block must be non-empty.
    mutating func withUnsafeMutableSplitComplex<R>(_ body: (inout DSPSplitComplex) throws -> R) rethrows -> R {
        precondition(!isEmpty, "Split-complex access requires a non-empty block")
        return try real.withUnsafeMutableBufferPointer { r in
            try imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                return try body(&split)
            }
        }
    }

    // MARK: - Polar representation

    /// Instantaneous envelope |x(n)|.
    func magnitude() -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        withUnsafeSplitComplex { split in
            var s = split
            vDSP_zvabs(&s, 1, &out, 1, vDSP_Length(count))
        }
        return out
    }

    /// Instantaneous power |x(n)|².
    func power() -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        withUnsafeSplitComplex { split in
            var s = split
            vDSP_zvmags(&s, 1, &out, 1, vDSP_Length(count))
        }
        return out
    }

    /// Instantaneous phase ∠x(n) in radians, range (-π, π].
    func phase() -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        withUnsafeSplitComplex { split in
            var s = split
            vDSP_zvphas(&s, 1, &out, 1, vDSP_Length(count))
        }
        return out
    }

    // MARK: - Statistics

    /// Mean power E[|x|²].
    var meanPower: Float {
        guard count > 0 else { return 0 }
        return vDSP.mean(power())
    }

    /// Root-mean-square envelope amplitude.
    var rmsAmplitude: Float { meanPower.squareRoot() }

    /// Peak envelope amplitude.
    var peakAmplitude: Float {
        guard count > 0 else { return 0 }
        return vDSP.maximum(magnitude())
    }

    /// Peak-to-average power ratio in dB.
    var paprDB: Float {
        let avg = meanPower
        guard avg > 0 else { return 0 }
        let peak = vDSP.maximum(power())
        return 10 * log10(peak / avg)
    }

    // MARK: - Arithmetic

    /// Scales both channels by a real factor in place.
    mutating func scale(by factor: Float) {
        vDSP.multiply(factor, real, result: &real)
        vDSP.multiply(factor, imag, result: &imag)
    }

    /// Multiplies by a complex scalar (gᵣ + j·gᵢ).
    func multiplied(by gain: DSPComplex) -> ComplexSignalBlock {
        // (a + jb)(c + jd) = (ac − bd) + j(ad + bc)
        let ac = vDSP.multiply(gain.real, real)
        let bd = vDSP.multiply(gain.imag, imag)
        let ad = vDSP.multiply(gain.imag, real)
        let bc = vDSP.multiply(gain.real, imag)
        return ComplexSignalBlock(
            real: vDSP.subtract(ac, bd),
            imag: vDSP.add(ad, bc),
            sampleRate: sampleRate
        )
    }

    /// Normalizes so the RMS envelope equals `targetRMS`.
    mutating func normalize(toRMS targetRMS: Float) {
        let rms = rmsAmplitude
        guard rms > 0 else { return }
        scale(by: targetRMS / rms)
    }

    /// Element-wise difference `self − other`.
    func subtracting(_ other: ComplexSignalBlock) -> ComplexSignalBlock {
        precondition(count == other.count, "Block length mismatch")
        return ComplexSignalBlock(
            real: vDSP.subtract(real, other.real),
            imag: vDSP.subtract(imag, other.imag),
            sampleRate: sampleRate
        )
    }

    /// Sub-range copy.
    func slice(_ range: Range<Int>) -> ComplexSignalBlock {
        let clamped = range.clamped(to: 0..<count)
        return ComplexSignalBlock(
            real: Array(real[clamped]),
            imag: Array(imag[clamped]),
            sampleRate: sampleRate
        )
    }

    /// Splits the stream into fixed-size processing blocks (last block may be shorter).
    func blocks(ofSize size: Int) -> [ComplexSignalBlock] {
        precondition(size > 0, "Block size must be positive")
        return stride(from: 0, to: count, by: size).map { slice($0..<min($0 + size, count)) }
    }

    /// Concatenates blocks produced by block-based processing back into one stream.
    static func concatenate(_ blocks: [ComplexSignalBlock]) -> ComplexSignalBlock {
        guard let first = blocks.first else { return ComplexSignalBlock(count: 0, sampleRate: 1) }
        let total = blocks.reduce(0) { $0 + $1.count }
        var r = [Float]()
        var i = [Float]()
        r.reserveCapacity(total)
        i.reserveCapacity(total)
        for block in blocks {
            r.append(contentsOf: block.real)
            i.append(contentsOf: block.imag)
        }
        return ComplexSignalBlock(real: r, imag: i, sampleRate: first.sampleRate)
    }
}
