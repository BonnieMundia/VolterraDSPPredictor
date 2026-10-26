import Accelerate
import Foundation

nonisolated struct DPDConfiguration: Sendable, Equatable, Hashable {
    var volterra = VolterraConfiguration(memoryDepth: 4, order: .third)
    /// λ must keep a memory of several blocks (1/(1−λ) = 10 000 samples here): with
    /// λ = 0.999 the post-inverse overfits the latest block and the frozen
    /// predistorter produces > 20 dB PAPR spikes on peaks it has not seen recently.
    var adaptation = AdaptationParameters(algorithm: .blockRLS, forgettingFactor: 0.9999, delta: 1e-2)
    /// Number of passes of the stimulus through the closed loop.
    var passes = 4
    var blockSize = 1_024
    /// SNR of the observation (feedback) receiver. `nil` = ideal.
    var feedbackSNRdB: Double? = 60
}

/// Per-block convergence sample of the closed DPD loop.
nonisolated struct DPDIterationPoint: Identifiable, Sendable {
    var id: Int { block }
    let block: Int
    /// NMSE between gain-normalized PA output y/G and the ideal reference u (dB).
    let nmseDB: Double
}

nonisolated struct DPDResult: Sendable {
    let reference: ComplexSignalBlock        // u: ideal input
    let predistorted: ComplexSignalBlock     // z = DPD(u), frozen final coefficients
    let outputWithoutDPD: ComplexSignalBlock // PA(u)
    let outputWithDPD: ComplexSignalBlock    // PA(DPD(u))
    let targetGain: DSPComplex               // G

    let baseline: DistortionMetrics
    let linearized: DistortionMetrics
    let iterations: [DPDIterationPoint]
    /// A-priori post-inverse training error (ILA learning curve).
    let trainingCurve: [LearningCurvePoint]
    let kernels: VolterraKernels
    let diverged: Bool
    let seconds: Double

    let amamBefore: [TransferPoint]
    let amamAfter: [TransferPoint]
    let ampmBefore: [TransferPoint]
    let ampmAfter: [TransferPoint]

    var nmseImprovementDB: Float { baseline.nmseDB - linearized.nmseDB }
}

