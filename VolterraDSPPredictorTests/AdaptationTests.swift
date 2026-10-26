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
