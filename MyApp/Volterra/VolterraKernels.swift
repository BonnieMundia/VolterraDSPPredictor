import Accelerate
import Foundation

/// Highest odd nonlinearity order kept by the engine.
///
/// For a band-pass PA modelled at complex baseband only odd-order products
/// with one more unconjugated than conjugated factor land back in the carrier
/// zone, so the in-band kernels are h₁(τ) and h₃(τ₁, τ₂; τ₃):
///
///     y(n) = h₀ + Σ_τ h₁(τ)·x(n−τ)
///               + Σ_{τ₁≤τ₂} Σ_{τ₃} h₃(τ₁,τ₂;τ₃)·x(n−τ₁)·x(n−τ₂)·x*(n−τ₃)
///
/// Even-order terms (h₂) generate only DC and 2f_c products, which are
/// filtered out by the PA output network and vanish in the baseband equivalent.
nonisolated enum VolterraOrder: Int, CaseIterable, Identifiable, Sendable {
    case first = 1
    case third = 3

    var id: Int { rawValue }
    var label: String { self == .first ? "P = 1 (linear FIR)" : "P = 3 (cubic)" }
}

nonisolated struct VolterraConfiguration: Sendable, Equatable, Hashable {
    static let maxMemoryDepth = 16

    /// Number of taps per dimension, τ ∈ 0 ..< M.
    var memoryDepth: Int = 4
    var order: VolterraOrder = .third
    /// Include the constant (DC) term h₀.
    var includeConstant: Bool = false
}

/// Index map from multidimensional kernel coordinates to a flat coefficient vector.
///
/// Storage order (also used by the Metal kernel and the regression matrix columns):
///
///     [h₀]  [h₁(0) … h₁(M−1)]  [h₃(τ₁,τ₂;τ₃) for τ₁ in 0..<M, τ₂ in τ₁..<M, τ₃ in 0..<M]
///
/// Exploiting the τ₁↔τ₂ symmetry stores M²(M+1)/2 cubic coefficients instead of M³.
nonisolated struct VolterraKernelLayout: Sendable, Equatable, Hashable {
    let memoryDepth: Int
    let order: VolterraOrder
    let includeConstant: Bool

    init(_ configuration: VolterraConfiguration) {
        precondition((1...VolterraConfiguration.maxMemoryDepth).contains(configuration.memoryDepth),
                     "Memory depth must be in 1...\(VolterraConfiguration.maxMemoryDepth)")
        memoryDepth = configuration.memoryDepth
        order = configuration.order
        includeConstant = configuration.includeConstant
    }

    var constantCount: Int { includeConstant ? 1 : 0 }
    var linearCount: Int { memoryDepth }
    /// Number of unordered (τ₁ ≤ τ₂) pairs.
    var cubicPairCount: Int { order == .third ? memoryDepth * (memoryDepth + 1) / 2 : 0 }
    var cubicCount: Int { cubicPairCount * memoryDepth }
    var termCount: Int { constantCount + linearCount + cubicCount }

    var linearOffset: Int { constantCount }
    var cubicOffset: Int { constantCount + linearCount }

    /// Coefficient count without symmetry reduction (full M³ tensor).
    var fullTensorTermCount: Int {
        constantCount + linearCount + (order == .third ? memoryDepth * memoryDepth * memoryDepth : 0)
    }

    func linearIndex(_ tau: Int) -> Int {
        precondition((0..<memoryDepth).contains(tau))
        return linearOffset + tau
    }

    /// Flat index of the (τ₁ ≤ τ₂) pair in row-major upper-triangular order.
    func pairIndex(_ tau1: Int, _ tau2: Int) -> Int {
        let a = min(tau1, tau2), b = max(tau1, tau2)
        // Row a starts after Σ_{i<a} (M − i) = a·M − a(a−1)/2 entries.
        return a * memoryDepth - a * (a - 1) / 2 + (b - a)
    }

    /// Flat index of h₃(τ₁, τ₂; τ₃). τ₁ and τ₂ may be given in either order.
    func cubicIndex(_ tau1: Int, _ tau2: Int, _ tau3: Int) -> Int {
        precondition(order == .third, "Layout has no cubic kernel")
        precondition([tau1, tau2, tau3].allSatisfy { (0..<memoryDepth).contains($0) })
        return cubicOffset + pairIndex(tau1, tau2) * memoryDepth + tau3
    }

    /// (τ₁, τ₂) for every pair, in storage order.
    var pairs: [(Int, Int)] {
        guard order == .third else { return [] }
        var result: [(Int, Int)] = []
        result.reserveCapacity(cubicPairCount)
        for a in 0..<memoryDepth {
            for b in a..<memoryDepth { result.append((a, b)) }
        }
        return result
    }
}

