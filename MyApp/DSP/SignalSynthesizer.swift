import Accelerate
import Foundation

// MARK: - Deterministic RNG

/// xoshiro256** PRNG. Seeded so every simulation run is bit-reproducible,
/// which matters when comparing identification runs across phases.
nonisolated struct Xoshiro256StarStar: RandomNumberGenerator, Sendable {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        // Expand the seed with SplitMix64 so that nearby seeds give uncorrelated streams.
        var x = seed
        func splitMix() -> UInt64 {
            x &+= 0x9E37_79B9_7F4A_7C15
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        s = (splitMix(), splitMix(), splitMix(), splitMix())
    }

    mutating func next() -> UInt64 {
        let result = ((s.1 &* 5) << 7 | (s.1 &* 5) >> 57) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = (s.3 << 45) | (s.3 >> 19)
        return result
    }
}

// MARK: - Configuration

nonisolated enum SignalKind: String, CaseIterable, Identifiable, Sendable {
    case multiTone = "Multi-Tone"
    case qam16 = "16-QAM"
    case qam64 = "64-QAM"

    var id: String { rawValue }

    /// Constellation order for QAM kinds.
    var qamOrder: Int? {
        switch self {
        case .multiTone: nil
        case .qam16: 16
        case .qam64: 64
        }
    }
}

nonisolated struct SignalConfiguration: Sendable, Equatable {
    var kind: SignalKind = .qam16
    /// Complex baseband sample rate (Hz).
    var sampleRate: Double = 122.88e6
    /// Number of samples to synthesize.
    var sampleCount: Int = 16_384
    /// Multi-tone: frequency span covered by the tones (Hz).
    var toneSpan: Double = 20e6
    /// Multi-tone: number of tones.
    var toneCount: Int = 8
    /// QAM: oversampling factor. Symbol rate = sampleRate / samplesPerSymbol.
    var samplesPerSymbol: Int = 6
    /// QAM: root-raised-cosine roll-off factor β.
    var rolloff: Double = 0.22
    /// QAM: RRC filter span in symbols. Truncation sets the spectral floor of the
    /// clean stimulus: 12 → −44 dBc ACLR, 24 → −52 dBc, 32 → −56 dBc.
    var filterSpanSymbols: Int = 32
    /// RMS envelope amplitude delivered to the PA (sets input back-off).
    var rmsAmplitude: Float = 0.35
    var seed: UInt64 = 0x5EED_C0FFEE

    /// Occupied bandwidth of the generated signal (Hz).
    var occupiedBandwidth: Double {
        switch kind {
        case .multiTone: toneSpan
        case .qam16, .qam64: sampleRate / Double(samplesPerSymbol) * (1 + rolloff)
        }
    }
}

// MARK: - Synthesizer

