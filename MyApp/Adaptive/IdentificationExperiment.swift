import Accelerate
import Foundation

/// One point on a learning curve (a-priori NMSE averaged over a bin of samples).
nonisolated struct LearningCurvePoint: Identifiable, Sendable {
    var id: String { "\(series)-\(iteration)" }
    let series: String
    let iteration: Int
    let errorDB: Double
}

nonisolated enum IdentificationTarget: String, CaseIterable, Identifiable, Sendable {
    /// The Phase 1 Wiener–Hammerstein PA — a model-mismatch case (finite M, P = 3).
    case virtualPA = "Virtual PA (Phase 1)"
    /// A known Volterra system of the same structure — coefficients are recoverable exactly.
    case syntheticVolterra = "Synthetic Volterra (exact)"

    var id: String { rawValue }
}

nonisolated struct IdentificationConfiguration: Sendable, Equatable, Hashable {
    var target: IdentificationTarget = .virtualPA
    var volterra = VolterraConfiguration(memoryDepth: 4, order: .third)
    var adaptation = AdaptationParameters()
    var sampleCount = 16_384
    var blockSize = 1_024
    /// Observation SNR of the measured PA output (dB). `nil` = noiseless.
    var measurementSNRdB: Double? = 60
}

nonisolated struct IdentificationRun: Sendable, Identifiable {
    var id: String { label }
    let label: String
    let curve: [LearningCurvePoint]
    /// NMSE of the final model over the whole record (a-posteriori, dB).
    let modelNMSEdB: Double
    /// ‖ĥ − h‖² / ‖h‖² in dB (synthetic target only).
    let coefficientErrorDB: Double?
    let seconds: Double
    let diverged: Bool
    let kernels: VolterraKernels
}

