import Accelerate
import Foundation
import Metal

/// Mirrors `VolterraGPUParams` in VolterraKernel.metal.
nonisolated struct VolterraGPUParams {
    var outputCount: UInt32
    var memoryDepth: UInt32
    var hasConstant: UInt32
    var hasCubic: UInt32
    var pairSpan: UInt32
}

/// GPU backend for the fused Volterra kernel.
///
/// Buffers use `.storageModeShared`: on Apple Silicon CPU and GPU share
/// unified memory, so writing samples into `contents()` is the upload — no
/// blit or staging copy. Buffers are grown on demand and reused between blocks.
nonisolated final class MetalVolterraEngine: @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let lock = NSLock()

    private var inputBuffer: MTLBuffer?
    private var kernelBuffer: MTLBuffer?
    private var outputBuffer: MTLBuffer?

    /// GPU-side execution time of the most recent dispatch (seconds).
    private(set) var lastGPUExecutionSeconds: Double = 0

    var deviceName: String { device.name }

    init?() {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "volterra_evaluate"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Evaluates the Volterra series on an extended block (M−1 history + N samples).
    func evaluate(extended e: ComplexSignalBlock, kernels k: VolterraKernels) -> ComplexSignalBlock {
        let layout = k.layout
        let m = layout.memoryDepth
        let n = e.count - (m - 1)
        guard n > 0 else { return ComplexSignalBlock(count: 0, sampleRate: e.sampleRate) }

        lock.lock()
        defer { lock.unlock() }

        let complexStride = 2 * MemoryLayout<Float>.stride
        guard
            let input = buffer(&inputBuffer, bytes: e.count * complexStride),
            let coefficients = buffer(&kernelBuffer, bytes: layout.termCount * complexStride),
            let output = buffer(&outputBuffer, bytes: n * complexStride),
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            // Device unavailable mid-run: fall back to the CPU path rather than fail.
            return VolterraCPUEngine.evaluateFactored(extended: e, kernels: k)
        }

        // Split → interleaved float2, written straight into shared GPU memory.
        interleave(e.real, e.imag, into: input)
        interleave(k.real, k.imag, into: coefficients)

        var params = VolterraGPUParams(
            outputCount: UInt32(n),
            memoryDepth: UInt32(m),
            hasConstant: layout.includeConstant ? 1 : 0,
            hasCubic: layout.order == .third ? 1 : 0,
            pairSpan: UInt32(layout.pairSpan)
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(coefficients, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<VolterraGPUParams>.stride, index: 3)

        let width = min(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth * 4)
        encoder.dispatchThreads(
            MTLSize(width: n, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastGPUExecutionSeconds = max(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, 0)

        // Interleaved float2 → split.
        var result = ComplexSignalBlock(count: n, sampleRate: e.sampleRate)
        result.withUnsafeMutableSplitComplex { split in
            let source = output.contents().bindMemory(to: DSPComplex.self, capacity: n)
            vDSP_ctoz(source, 2, &split, 1, vDSP_Length(n))
        }
        return result
    }

    // MARK: - Buffers

    private func buffer(_ slot: inout MTLBuffer?, bytes: Int) -> MTLBuffer? {
        if let existing = slot, existing.length >= bytes { return existing }
        // Round up to 64 KiB to avoid reallocating on small size changes.
        let rounded = (max(bytes, 1) + 0xFFFF) & ~0xFFFF
        slot = device.makeBuffer(length: rounded, options: .storageModeShared)
        return slot
    }

    private func interleave(_ real: [Float], _ imag: [Float], into buffer: MTLBuffer) {
        let destination = buffer.contents().bindMemory(to: DSPComplex.self, capacity: real.count)
        real.withUnsafeBufferPointer { r in
            imag.withUnsafeBufferPointer { i in
                var split = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: r.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: i.baseAddress!)
                )
                vDSP_ztoc(&split, 1, destination, 2, vDSP_Length(real.count))
            }
        }
    }
}
