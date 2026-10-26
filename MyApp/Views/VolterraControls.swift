import SwiftUI

/// Kernel-pruning control: cubic pairs with τ₂ − τ₁ ≤ D are kept.
/// The top of the range (D = M − 1) is stored as `nil`, the unpruned kernel,
/// so it stays "full" when the memory depth later changes.
struct PairSpanStepper: View {
    @Binding var volterra: VolterraConfiguration

    private var fullSpan: Int { volterra.memoryDepth - 1 }

    private var span: Binding<Int> {
        Binding(
            get: { min(volterra.maxPairSpan ?? fullSpan, fullSpan) },
            set: { volterra.maxPairSpan = $0 >= fullSpan ? nil : $0 }
        )
    }

    var body: some View {
        Stepper(span.wrappedValue >= fullSpan ? "Cross-term span D: full" : "Cross-term span D: \(span.wrappedValue)",
                value: span, in: 0...max(fullSpan, 0))
        .disabled(volterra.order != .third || fullSpan == 0)
        .help("Keeps only cubic terms x(n−τ₁)·x(n−τ₂)·x*(n−τ₃) with |τ₁ − τ₂| ≤ D. Fewer coefficients, faster adaptation.")
    }
}
