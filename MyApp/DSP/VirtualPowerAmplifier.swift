import Accelerate
import Foundation

nonisolated enum PAModelKind: String, CaseIterable, Identifiable, Sendable {
    /// Saleh model — classic travelling-wave-tube amplifier characteristic.
    case saleh = "Saleh (TWTA)"
    /// Modified Rapp model — solid-state PA with tunable knee and AM/PM.
    case rapp = "Rapp (SSPA)"

    var id: String { rawValue }
}

nonisolated struct PAConfiguration: Sendable, Equatable {
    var model: PAModelKind = .rapp

    // Saleh:  A(r) = αₐ·r / (1 + βₐ·r²),   Φ(r) = α_φ·r² / (1 + β_φ·r²)
    var salehAlphaA: Float = 2.1587
    var salehBetaA: Float = 1.1517
    var salehAlphaPhi: Float = 4.0033
    var salehBetaPhi: Float = 9.1040

    // Modified Rapp:
    //   A(r) = G·r / [1 + (G·r / V_sat)^{2p}]^{1/(2p)}
    //   Φ(r) = A_φ·(r / B_φ)^q / [1 + (r / B_φ)^q]
    var smallSignalGain: Float = 1.0
    var saturationAmplitude: Float = 0.8
    var smoothness: Float = 2.0
    /// Asymptotic AM/PM phase shift (radians).
    var amPMMaxPhase: Float = 0.6
    /// Envelope amplitude at which AM/PM reaches half its maximum.
    var amPMKnee: Float = 0.7
    var amPMExponent: Float = 3.5

    // Wiener–Hammerstein memory: H_in(z) → static NL → H_out(z).
    // H_in models bias-network / matching dispersion; H_out models output
    // matching and thermal low-pass. Together they give a true memory PA whose
    // response cannot be captured by a memoryless AM/AM-AM/PM curve.
    var memoryEnabled: Bool = true
    var inputFilterTaps: [Float] = [0.85, 0.22, -0.09, 0.03]
    var outputFilterTaps: [Float] = [1.0, -0.12, 0.05]
}

/// Behavioral virtual power amplifier operating on complex baseband.
///
/// Processing is block-based and stateful: memory filters carry their delay
/// lines between `process(_:)` calls so a stream split into arbitrary blocks
/// produces exactly the same output as one long block.
nonisolated struct VirtualPowerAmplifier: Sendable {
    let configuration: PAConfiguration
    private var inputFilter: FIRFilter
    private var outputFilter: FIRFilter

    init(configuration: PAConfiguration) {
        self.configuration = configuration
        self.inputFilter = FIRFilter(taps: configuration.inputFilterTaps.isEmpty ? [1] : configuration.inputFilterTaps)
        self.outputFilter = FIRFilter(taps: configuration.outputFilterTaps.isEmpty ? [1] : configuration.outputFilterTaps)
    }

    mutating func reset() {
        inputFilter.reset()
        outputFilter.reset()
    }

    /// Amplifies one block of samples.
    mutating func process(_ block: ComplexSignalBlock) -> ComplexSignalBlock {
        guard !block.isEmpty else { return block }
        guard configuration.memoryEnabled else {
            return Self.applyStaticNonlinearity(block, configuration)
        }
        let predistorted = inputFilter.process(block)
        let saturated = Self.applyStaticNonlinearity(predistorted, configuration)
        return outputFilter.process(saturated)
    }

    /// Convenience: runs the PA over a stream in fixed-size blocks from a reset state.
    mutating func process(stream: ComplexSignalBlock, blockSize: Int) -> ComplexSignalBlock {
        reset()
        let outputs = stream.blocks(ofSize: blockSize).map { process($0) }
        return ComplexSignalBlock.concatenate(outputs)
    }

    // MARK: - Static AM/AM + AM/PM

    /// Applies y = g(|x|)·e^{jΦ(|x|)}·x, where g(r) = A(r)/r.
    ///
    /// Both models are written so g(r) is evaluated without dividing by r,
    /// so zero-amplitude samples are well defined.
    static func applyStaticNonlinearity(_ x: ComplexSignalBlock, _ c: PAConfiguration) -> ComplexSignalBlock {
        let r2 = x.power()
        let (gain, phi) = gainAndPhase(envelopePower: r2, c)

        let cosPhi = vForce.cos(phi)
        let sinPhi = vForce.sin(phi)

        // Rotation by Φ: (xr + j·xi)(cosΦ + j·sinΦ)
        let rotReal = vDSP.subtract(vDSP.multiply(x.real, cosPhi), vDSP.multiply(x.imag, sinPhi))
        let rotImag = vDSP.add(vDSP.multiply(x.real, sinPhi), vDSP.multiply(x.imag, cosPhi))

        return ComplexSignalBlock(
            real: vDSP.multiply(gain, rotReal),
            imag: vDSP.multiply(gain, rotImag),
            sampleRate: x.sampleRate
        )
    }

    /// Envelope gain g(r) = A(r)/r and phase Φ(r), given r² for each sample.
    static func gainAndPhase(envelopePower r2: [Float], _ c: PAConfiguration) -> (gain: [Float], phase: [Float]) {
        let n = r2.count
        switch c.model {
        case .saleh:
            // g(r) = αₐ / (1 + βₐr²)
            let gainDen = vDSP.add(1, vDSP.multiply(c.salehBetaA, r2))
            let gain = vDSP.divide(c.salehAlphaA, gainDen)
            // Φ(r) = α_φ r² / (1 + β_φ r²)
            let phiDen = vDSP.add(1, vDSP.multiply(c.salehBetaPhi, r2))
            let phase = vDSP.divide(vDSP.multiply(c.salehAlphaPhi, r2), phiDen)
            return (gain, phase)

        case .rapp:
            let g = c.smallSignalGain
            let vSat = max(c.saturationAmplitude, 1e-6)
            let p = max(c.smoothness, 0.1)

            // u = (G·r / V_sat)²  →  denominator = (1 + u^p)^{1/(2p)}
            let u = vDSP.multiply((g * g) / (vSat * vSat), r2)
            let up = vForce.pow(bases: u, exponents: [Float](repeating: p, count: n))
            let base = vDSP.add(1, up)
            let den = vForce.pow(bases: base, exponents: [Float](repeating: 1 / (2 * p), count: n))
            let gain = vDSP.divide(g, den)

            // v = (r / B_φ)^q = (r² / B_φ²)^{q/2};   Φ = A_φ·v / (1 + v)
            // Φ → A_φ as r → ∞ and Φ(B_φ) = A_φ / 2.
            let q = max(c.amPMExponent, 0.1)
            let knee = max(c.amPMKnee, 1e-6)
            let v = vForce.pow(bases: vDSP.divide(r2, knee * knee),
                               exponents: [Float](repeating: q / 2, count: n))
            let phase = vDSP.divide(vDSP.multiply(c.amPMMaxPhase, v), vDSP.add(1, v))
            return (gain, phase)
        }
    }

    /// Static characteristic sampled on `amplitudes`: output amplitude A(r) and
    /// phase shift Φ(r) in degrees. Used for the theoretical overlay curves.
    static func staticCharacteristic(amplitudes r: [Float], _ c: PAConfiguration) -> (amam: [Float], ampmDegrees: [Float]) {
        let (gain, phase) = gainAndPhase(envelopePower: vDSP.square(r), c)
        return (vDSP.multiply(gain, r), vDSP.multiply(180 / Float.pi, phase))
    }
}
