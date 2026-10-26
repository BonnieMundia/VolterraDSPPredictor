import Accelerate
import Testing
@testable import MyApp

// MARK: - Shared helpers

/// Deterministic complex Gaussian-like block (sum of uniforms), scaled to `rms`.
func randomBlock(count: Int, seed: UInt64, rms: Float = 0.3, sampleRate: Double = 122.88e6) -> ComplexSignalBlock {
    var rng = Xoshiro256StarStar(seed: seed)
    func gaussian() -> Float {
        (0..<4).reduce(Float(0)) { acc, _ in acc + Float.random(in: -1...1, using: &rng) } * 0.866
    }
    var block = ComplexSignalBlock(
        real: (0..<count).map { _ in gaussian() },
        imag: (0..<count).map { _ in gaussian() },
        sampleRate: sampleRate
    )
    block.normalize(toRMS: rms)
    return block
}

/// Wideband, noiseless setup under which the Volterra kernels are exactly identifiable.
func exactRecoveryConfiguration(_ algorithm: AdaptiveAlgorithm, memoryDepth: Int = 4) -> (IdentificationConfiguration, SignalConfiguration) {
    var signal = SignalConfiguration()
    signal.samplesPerSymbol = 2
    signal.rolloff = 1.0
    var config = IdentificationConfiguration()
    config.target = .syntheticVolterra
    config.measurementSNRdB = nil
    config.volterra.memoryDepth = memoryDepth
    config.adaptation.algorithm = algorithm
    config.adaptation.forgettingFactor = 1
    config.adaptation.delta = 1e-6
    return (config, signal)
}

// MARK: - Kernel layout

@Suite("Volterra kernel layout")
struct KernelLayoutTests {
    @Test("Term count is M + M²(M+1)/2 with τ₁↔τ₂ symmetry", arguments: 1...VolterraConfiguration.maxMemoryDepth)
    func termCount(memoryDepth m: Int) {
        let layout = VolterraKernelLayout(VolterraConfiguration(memoryDepth: m, order: .third))
        #expect(layout.termCount == m + m * m * (m + 1) / 2)
        #expect(layout.pairs.count == layout.cubicPairCount)
        #expect(layout.fullTensorTermCount == m + m * m * m)
    }

    @Test("Cubic index map is a symmetric bijection onto the cubic block", arguments: [1, 4, 8, 16])
    func cubicIndexBijection(memoryDepth m: Int) {
        let layout = VolterraKernelLayout(VolterraConfiguration(memoryDepth: m, order: .third))
        var seen = Set<Int>()
        for (a, b) in layout.pairs {
            for c in 0..<m {
                let index = layout.cubicIndex(a, b, c)
                #expect(index == layout.cubicIndex(b, a, c))
                seen.insert(index)
            }
        }
        #expect(seen == Set(layout.cubicOffset..<layout.termCount))
    }
}

// MARK: - Evaluation backends

@Suite("Volterra evaluation backends")
struct BackendEquivalenceTests {
    @Test("vDSP factored and regression Φ·h match the scalar reference", arguments: [1, 3, 6])
    func cpuBackendsMatchScalar(memoryDepth m: Int) {
        let layout = VolterraKernelLayout(VolterraConfiguration(memoryDepth: m, order: .third))
        let kernels = VolterraKernels.syntheticPA(layout: layout)
        let input = randomBlock(count: 2_048, seed: 7)

        var reference = VolterraFilter(kernels: kernels)
        let expected = reference.process(input, backend: .scalarReference)
        for backend in [VolterraBackend.vDSPFactored, .regressionMatrix] {
            var filter = VolterraFilter(kernels: kernels)
            let output = filter.process(input, backend: backend)
            #expect(IdentificationExperiment.nmseDB(output, reference: expected) < -100, "\(backend.rawValue)")
        }
    }

    @Test("Metal GPU kernel matches the scalar reference")
    func metalMatchesScalar() throws {
        let metal = try #require(MetalVolterraEngine(), "No Metal device")
        for m in [1, 4, 8] {
            let kernels = VolterraKernels.syntheticPA(layout: VolterraKernelLayout(VolterraConfiguration(memoryDepth: m, order: .third)))
            let input = randomBlock(count: 4_096, seed: 11)
            var reference = VolterraFilter(kernels: kernels)
            var gpu = VolterraFilter(kernels: kernels)
            let expected = reference.process(input, backend: .scalarReference)
            let output = gpu.process(input, backend: .metalGPU, metal: metal)
            #expect(IdentificationExperiment.nmseDB(output, reference: expected) < -100, "M = \(m)")
        }
    }

    @Test("Streaming in odd-sized blocks equals one-shot evaluation")
    func streamingContinuity() {
        let kernels = VolterraKernels.syntheticPA(layout: VolterraKernelLayout(VolterraConfiguration(memoryDepth: 5, order: .third)))
        let input = randomBlock(count: 3_000, seed: 3)
        var whole = VolterraFilter(kernels: kernels)
        var streamed = VolterraFilter(kernels: kernels)
        let expected = whole.process(input, backend: .vDSPFactored)
        let output = streamed.process(stream: input, blockSize: 257, backend: .vDSPFactored)
        #expect(output.count == expected.count)
        #expect(IdentificationExperiment.nmseDB(output, reference: expected) < -120)
    }
}
