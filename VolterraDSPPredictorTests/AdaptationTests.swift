import Accelerate
import Foundation
import Testing
@testable import MyApp

@Suite("Adaptive identification")
struct IdentificationTests {
    @Test("RLS and Block RLS recover a known Volterra system exactly", arguments: [AdaptiveAlgorithm.rls, .blockRLS])
    func exactRecovery(algorithm: AdaptiveAlgorithm) throws {
        let (config, signal) = exactRecoveryConfiguration(algorithm)
        let run = IdentificationExperiment.run(config, signal: signal, amplifier: PAConfiguration())
        #expect(!run.diverged)
        let coefficientError = try #require(run.coefficientErrorDB)
        #expect(coefficientError < -100)    // measured −119.7 dB
        #expect(run.modelNMSEdB < -110)
    }

    @Test("Block RLS reaches the same solution as sample-by-sample RLS")
    func blockMatchesSampleRLS() {
        let (rlsConfig, signal) = exactRecoveryConfiguration(.rls)
        let (blockConfig, _) = exactRecoveryConfiguration(.blockRLS)
        let rls = IdentificationExperiment.run(rlsConfig, signal: signal, amplifier: PAConfiguration())
        let block = IdentificationExperiment.run(blockConfig, signal: signal, amplifier: PAConfiguration())
        let dr = vDSP.subtract(rls.kernels.real, block.kernels.real)
        let di = vDSP.subtract(rls.kernels.imag, block.kernels.imag)
        let difference = Double(vDSP.sumOfSquares(dr) + vDSP.sumOfSquares(di))
        let norm = Double(vDSP.sumOfSquares(rls.kernels.real) + vDSP.sumOfSquares(rls.kernels.imag))
        #expect(10 * log10(difference / norm) < -90)
    }

    @Test("NLMS converges on the noiseless synthetic system")
    func nlmsConverges() throws {
        var config = IdentificationConfiguration()
        config.target = .syntheticVolterra
        config.measurementSNRdB = nil
        config.adaptation.algorithm = .nlms
        let run = IdentificationExperiment.run(config, signal: SignalConfiguration(), amplifier: PAConfiguration())
        #expect(!run.diverged)
        #expect(run.modelNMSEdB < -35)      // measured −44 dB
        let first = try #require(run.curve.first?.errorDB)
        let last = try #require(run.curve.last?.errorDB)
        #expect(last < first - 20)
    }

    @Test("Only sample-by-sample RLS above the cost threshold is flagged")
    func costWarning() {
        #expect(AdaptiveAlgorithm.rls.costWarning(termCount: 44) == nil)     // M = 4
        #expect(AdaptiveAlgorithm.rls.costWarning(termCount: 80) != nil)     // M = 5
        #expect(AdaptiveAlgorithm.blockRLS.costWarning(termCount: 296) == nil)
        #expect(AdaptiveAlgorithm.nlms.costWarning(termCount: 296) == nil)
    }

    @Test("Cholesky solve matches a known SPD system")
    func choleskySolve() throws {
        // A = [[4, 2, 0.4], [2, 5, 1], [0.4, 1, 3]], x = [1, −2, 0.5] → b = A·x
        let a: [Double] = [4, 2, 0.4, 2, 5, 1, 0.4, 1, 3]
        let x: [Double] = [1, -2, 0.5]
        let b = (0..<3).map { r in (0..<3).reduce(0.0) { $0 + a[r * 3 + $1] * x[$1] } }
        let solved = try #require(AdaptiveVolterraIdentifier.choleskySolve(a, b, n: 3))
        for (s, e) in zip(solved, x) { #expect(abs(s - e) < 1e-12) }
        #expect(AdaptiveVolterraIdentifier.choleskySolve([1, 2, 2, 1], [1, 1], n: 2) == nil)
    }
}

@Suite("Digital predistortion")
struct LinearizationTests {
    @Test("Closed-loop indirect-learning DPD improves NMSE by more than 13 dB")
    func dpdLoop() {
        let result = DPDLoop.run(signal: SignalConfiguration(), amplifier: PAConfiguration(), dpd: DPDConfiguration())
        #expect(!result.diverged)
        #expect(result.nmseImprovementDB > 13)   // measured 15.9 dB
    }

