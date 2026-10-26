import Foundation
import Observation

/// UI state for the Phase 2 Volterra engine workbench.
@Observable
final class Phase2EngineModel {
    /// Kernel shown in the structure panel and coefficient map.
    var configuration = VolterraConfiguration(memoryDepth: 6, order: .third, includeConstant: false)
    var benchmarkOrder: VolterraOrder = .third
    var blockSize = 1_024

    private(set) var report: VolterraBenchmarkReport?
    private(set) var isRunning = false
    private(set) var progress: Double = 0

    /// Created once; compiling the pipeline state is expensive. `nil` if Metal is unavailable.
    let metal = MetalVolterraEngine()

    var layout: VolterraKernelLayout { VolterraKernelLayout(configuration) }

    /// Regression matrix footprint per block for the current configuration.
    var regressionMatrixBytes: Int { layout.termCount * blockSize * 2 * MemoryLayout<Float>.stride }

    func runBenchmark() async {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        defer { isRunning = false }

        let order = benchmarkOrder
        let blockSize = blockSize
        let metal = metal
        // The model is main-actor isolated (hence Sendable); progress hops back to it.
        let reportProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in self.progress = fraction }
        }
        let report = await Task.detached(priority: .userInitiated) {
            VolterraBenchmark.run(order: order, blockSize: blockSize, metal: metal, progress: reportProgress)
        }.value
        self.report = report
    }
}
