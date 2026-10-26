import Accelerate
import Foundation

nonisolated struct VolterraBenchmarkEntry: Identifiable, Sendable {
    var id: String { "\(backend.rawValue)-\(memoryDepth)" }
    let backend: VolterraBackend
    let memoryDepth: Int
    let termCount: Int
    let blockSize: Int
    /// Samples actually timed (the scalar reference runs on a shorter window).
    let samplesTimed: Int
    /// Best-of-N wall time per block, including all host-side work.
    let secondsPerBlock: Double
    /// GPU-only execution time per block (Metal backend only).
    let gpuSecondsPerBlock: Double?
    /// max|y − y_ref| / max|y_ref| against the scalar reference.
    let relativeError: Float

    var throughputMSps: Double { Double(blockSize) / secondsPerBlock / 1e6 }
    /// Kernel-term evaluations per second (N·K / t) in giga-terms/s.
    var gigaTermsPerSecond: Double { Double(blockSize * termCount) / secondsPerBlock / 1e9 }
}

nonisolated struct VolterraSelfCheck: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let detail: String
    let error: Float
    let tolerance: Float
    var passed: Bool { error <= tolerance }
}

nonisolated struct VolterraBenchmarkReport: Sendable {
    let order: VolterraOrder
    let blockSize: Int
    let entries: [VolterraBenchmarkEntry]
    let checks: [VolterraSelfCheck]
    let gpuName: String?

    /// Fastest backend for each memory depth.
    func winner(forDepth depth: Int) -> VolterraBenchmarkEntry? {
        entries.filter { $0.memoryDepth == depth }.max { $0.throughputMSps < $1.throughputMSps }
    }

    /// Smallest depth at which the GPU outperforms the best CPU backend —
    /// the CPU efficiency boundary for this block size.
    var gpuCrossoverDepth: Int? {
        let depths = Set(entries.map(\.memoryDepth)).sorted()
        return depths.first { winner(forDepth: $0)?.backend == .metalGPU }
    }
}

