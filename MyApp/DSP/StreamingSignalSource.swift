import Accelerate
import Foundation

/// Endless, phase-continuous stimulus for the real-time engine.
///
/// Unlike `SignalSynthesizer` (one finite block), this carries RNG, pulse-shaping
/// filter and oscillator state between frames, so consecutive frames splice
/// seamlessly and the spectrum never shows block-boundary splatter.
nonisolated struct StreamingSignalSource: Sendable {
    let configuration: SignalConfiguration
    private var rng: Xoshiro256StarStar
    private var shaper: FIRFilter?
    private var sampleIndex: Int = 0
    private let amplitudeScale: Float

    /// RRC taps, also used by receivers as the matched filter.
    let pulseTaps: [Float]
    /// Total transmit + matched-filter delay; symbols appear at matched-filter
    /// output index i where (i − symbolDelay) % sps == 0.
    var symbolDelay: Int { pulseTaps.count - 1 }

    init(configuration: SignalConfiguration) {
        self.configuration = configuration
        rng = Xoshiro256StarStar(seed: configuration.seed)

        switch configuration.kind {
        case .multiTone:
            pulseTaps = [1]
            shaper = nil
            // Each tone has amplitude 1 ⇒ mean power K.
            amplitudeScale = configuration.rmsAmplitude / Float(max(configuration.toneCount, 1)).squareRoot()
        case .qam16, .qam64:
            let sps = max(configuration.samplesPerSymbol, 2)
            let taps = SignalSynthesizer.rootRaisedCosine(
                rolloff: configuration.rolloff,
                samplesPerSymbol: sps,
                spanSymbols: max(configuration.filterSpanSymbols, 2)
            )
            pulseTaps = taps
            shaper = FIRFilter(taps: taps)
            // Square M-QAM on odd-integer grid: E|s|² = 2(M−1)/3. Zero-stuffing by sps
            // and a unit-energy RRC give mean sample power E|s|² / sps.
            let order = Double(configuration.kind.qamOrder ?? 16)
            let samplePower = 2 * (order - 1) / 3 / Double(sps)
            amplitudeScale = configuration.rmsAmplitude / Float(samplePower.squareRoot())
        }
    }

    mutating func next(_ count: Int) -> ComplexSignalBlock {
        defer { sampleIndex += count }
        switch configuration.kind {
        case .multiTone: return nextMultiTone(count)
        case .qam16, .qam64: return nextQAM(count)
        }
    }

    private mutating func nextQAM(_ count: Int) -> ComplexSignalBlock {
        let sps = max(configuration.samplesPerSymbol, 2)
        let levels = Int(Double(configuration.kind.qamOrder ?? 16).squareRoot())
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        // Global symbol grid: a symbol is inserted wherever the absolute index is a multiple of sps.
        var n = (sps - sampleIndex % sps) % sps
        while n < count {
            re[n] = Float(2 * Int.random(in: 0..<levels, using: &rng) - (levels - 1))
            im[n] = Float(2 * Int.random(in: 0..<levels, using: &rng) - (levels - 1))
            n += sps
        }
        let impulses = ComplexSignalBlock(real: re, imag: im, sampleRate: configuration.sampleRate)
        guard var filter = shaper else { return impulses }
        var shaped = filter.process(impulses)
        shaper = filter
        shaped.scale(by: amplitudeScale)
        return shaped
    }

    private func nextMultiTone(_ count: Int) -> ComplexSignalBlock {
        let k = max(configuration.toneCount, 1)
        let fs = configuration.sampleRate
        // Tones on the 1024-point analysis grid ⇒ exactly periodic, leakage-free PSD.
        let binWidth = fs / 1_024
        let index = vDSP.ramp(withInitialValue: Double(sampleIndex), increment: 1.0, count: count)
        var accR = [Double](repeating: 0, count: count)
        var accI = [Double](repeating: 0, count: count)
        for tone in 0..<k {
            let raw = k == 1 ? 0 : -configuration.toneSpan / 2 + Double(tone) * configuration.toneSpan / Double(k - 1)
            let normalized = (raw / binWidth).rounded() / 1_024
            let phase = Double(tone * tone) / Double(2 * k)
            var cycles = vDSP.add(phase, vDSP.multiply(normalized, index))
            cycles = vDSP.subtract(cycles, vForce.trunc(cycles))
            let theta = vDSP.multiply(2 * Double.pi, cycles)
            accR = vDSP.add(accR, vForce.cos(theta))
            accI = vDSP.add(accI, vForce.sin(theta))
        }
        var block = ComplexSignalBlock(real: vDSP.doubleToFloat(accR), imag: vDSP.doubleToFloat(accI), sampleRate: fs)
        block.scale(by: amplitudeScale)
        return block
    }
}