nonisolated enum IdentificationExperiment {
    static let curvePoints = 160

    /// Fixed NLMS step sizes for the comparison sweep, plus one RLS run.
    static let sweepStepSizes: [Double] = [0.05, 0.2, 0.5, 1.0]

    static func run(
        _ config: IdentificationConfiguration,
        signal: SignalConfiguration,
        amplifier: PAConfiguration
    ) -> IdentificationRun {
        let data = makeData(config, signal: signal, amplifier: amplifier)
        return identify(config, input: data.input, observed: data.observed, clean: data.clean, truth: data.truth)
    }

    /// NLMS at each sweep step size and RLS, all on the same record.
    static func sweep(
        _ config: IdentificationConfiguration,
        signal: SignalConfiguration,
        amplifier: PAConfiguration
    ) -> [IdentificationRun] {
        let data = makeData(config, signal: signal, amplifier: amplifier)
        var configs = sweepStepSizes.map { mu -> IdentificationConfiguration in
            var c = config
            c.adaptation.algorithm = .nlms
            c.adaptation.stepSize = mu
            return c
        }
        var rls = config
        rls.adaptation.algorithm = .rls
        configs.append(rls)
        return configs.map { identify($0, input: data.input, observed: data.observed, clean: data.clean, truth: data.truth) }
    }

    // MARK: - Internals

    private struct Record {
        let input: ComplexSignalBlock
        /// Noisy observation used for adaptation.
        let observed: ComplexSignalBlock
        /// Noise-free system output, for a-posteriori model NMSE.
        let clean: ComplexSignalBlock
        let truth: VolterraKernels?
    }

    private static func makeData(_ config: IdentificationConfiguration, signal: SignalConfiguration, amplifier: PAConfiguration) -> Record {
        var signal = signal
        signal.sampleCount = config.sampleCount
        let x = SignalSynthesizer.generate(signal)

        let clean: ComplexSignalBlock
        var truth: VolterraKernels?
        switch config.target {
        case .virtualPA:
            var pa = VirtualPowerAmplifier(configuration: amplifier)
            clean = pa.process(stream: x, blockSize: config.blockSize)
        case .syntheticVolterra:
            let kernels = VolterraKernels.syntheticPA(layout: VolterraKernelLayout(config.volterra))
            var system = VolterraFilter(kernels: kernels)
            clean = system.process(stream: x, blockSize: config.blockSize, backend: .vDSPFactored)
            truth = kernels
        }

        var observed = clean
        if let snr = config.measurementSNRdB {
            var rng = Xoshiro256StarStar(seed: signal.seed ^ 0xA5A5_5A5A)
            NoiseGenerator.addGaussianNoise(to: &observed, snrDB: snr, using: &rng)
        }
        return Record(input: x, observed: observed, clean: clean, truth: truth)
    }

    private static func identify(
        _ config: IdentificationConfiguration,
        input x: ComplexSignalBlock,
        observed y: ComplexSignalBlock,
        clean: ComplexSignalBlock,
        truth: VolterraKernels?
    ) -> IdentificationRun {
        let layout = VolterraKernelLayout(config.volterra)
        var identifier = AdaptiveVolterraIdentifier(layout: layout, parameters: config.adaptation)
        var delayLine = VolterraFilter(kernels: VolterraKernels(layout: layout))
        let clock = ContinuousClock()

        var errorPower: [Double] = []
        errorPower.reserveCapacity(x.count)
        let elapsed = clock.measure {
            let inputBlocks = x.blocks(ofSize: config.blockSize)
            let outputBlocks = y.blocks(ofSize: config.blockSize)
            for (xb, yb) in zip(inputBlocks, outputBlocks) {
                let rows = RegressorRows.build(extended: delayLine.extend(xb), layout: layout)
                errorPower += identifier.adapt(regressors: rows, desired: yb)
                if identifier.diverged { break }
            }
        }

        let referencePower = Double(y.meanPower)
        let label = config.adaptation.seriesLabel
        let curve = learningCurve(errorPower, referencePower: referencePower, series: label)

        // A-posteriori: run the frozen model over the full record vs. the noise-free output.
        let kernels = identifier.kernels
        var model = VolterraFilter(kernels: kernels)
        let predicted = model.process(stream: x, blockSize: config.blockSize, backend: .vDSPFactored)
        let modelNMSE = nmseDB(predicted, reference: clean)

        var coefficientError: Double?
        if let truth {
            let dr = vDSP.subtract(kernels.real, truth.real)
            let di = vDSP.subtract(kernels.imag, truth.imag)
            let num = Double(vDSP.sumOfSquares(dr) + vDSP.sumOfSquares(di))
            let den = Double(vDSP.sumOfSquares(truth.real) + vDSP.sumOfSquares(truth.imag))
            coefficientError = 10 * log10(max(num / den, 1e-30))
        }

        return IdentificationRun(
            label: label,
            curve: curve,
            modelNMSEdB: identifier.diverged ? .infinity : modelNMSE,
            coefficientErrorDB: identifier.diverged ? nil : coefficientError,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
            diverged: identifier.diverged,
            kernels: kernels
        )
    }

    /// Bins |e(n)|² into ~`curvePoints` averages, normalized by output power.
    static func learningCurve(_ errorPower: [Double], referencePower: Double, series: String) -> [LearningCurvePoint] {
        let finite = errorPower.prefix { $0.isFinite }
        guard !finite.isEmpty, referencePower > 0 else { return [] }
        let bin = max(1, finite.count / curvePoints)
        return stride(from: 0, to: finite.count, by: bin).map { start in
            let slice = finite[start..<min(start + bin, finite.count)]
            let mean = slice.reduce(0, +) / Double(slice.count)
            return LearningCurvePoint(
                series: series,
                iteration: start + slice.count,
                errorDB: 10 * log10(max(mean / referencePower, 1e-30))
            )
        }
    }

    static func nmseDB(_ value: ComplexSignalBlock, reference: ComplexSignalBlock) -> Double {
        let err = Double(value.subtracting(reference).meanPower)
        let ref = Double(max(reference.meanPower, .leastNormalMagnitude))
        return 10 * log10(max(err / ref, 1e-30))
    }
}

nonisolated enum NoiseGenerator {
    /// Adds circular complex white Gaussian noise at the given SNR (Box–Muller).
    static func addGaussianNoise<G: RandomNumberGenerator>(to block: inout ComplexSignalBlock, snrDB: Double, using rng: inout G) {
        let n = block.count
        guard n > 0 else { return }
        let noisePower = Double(block.meanPower) / pow(10, snrDB / 10)
        let sigma = Float((noisePower / 2).squareRoot())   // per real dimension

        var u1 = [Float](repeating: 0, count: n)
        var u2 = [Float](repeating: 0, count: n)
        for i in 0..<n {
            u1[i] = Float.random(in: Float.leastNormalMagnitude..<1, using: &rng)
            u2[i] = Float.random(in: 0..<1, using: &rng)
        }
        // r = σ·√(−2 ln u1),  θ = 2π·u2
        let radius = vDSP.multiply(sigma, vForce.sqrt(vDSP.multiply(-2, vForce.log(u1))))
        let theta = vDSP.multiply(2 * Float.pi, u2)
        block.real = vDSP.add(block.real, vDSP.multiply(radius, vForce.cos(theta)))
        block.imag = vDSP.add(block.imag, vDSP.multiply(radius, vForce.sin(theta)))
    }
}