/// Generates wideband complex-baseband stimulus entirely in memory.
nonisolated enum SignalSynthesizer {

    static func generate(_ config: SignalConfiguration) -> ComplexSignalBlock {
        var block: ComplexSignalBlock
        switch config.kind {
        case .multiTone:
            block = multiTone(config)
        case .qam16, .qam64:
            block = qam(config, order: config.kind.qamOrder ?? 16)
        }
        block.normalize(toRMS: config.rmsAmplitude)
        return block
    }

    // MARK: Multi-tone

    /// Equal-amplitude multi-tone with Schroeder phases (φₖ = πk²/K), which
    /// keeps the crest factor low compared to coherent phases.
    ///
    /// Tone frequencies are snapped to the FFT grid of `sampleCount` so the
    /// spectrum shows no leakage — distortion products then appear cleanly.
    static func multiTone(_ config: SignalConfiguration) -> ComplexSignalBlock {
        let n = config.sampleCount
        let k = max(config.toneCount, 1)
        let fs = config.sampleRate
        let binWidth = fs / Double(n)

        // Sample index ramp in Double: phase accumulation stays exact for long blocks.
        let index = vDSP.ramp(withInitialValue: 0.0, increment: 1.0, count: n)
        var accReal = [Double](repeating: 0, count: n)
        var accImag = [Double](repeating: 0, count: n)

        for tone in 0..<k {
            let rawFreq = k == 1
                ? 0
                : -config.toneSpan / 2 + Double(tone) * config.toneSpan / Double(k - 1)
            let bin = (rawFreq / binWidth).rounded()
            let normalizedFreq = bin / Double(n)                    // cycles / sample
            let phaseCycles = Double(tone * tone) / Double(2 * k)   // Schroeder: πk²/K rad = k²/2K cycles

            // θ(n) = 2π · frac(f·n + φ)   — wrapping before the trig keeps Float precision tight.
            var cycles = vDSP.add(phaseCycles, vDSP.multiply(normalizedFreq, index))
            cycles = vDSP.subtract(cycles, vForce.trunc(cycles))
            let theta = vDSP.multiply(2 * Double.pi, cycles)

            accReal = vDSP.add(accReal, vForce.cos(theta))
            accImag = vDSP.add(accImag, vForce.sin(theta))
        }

        return ComplexSignalBlock(
            real: vDSP.doubleToFloat(accReal),
            imag: vDSP.doubleToFloat(accImag),
            sampleRate: fs
        )
    }

    // MARK: QAM

    /// Square M-QAM symbols, zero-stuffed and shaped with a root-raised-cosine filter.
    static func qam(_ config: SignalConfiguration, order: Int) -> ComplexSignalBlock {
        let n = config.sampleCount
        let sps = max(config.samplesPerSymbol, 2)
        let span = max(config.filterSpanSymbols, 2)
        let levels = Int(Double(order).squareRoot())
        precondition(levels * levels == order, "QAM order must be a perfect square")

        let taps = rootRaisedCosine(rolloff: config.rolloff, samplesPerSymbol: sps, spanSymbols: span)
        let groupDelay = (taps.count - 1) / 2

        // Enough symbols to cover the output window plus the filter transient.
        let symbolCount = (n + taps.count) / sps + 1
        let upsampledCount = symbolCount * sps

        var rng = Xoshiro256StarStar(seed: config.seed)
        var upReal = [Float](repeating: 0, count: upsampledCount)
        var upImag = [Float](repeating: 0, count: upsampledCount)
        for s in 0..<symbolCount {
            // PAM levels: −(L−1), …, −1, +1, …, +(L−1)
            let i = Int.random(in: 0..<levels, using: &rng)
            let q = Int.random(in: 0..<levels, using: &rng)
            upReal[s * sps] = Float(2 * i - (levels - 1))
            upImag[s * sps] = Float(2 * q - (levels - 1))
        }

        let shapedReal = FIRFilter.filter(upReal, taps: taps)
        let shapedImag = FIRFilter.filter(upImag, taps: taps)

        // Skip the start-up transient so the window is in steady state.
        let start = groupDelay * 2
        let end = start + n
        precondition(end <= shapedReal.count, "Insufficient symbols for requested window")
        return ComplexSignalBlock(
            real: Array(shapedReal[start..<end]),
            imag: Array(shapedImag[start..<end]),
            sampleRate: config.sampleRate
        )
    }

    /// Unit-energy root-raised-cosine impulse response, length `span·sps + 1`.
    static func rootRaisedCosine(rolloff beta: Double, samplesPerSymbol sps: Int, spanSymbols span: Int) -> [Float] {
        let length = span * sps + 1
        let mid = Double(length - 1) / 2
        var taps = [Double](repeating: 0, count: length)

        for k in 0..<length {
            let t = (Double(k) - mid) / Double(sps)   // time in symbol periods
            let value: Double
            if t == 0 {
                value = 1 - beta + 4 * beta / .pi
            } else if beta > 0, abs(abs(t) - 1 / (4 * beta)) < 1e-9 {
                // Removable singularity at t = ±1/(4β).
                value = beta / 2.0.squareRoot() * (
                    (1 + 2 / .pi) * sin(.pi / (4 * beta)) +
                    (1 - 2 / .pi) * cos(.pi / (4 * beta))
                )
            } else {
                let numerator = sin(.pi * t * (1 - beta)) + 4 * beta * t * cos(.pi * t * (1 + beta))
                let denominator = .pi * t * (1 - pow(4 * beta * t, 2))
                value = numerator / denominator
            }
            taps[k] = value
        }

        // Normalize to unit energy so symbol power is preserved through shaping.
        let energy = vDSP.sumOfSquares(taps)
        let normalized = vDSP.multiply(1 / energy.squareRoot(), taps)
        return vDSP.doubleToFloat(normalized)
    }
}
