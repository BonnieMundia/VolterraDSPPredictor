import Accelerate
import Charts
import SwiftUI

extension Color {
    /// sRGB color from a 0xRRGGBB literal.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// Fixed categorical slot per backend (validated for CVD separation in light and
/// dark), plus a distinct symbol so identity never rests on color alone.
enum BackendStyle {
    static func color(_ backend: VolterraBackend, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        return switch backend {
        case .scalarReference: Color(rgb: dark ? 0x3987E5 : 0x2A78D6)   // blue
        case .vDSPFactored: Color(rgb: dark ? 0xD95926 : 0xEB6834)      // orange
        case .regressionMatrix: Color(rgb: dark ? 0x199E70 : 0x1BAF7A)  // aqua
        case .metalGPU: Color(rgb: dark ? 0xC98500 : 0xEDA100)          // yellow
        }
    }

    static func symbol(_ backend: VolterraBackend) -> BasicChartSymbolShape {
        switch backend {
        case .scalarReference: .circle
        case .vDSPFactored: .square
        case .regressionMatrix: .triangle
        case .metalGPU: .diamond
        }
    }
}

// MARK: - Throughput vs memory depth

struct ThroughputChart: View {
    let entries: [VolterraBenchmarkEntry]
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDepth: Int?

    private var backends: [VolterraBackend] {
        VolterraBackend.allCases.filter { b in entries.contains { $0.backend == b } }
    }

    var body: some View {
        Chart {
            ForEach(entries) { e in
                LineMark(
                    x: .value("Memory depth M", e.memoryDepth),
                    y: .value("Throughput (MS/s)", e.throughputMSps),
                    series: .value("Backend", e.backend.rawValue)
                )
                .foregroundStyle(by: .value("Backend", e.backend.rawValue))
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Memory depth M", e.memoryDepth),
                    y: .value("Throughput (MS/s)", e.throughputMSps)
                )
                .foregroundStyle(by: .value("Backend", e.backend.rawValue))
                .symbol(by: .value("Backend", e.backend.rawValue))
                .symbolSize(48)
            }

            if let selectedDepth {
                RuleMark(x: .value("Memory depth M", selectedDepth))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(depth: selectedDepth)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: backends.map(\.rawValue),
            range: backends.map { BackendStyle.color($0, colorScheme) }
        )
        .chartSymbolScale(
            domain: backends.map(\.rawValue),
            range: backends.map { BackendStyle.symbol($0) }
        )
        .chartYScale(type: .log)
        .chartXScale(domain: 0...(entries.map(\.memoryDepth).max() ?? 16) + 1)
        .chartXAxisLabel("Memory depth M")
        .chartYAxisLabel("Throughput (MS/s, log)")
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selectedDepth)
    }

    private func tooltip(depth: Int) -> some View {
        let rows = entries.filter { $0.memoryDepth == depth }.sorted { $0.throughputMSps > $1.throughputMSps }
        return VStack(alignment: .leading, spacing: 3) {
            Text("M = \(depth) · K = \(rows.first?.termCount ?? 0)").font(.caption.bold())
            ForEach(rows) { e in
                HStack(spacing: 6) {
                    Circle().fill(BackendStyle.color(e.backend, colorScheme)).frame(width: 8, height: 8)
                    Text(e.backend.rawValue)
                    Spacer(minLength: 8)
                    Text("\(e.throughputMSps, format: .number.precision(.significantDigits(3))) MS/s")
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(8)
        .frame(width: 250)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}

// MARK: - Cubic kernel energy map

/// E(τ₁, τ₂) = 10·log₁₀ Σ_{τ₃} |h₃(τ₁, τ₂; τ₃)|², shown on the full square so the
/// τ₁↔τ₂ mirror symmetry exploited by the storage layout is visible.
struct KernelEnergyMap: View {
    let kernels: VolterraKernels
    @Environment(\.colorScheme) private var colorScheme

    private struct Cell: Identifiable {
        var id: Int { tau1 * 64 + tau2 }
        let tau1: Int
        let tau2: Int
        let energyDB: Double
    }

    private var cells: [Cell] {
        let layout = kernels.layout
        guard layout.order == .third else { return [] }
        let m = layout.memoryDepth
        var result: [Cell] = []
        for a in 0..<m {
            for b in 0..<m {
                var energy: Float = 0
                for c in 0..<m {
                    let h = kernels.cubic(a, b, c)
                    energy += h.real * h.real + h.imag * h.imag
                }
                result.append(Cell(tau1: a, tau2: b, energyDB: Double(10 * log10(max(energy, 1e-12)))))
            }
        }
        return result
    }

    var body: some View {
        let cells = cells
        if cells.isEmpty {
            ContentUnavailableView("No cubic kernel", systemImage: "square.grid.3x3",
                                   description: Text("Select P = 3 to view h₃ energy."))
        } else {
            Chart(cells) { cell in
                // String values give discrete (band) axes, one cell per tap.
                RectangleMark(
                    x: .value("τ₁", "\(cell.tau1)"),
                    y: .value("τ₂", "\(cell.tau2)"),
                    width: .ratio(0.92),
                    height: .ratio(0.92)
                )
                .foregroundStyle(by: .value("Energy (dB)", cell.energyDB))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(range: Gradient(colors: colorScheme == .dark
                ? [Color(rgb: 0x0D366B), Color(rgb: 0x86B6EF)]
                : [Color(rgb: 0xCDE2FB), Color(rgb: 0x104281)]))
            .chartXAxisLabel("τ₁")
            .chartYAxisLabel("τ₂")
            .chartLegend(position: .trailing)
            .aspectRatio(1.15, contentMode: .fit)
        }
    }
}