/// Closed-loop Digital Pre-Distortion with the Indirect Learning Architecture.
///
///        u ──► [ DPD  g ] ──z──► [ PA ] ──y──► ÷G ──ỹ
///                  ▲                              │
///                  └──── copy ◄── [ post-inverse g ] ◄─ adapt: ỹ → z
///
/// The post-inverse is identified (NLMS/RLS) to map ỹ = y/G back to z; its
/// coefficients are copied into the predistorter after every block. At
/// convergence PA(DPD(u)) ≈ G·u, i.e. the cascade is linear.
nonisolated enum DPDLoop {
    static let scatterPoints = 1_500

    static func run(signal: SignalConfiguration, amplifier: PAConfiguration, dpd: DPDConfiguration) -> DPDResult {
        let clock = ContinuousClock()
        let start = clock.now
        let layout = VolterraKernelLayout(dpd.volterra)
        let u = SignalSynthesizer.generate(signal)

        // Baseline and target gain G from the uncorrected PA (LS gain includes AM/PM offset).
        var baselinePA = VirtualPowerAmplifier(configuration: amplifier)
        let y0 = baselinePA.process(stream: u, blockSize: dpd.blockSize)
        let gain = DistortionMetrics.linearGain(input: u, output: y0)
        let inverseGain = reciprocal(gain)
        let baseline = DistortionMetrics.measure(input: u, output: y0)

        // Identity initialization: h₁(0) = 1, everything else 0.
        var identity = VolterraKernels(layout: layout)
        identity.setLinear(0, DSPComplex(real: 1, imag: 0))

        var predistorter = VolterraFilter(kernels: identity)
        var postInverseDelay = VolterraFilter(kernels: identity)   // delay line for ỹ regressors
        var identifier = AdaptiveVolterraIdentifier(layout: layout, parameters: dpd.adaptation, initial: identity)
        var pa = VirtualPowerAmplifier(configuration: amplifier)
        var rng = Xoshiro256StarStar(seed: signal.seed ^ 0xD1D1_D1D1)

        var iterations: [DPDIterationPoint] = []
        var trainingError: [Double] = []
        let blocks = u.blocks(ofSize: dpd.blockSize)
        var blockIndex = 0

        loop: for _ in 0..<max(dpd.passes, 1) {
            for ub in blocks {
                let z = predistorter.process(ub, backend: .vDSPFactored)
                var y = pa.process(z)
                if let snr = dpd.feedbackSNRdB {
                    NoiseGenerator.addGaussianNoise(to: &y, snrDB: snr, using: &rng)
                }
                let yNormalized = y.multiplied(by: inverseGain)

                iterations.append(DPDIterationPoint(
                    block: blockIndex,
                    nmseDB: IdentificationExperiment.nmseDB(yNormalized, reference: ub)
                ))
                blockIndex += 1

                // Post-inverse training: regressors from ỹ, desired = z.
                let rows = RegressorRows.build(extended: postInverseDelay.extend(yNormalized), layout: layout)
                trainingError += identifier.adapt(regressors: rows, desired: z)
                if identifier.diverged || !(iterations.last?.nmseDB.isFinite ?? false) { break loop }

                // Copy post-inverse → predistorter (keeps the predistorter's delay line).
                predistorter.kernels = identifier.kernels
            }
        }

        // Final evaluation with frozen coefficients from a clean state.
        let kernels = identifier.kernels
        var frozen = VolterraFilter(kernels: kernels)
        let z = frozen.process(stream: u, blockSize: dpd.blockSize, backend: .vDSPFactored)
        var finalPA = VirtualPowerAmplifier(configuration: amplifier)
        let yFinal = finalPA.process(stream: z, blockSize: dpd.blockSize)

        // Linearized metrics use the same target gain G as the loop.
        let linearized = metrics(reference: u, output: yFinal, gain: gain)
        let y0n = y0.multiplied(by: inverseGain)
        let yFn = yFinal.multiplied(by: inverseGain)

        return DPDResult(
            reference: u,
            predistorted: z,
            outputWithoutDPD: y0,
            outputWithDPD: yFinal,
            targetGain: gain,
            baseline: baseline,
            linearized: linearized,
            iterations: iterations,
            trainingCurve: IdentificationExperiment.learningCurve(
                trainingError, referencePower: Double(u.meanPower), series: "Post-inverse a-priori error"),
            kernels: kernels,
            diverged: identifier.diverged,
            seconds: (clock.now - start).timeInterval,
            amamBefore: amam(u, y0n),
            amamAfter: amam(u, yFn),
            ampmBefore: ampm(u, y0n),
            ampmAfter: ampm(u, yFn)
        )
    }

    // MARK: - Helpers

    /// Like `DistortionMetrics.measure` but with the error taken against a fixed gain G,
    /// so "after" is judged against the same linear target as "before".
    private static func metrics(reference u: ComplexSignalBlock, output y: ComplexSignalBlock, gain: DSPComplex) -> DistortionMetrics {
        let target = u.multiplied(by: gain)
        let nmse = Float(max(Double(y.subtracting(target).meanPower) / Double(max(target.meanPower, .leastNormalMagnitude)), 1e-30))
        let ls = DistortionMetrics.measure(input: u, output: y)
        return DistortionMetrics(
            linearGain: gain,
            nmseDB: 10 * log10(nmse),
            evmPercent: nmse.squareRoot() * 100,
            inputPAPRdB: ls.inputPAPRdB,
            outputPAPRdB: ls.outputPAPRdB,
            averageCompressionDB: 10 * log10(max(y.meanPower, 1e-30) / max(target.meanPower, 1e-30))
        )
    }

    private static func reciprocal(_ g: DSPComplex) -> DSPComplex {
        let m2 = g.real * g.real + g.imag * g.imag
        guard m2 > 0 else { return DSPComplex(real: 1, imag: 0) }
        return DSPComplex(real: g.real / m2, imag: -g.imag / m2)
    }

    private static func amam(_ u: ComplexSignalBlock, _ y: ComplexSignalBlock) -> [TransferPoint] {
        let a = u.magnitude(), b = y.magnitude()
        let step = max(1, a.count / scatterPoints)
        return stride(from: 0, to: a.count, by: step).map { TransferPoint(id: $0, input: a[$0], output: b[$0]) }
    }

    private static func ampm(_ u: ComplexSignalBlock, _ y: ComplexSignalBlock) -> [TransferPoint] {
        let a = u.magnitude()
        let phase = DistortionMetrics.relativePhaseDegrees(input: u, output: y)
        let step = max(1, a.count / scatterPoints)
        return stride(from: 0, to: a.count, by: step).map { TransferPoint(id: $0, input: a[$0], output: phase[$0]) }
    }
}

nonisolated extension Duration {
    var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