/// Complex Volterra coefficients in split layout.
nonisolated struct VolterraKernels: Sendable, Equatable {
    let layout: VolterraKernelLayout
    var real: [Float]
    var imag: [Float]

    init(layout: VolterraKernelLayout) {
        self.layout = layout
        real = [Float](repeating: 0, count: layout.termCount)
        imag = [Float](repeating: 0, count: layout.termCount)
    }

    /// Kernel storage in bytes (split complex Float).
    var byteSize: Int { layout.termCount * 2 * MemoryLayout<Float>.stride }

    subscript(index: Int) -> DSPComplex {
        get { DSPComplex(real: real[index], imag: imag[index]) }
        set {
            real[index] = newValue.real
            imag[index] = newValue.imag
        }
    }

    var constant: DSPComplex {
        get { layout.includeConstant ? self[0] : DSPComplex(real: 0, imag: 0) }
        set {
            precondition(layout.includeConstant, "Layout has no constant term")
            self[0] = newValue
        }
    }

    func linear(_ tau: Int) -> DSPComplex { self[layout.linearIndex(tau)] }
    mutating func setLinear(_ tau: Int, _ value: DSPComplex) { self[layout.linearIndex(tau)] = value }

    func cubic(_ t1: Int, _ t2: Int, _ t3: Int) -> DSPComplex { self[layout.cubicIndex(t1, t2, t3)] }
    mutating func setCubic(_ t1: Int, _ t2: Int, _ t3: Int, _ value: DSPComplex) {
        self[layout.cubicIndex(t1, t2, t3)] = value
    }

    /// Taps h₃(τ₁, τ₂; ·) for one pair, as split arrays of length M.
    func cubicSlice(pair: Int) -> (real: ArraySlice<Float>, imag: ArraySlice<Float>) {
        let start = layout.cubicOffset + pair * layout.memoryDepth
        let range = start..<(start + layout.memoryDepth)
        return (real[range], imag[range])
    }

    /// Physically plausible synthetic PA kernel for benchmarking and engine
    /// verification before identification exists (Phase 3): unit main tap,
    /// exponentially decaying memory, and a compressive cubic main term.
    static func syntheticPA(layout: VolterraKernelLayout, seed: UInt64 = 0xB0B_CAFE) -> VolterraKernels {
        var k = VolterraKernels(layout: layout)
        var rng = Xoshiro256StarStar(seed: seed)
        func randomPhasor(_ magnitude: Float) -> DSPComplex {
            let theta = Float.random(in: -.pi ... .pi, using: &rng)
            return DSPComplex(real: magnitude * cos(theta), imag: magnitude * sin(theta))
        }

        if layout.includeConstant { k.constant = DSPComplex(real: 1e-3, imag: -5e-4) }

        k.setLinear(0, DSPComplex(real: 1, imag: 0))
        for tau in 1..<max(layout.memoryDepth, 1) {
            k.setLinear(tau, randomPhasor(0.25 * pow(0.6, Float(tau))))
        }

        if layout.order == .third {
            for (a, b) in layout.pairs {
                for c in 0..<layout.memoryDepth {
                    let decay = pow(0.45, Float(a + b + c))
                    k.setCubic(a, b, c, randomPhasor(0.12 * decay))
                }
            }
            // AM/AM compression with AM/PM rotation on the memoryless diagonal.
            k.setCubic(0, 0, 0, DSPComplex(real: -0.35, imag: 0.12))
        }
        return k
    }
}