nonisolated enum VolterraBenchmark {
    static let defaultDepths = [1, 2, 3, 4, 6, 8, 10, 12, 14, 16]
    /// The scalar reference is O(N·K) in plain Swift; time it on a short window.
    static let scalarWindow = 1_024
    static let repetitions = 3

    static func run(
        order: VolterraOrder,
        depths: [Int] = defaultDepths,
        blockSize: Int,
        blocksPerRun: Int = 8,
        metal: MetalVolterraEngine?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> VolterraBenchmarkReport {
        var stimulusConfig = SignalConfiguration()
        stimulusConfig.sampleCount = blockSize * blocksPerRun
        let stimulus = SignalSynthesizer.generate(stimulusConfig)
        let clock = ContinuousClock()

        var entries: [VolterraBenchmarkEntry] = []
        let backends = VolterraBackend.allCases.filter { $0 != .metalGPU || metal != nil }

        for (step, depth) in depths.enumerated() {
            let layout = VolterraKernelLayout(VolterraConfiguration(memoryDepth: depth, order: order))
            let kernels = VolterraKernels.syntheticPA(layout: layout)

            // Ground truth on the scalar window.
            let window = stimulus.slice(0..<min(scalarWindow, stimulus.count))
            var referenceFilter = VolterraFilter(kernels: kernels)
            var reference = ComplexSignalBlock(count: 0, sampleRate: stimulus.sampleRate)
            let scalarTime = clock.measure {
                reference = referenceFilter.process(stream: window, blockSize: window.count, backend: .scalarReference)
            }
            let referencePeak = max(reference.peakAmplitude, 1e-20)

            for backend in backends {
                if backend == .scalarReference {
                    entries.append(VolterraBenchmarkEntry(
                        backend: backend, memoryDepth: depth, termCount: layout.termCount,
                        blockSize: blockSize, samplesTimed: window.count,
                        secondsPerBlock: seconds(scalarTime) * Double(blockSize) / Double(window.count),
                        gpuSecondsPerBlock: nil, relativeError: 0
                    ))
                    continue
                }

                var filter = VolterraFilter(kernels: kernels)
                // Warm-up: populates caches, GPU pipeline and buffer pool.
                _ = filter.process(stream: stimulus.slice(0..<blockSize), blockSize: blockSize, backend: backend, metal: metal)

                var best = Double.infinity
                var bestGPU = Double.infinity
                var output = stimulus
                for _ in 0..<repetitions {
                    filter.reset()
                    var gpuTotal = 0.0
                    let elapsed = clock.measure {
                        var outputs: [ComplexSignalBlock] = []
                        outputs.reserveCapacity(blocksPerRun)
                        for block in stimulus.blocks(ofSize: blockSize) {
                            outputs.append(filter.process(block, backend: backend, metal: metal))
                            if backend == .metalGPU { gpuTotal += metal?.lastGPUExecutionSeconds ?? 0 }
                        }
                        output = ComplexSignalBlock.concatenate(outputs)
                    }
                    best = min(best, seconds(elapsed))
                    bestGPU = min(bestGPU, gpuTotal)
                }

                let blocks = Double(stimulus.blocks(ofSize: blockSize).count)
                let error = vDSP.maximum(output.slice(0..<reference.count).subtracting(reference).magnitude()) / referencePeak
                entries.append(VolterraBenchmarkEntry(
                    backend: backend, memoryDepth: depth, termCount: layout.termCount,
                    blockSize: blockSize, samplesTimed: stimulus.count,
                    secondsPerBlock: best / blocks,
                    gpuSecondsPerBlock: backend == .metalGPU ? bestGPU / blocks : nil,
                    relativeError: error
                ))
            }
            progress?(Double(step + 1) / Double(depths.count + 1))
        }

        let checks = selfChecks(metal: metal)
        progress?(1)
        return VolterraBenchmarkReport(order: order, blockSize: blockSize, entries: entries, checks: checks, gpuName: metal?.deviceName)
    }

    // MARK: - Analytical self-checks

    /// Cases with closed-form answers that pin down indexing, conjugation and state handling.
    static func selfChecks(metal: MetalVolterraEngine?) -> [VolterraSelfCheck] {
        var stimulusConfig = SignalConfiguration()
        stimulusConfig.sampleCount = 4_096
        let x = SignalSynthesizer.generate(stimulusConfig)
        var checks: [VolterraSelfCheck] = []

        // 1. P = 1 with real taps must equal the Phase 1 FIR filter.
        let taps: [Float] = [0.85, 0.22, -0.09, 0.03]
        var linear = VolterraKernels(layout: VolterraKernelLayout(VolterraConfiguration(memoryDepth: taps.count, order: .first)))
        for (t, v) in taps.enumerated() { linear.setLinear(t, DSPComplex(real: v, imag: 0)) }
        var linearFilter = VolterraFilter(kernels: linear)
        var fir = FIRFilter(taps: taps)
        checks.append(VolterraSelfCheck(
            name: "P = 1 ≡ FIR",
            detail: "Linear kernel reproduces vDSP_conv FIR output",
            error: relativeError(linearFilter.process(stream: x, blockSize: 1_024, backend: .vDSPFactored), fir.process(x)),
            tolerance: 1e-5
        ))

        // 2. M = 1 cubic must equal a·x + b·x·|x|² (checks conjugate placement).
        let a = DSPComplex(real: 1, imag: 0)
        let b = DSPComplex(real: -0.3, imag: 0.1)
        var memoryless = VolterraKernels(layout: VolterraKernelLayout(VolterraConfiguration(memoryDepth: 1, order: .third)))
        memoryless.setLinear(0, a)
        memoryless.setCubic(0, 0, 0, b)
        let power = x.power()
        let cubicGain = ComplexSignalBlock(real: vDSP.multiply(b.real, power), imag: vDSP.multiply(b.imag, power), sampleRate: x.sampleRate)
        let expected = ComplexSignalBlock(
            real: vDSP.add(x.real, vDSP.subtract(vDSP.multiply(x.real, cubicGain.real), vDSP.multiply(x.imag, cubicGain.imag))),
            imag: vDSP.add(x.imag, vDSP.add(vDSP.multiply(x.real, cubicGain.imag), vDSP.multiply(x.imag, cubicGain.real))),
            sampleRate: x.sampleRate
        )
        var memorylessFilter = VolterraFilter(kernels: memoryless)
        checks.append(VolterraSelfCheck(
            name: "M = 1 ≡ a·x + b·x|x|²",
            detail: "Memoryless cubic matches closed form (conjugate on τ₃)",
            error: relativeError(memorylessFilter.process(stream: x, blockSize: 1_024, backend: .regressionMatrix), expected),
            tolerance: 1e-5
        ))

        // 3. Block-size invariance: streaming state must make 1 × N ≡ k × (N/k).
        let kernels = VolterraKernels.syntheticPA(layout: VolterraKernelLayout(VolterraConfiguration(memoryDepth: 8, order: .third)))
        var streaming = VolterraFilter(kernels: kernels)
        let whole = streaming.process(stream: x, blockSize: x.count, backend: .vDSPFactored)
        let chunked = streaming.process(stream: x, blockSize: 333, backend: .vDSPFactored)
        checks.append(VolterraSelfCheck(
            name: "Block continuity",
            detail: "4096 samples as 1 block vs. 333-sample blocks (M = 8)",
            error: relativeError(chunked, whole),
            tolerance: 1e-5
        ))

        // 4. Symmetric storage: swapping τ₁ ↔ τ₂ addresses the same coefficient.
        let layout = VolterraKernelLayout(VolterraConfiguration(memoryDepth: 16, order: .third))
        var symmetricMismatches = 0
        for t1 in 0..<16 {
            for t2 in 0..<16 where layout.cubicIndex(t1, t2, 5) != layout.cubicIndex(t2, t1, 5) {
                symmetricMismatches += 1
            }
        }
        let lastIndexOK = layout.cubicIndex(15, 15, 15) == layout.termCount - 1
        checks.append(VolterraSelfCheck(
            name: "Kernel index map",
            detail: "τ₁↔τ₂ symmetry and dense packing at M = 16 (K = \(layout.termCount))",
            error: Float(symmetricMismatches + (lastIndexOK ? 0 : 1)),
            tolerance: 0
        ))

        // 5. GPU ≡ CPU on a deep kernel.
        if let metal {
            var gpuFilter = VolterraFilter(kernels: kernels)
            var cpuFilter = VolterraFilter(kernels: kernels)
            checks.append(VolterraSelfCheck(
                name: "Metal ≡ vDSP",
                detail: "Fused GPU kernel vs. CPU factored path (M = 8)",
                error: relativeError(
                    gpuFilter.process(stream: x, blockSize: 1_024, backend: .metalGPU, metal: metal),
                    cpuFilter.process(stream: x, blockSize: 1_024, backend: .vDSPFactored)
                ),
                tolerance: 1e-4
            ))
        }
        return checks
    }

    static func relativeError(_ value: ComplexSignalBlock, _ reference: ComplexSignalBlock) -> Float {
        let peak = max(reference.peakAmplitude, 1e-20)
        return vDSP.maximum(value.subtracting(reference).magnitude()) / peak
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