    @Test("Live engine linearizes ACLR, NMSE and EVM")
    func liveEngine() throws {
        var core = LinearizationCore(configuration: LiveConfiguration())
        var snapshot = core.advance()
        for _ in 0..<40 { snapshot = core.advance() }
        #expect(snapshot.divergenceResets == 0)
        #expect(snapshot.aclrWithoutDPD.worstDBc - snapshot.aclrWithDPD.worstDBc > 12)   // measured 13.8
        #expect(snapshot.nmseWithoutDPD - snapshot.nmseWithDPD > 14)                     // measured 16.0
        let evm = try #require(snapshot.symbolEVMWithDPD)
        #expect(evm < 1.5)                                                               // measured 0.67 %
    }

    @Test("Adapting on a subset of frames still linearizes", arguments: [4, 8])
    func subsampledAdaptation(interval: Int) {
        var configuration = LiveConfiguration()
        configuration.adaptationInterval = interval
        var core = LinearizationCore(configuration: configuration)
        var snapshot = core.advance()
        for _ in 0..<40 { snapshot = core.advance() }
        #expect(snapshot.divergenceResets == 0)
        #expect(snapshot.aclrWithoutDPD.worstDBc - snapshot.aclrWithDPD.worstDBc > 12)
    }

    @Test("A pruned M = 8 kernel adapted on 1 frame in 8 still linearizes", arguments: [0, 1])
    func prunedLiveEngine(pairSpan: Int) {
        var configuration = LiveConfiguration()
        configuration.volterra.memoryDepth = 8
        configuration.volterra.maxPairSpan = pairSpan
        configuration.adaptationInterval = 8
        var core = LinearizationCore(configuration: configuration)
        var snapshot = core.advance()
        for _ in 0..<40 { snapshot = core.advance() }
        #expect(snapshot.termCount < 296)
        #expect(snapshot.divergenceResets == 0)
        #expect(snapshot.aclrWithoutDPD.worstDBc - snapshot.aclrWithDPD.worstDBc > 12)   // measured 13.9
    }

    @Test("Pruning removes model capacity on a system that needs cross-terms")
    func pruningCostsAccuracyWhenCrossTermsMatter() {
        // Wideband stimulus through a full-kernel M = 4 system, fitted with full and diagonal-only models.
        var signal = SignalConfiguration()
        signal.samplesPerSymbol = 2
        signal.rolloff = 1.0
        signal.sampleCount = 8_192
        let x = SignalSynthesizer.generate(signal)
        var system = VolterraFilter(kernels: .syntheticPA(layout: VolterraKernelLayout(VolterraConfiguration(memoryDepth: 4, order: .third))))
        let y = system.process(stream: x, blockSize: 1_024, backend: .vDSPFactored)

        func fitNMSE(span: Int?) -> Double {
            let layout = VolterraKernelLayout(VolterraConfiguration(memoryDepth: 4, order: .third, maxPairSpan: span))
            var identifier = AdaptiveVolterraIdentifier(layout: layout, parameters: AdaptationParameters(algorithm: .blockRLS, forgettingFactor: 1, delta: 1e-6))
            var delay = VolterraFilter(kernels: VolterraKernels(layout: layout))
            for (xb, yb) in zip(x.blocks(ofSize: 1_024), y.blocks(ofSize: 1_024)) {
                identifier.adapt(regressors: RegressorRows.build(extended: delay.extend(xb), layout: layout), desired: yb)
            }
            var model = VolterraFilter(kernels: identifier.kernels)
            return IdentificationExperiment.nmseDB(model.process(stream: x, blockSize: 1_024, backend: .vDSPFactored), reference: y)
        }
        let full = fitNMSE(span: nil), diagonal = fitNMSE(span: 0)
        #expect(full < -100)
        #expect(diagonal > full + 30)
    }

    @Test("Bypassing DPD leaves both PA paths equivalent")
    func bypass() {
        var configuration = LiveConfiguration()
        configuration.dpdEnabled = false
        var core = LinearizationCore(configuration: configuration)
        var snapshot = core.advance()
        for _ in 0..<20 { snapshot = core.advance() }
        #expect(snapshot.status == .bypassed)
        #expect(abs(snapshot.aclrWithoutDPD.worstDBc - snapshot.aclrWithDPD.worstDBc) < 1)
    }
}
