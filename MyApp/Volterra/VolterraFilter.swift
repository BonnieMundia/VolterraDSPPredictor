import Accelerate
import Foundation

nonisolated enum VolterraBackend: String, CaseIterable, Identifiable, Sendable {
    case scalarReference = "Scalar reference"
    case vDSPFactored = "vDSP factored"
    case regressionMatrix = "Regression Φ·h"
    case metalGPU = "Metal GPU"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .scalarReference: "Direct triple-sum multidimensional convolution, one sample at a time"
        case .vDSPFactored: "Per-pair product × vDSP_zconv FIR of x*, accumulated with vDSP_zvma"
        case .regressionMatrix: "Builds Φ (N×K) with vDSP, then y = Φh with BLAS-backed vDSP_mmul"
        case .metalGPU: "Fused compute kernel, one thread per sample, no Φ materialization"
        }
    }
}

/// Streaming Volterra filter. Keeps the last M−1 input samples so a stream
/// processed in blocks of any size matches a single-block evaluation exactly.
nonisolated struct VolterraFilter: Sendable {
    var kernels: VolterraKernels
    private var historyReal: [Float]
    private var historyImag: [Float]

    init(kernels: VolterraKernels) {
        self.kernels = kernels
        let h = kernels.layout.memoryDepth - 1
        historyReal = [Float](repeating: 0, count: h)
        historyImag = [Float](repeating: 0, count: h)
    }

    mutating func reset() {
        vDSP.fill(&historyReal, with: 0)
        vDSP.fill(&historyImag, with: 0)
    }

    /// [history (M−1) | block (N)] and advance the delay line.
    mutating func extend(_ block: ComplexSignalBlock) -> ComplexSignalBlock {
        let extended = ComplexSignalBlock(
            real: historyReal + block.real,
            imag: historyImag + block.imag,
            sampleRate: block.sampleRate
        )
        let h = historyReal.count
        if h > 0 {
            historyReal = Array(extended.real.suffix(h))
            historyImag = Array(extended.imag.suffix(h))
        }
        return extended
    }

    mutating func process(_ block: ComplexSignalBlock, backend: VolterraBackend, metal: MetalVolterraEngine? = nil) -> ComplexSignalBlock {
        guard !block.isEmpty else { return block }
        let extended = extend(block)
        switch backend {
        case .scalarReference:
            return VolterraCPUEngine.evaluateScalar(extended: extended, kernels: kernels)
        case .vDSPFactored:
            return VolterraCPUEngine.evaluateFactored(extended: extended, kernels: kernels)
        case .regressionMatrix:
            return VolterraCPUEngine.evaluateRegression(extended: extended, kernels: kernels)
        case .metalGPU:
            guard let metal else { return VolterraCPUEngine.evaluateFactored(extended: extended, kernels: kernels) }
            return metal.evaluate(extended: extended, kernels: kernels)
        }
    }

    /// Processes a stream in fixed-size blocks from a reset state.
    mutating func process(stream: ComplexSignalBlock, blockSize: Int, backend: VolterraBackend, metal: MetalVolterraEngine? = nil) -> ComplexSignalBlock {
        reset()
        let outputs = stream.blocks(ofSize: blockSize).map { process($0, backend: backend, metal: metal) }
        return ComplexSignalBlock.concatenate(outputs)
    }
}
