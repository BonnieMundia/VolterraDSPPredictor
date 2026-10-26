import Charts
import SwiftUI

/// Validated categorical slots, assigned in fixed order (never cycled).
enum CategoricalPalette {
    private static let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4]
    private static let dark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181]

    static func color(slot: Int, _ scheme: ColorScheme) -> Color {
        let table = scheme == .dark ? dark : light
        return Color(rgb: table[min(slot, table.count - 1)])
    }
}

// MARK: - Identification learning curves

struct LearningCurveChart: View {
    let runs: [IdentificationRun]
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIteration: Int?

    private var labels: [String] { runs.map(\.label) }

    var body: some View {
        Chart {
            ForEach(runs) { run in
                ForEach(run.curve) { p in
                    LineMark(
                        x: .value("Iteration n", p.iteration),
                        y: .value("A-priori NMSE (dB)", p.errorDB),
                        series: .value("Run", p.series)
                    )
                    .foregroundStyle(by: .value("Run", p.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if let selectedIteration {
                RuleMark(x: .value("Iteration n", selectedIteration))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(at: selectedIteration)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: labels,
            range: labels.indices.map { CategoricalPalette.color(slot: $0, colorScheme) }
        )
        .chartXScale(domain: 0...max(runs.flatMap(\.curve).map(\.iteration).max() ?? 1, 1))
        .chartXAxisLabel("Iteration n (samples)")
        .chartYAxisLabel("A-priori NMSE (dB)")
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selectedIteration)
    }

    private func tooltip(at iteration: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("n = \(iteration)").font(.caption.bold())
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if let point = run.curve.min(by: { abs($0.iteration - iteration) < abs($1.iteration - iteration) }) {
                    HStack(spacing: 6) {
                        Circle().fill(CategoricalPalette.color(slot: index, colorScheme)).frame(width: 8, height: 8)
                        Text(run.label)
                        Spacer(minLength: 8)
                        Text("\(point.errorDB, format: .number.precision(.fractionLength(1))) dB")
                    }
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(8)
        .frame(width: 240)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}

// MARK: - DPD convergence

/// Linearization error per closed-loop block, against the uncorrected PA baseline.
struct DPDConvergenceChart: View {
    let result: DPDResult
    @Environment(\.colorScheme) private var colorScheme

    private static let withDPD = "With DPD (per block)"
    private static let withoutDPD = "Without DPD"

    var body: some View {
        Chart {
            ForEach(result.iterations) { p in
                LineMark(
                    x: .value("Block", p.block),
                    y: .value("NMSE vs. G·u (dB)", p.nmseDB),
                    series: .value("Series", Self.withDPD)
                )
                .foregroundStyle(by: .value("Series", Self.withDPD))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("NMSE vs. G·u (dB)", Double(result.baseline.nmseDB)))
                .foregroundStyle(by: .value("Series", Self.withoutDPD))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("Without DPD \(result.baseline.nmseDB, format: .number.precision(.fractionLength(1))) dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
        .chartForegroundStyleScale([
            Self.withDPD: CategoricalPalette.color(slot: 0, colorScheme),
            Self.withoutDPD: CategoricalPalette.color(slot: 1, colorScheme)
        ])
        .chartXScale(domain: 0...max(result.iterations.last?.block ?? 1, 1))
        .chartXAxisLabel("Closed-loop block (1024 samples each)")
        .chartYAxisLabel("NMSE of y/G vs. u (dB)")
        .chartLegend(position: .top, alignment: .leading)
    }
}

// MARK: - Before/after transfer characteristics

struct BeforeAfterScatter: View {
    let before: [TransferPoint]
    let after: [TransferPoint]
    let yLabel: String
    @Environment(\.colorScheme) private var colorScheme

    private static let beforeLabel = "Without DPD"
    private static let afterLabel = "With DPD"

    var body: some View {
        Chart {
            ForEach(before) { p in
                PointMark(x: .value("|u|", Double(p.input)), y: .value(yLabel, Double(p.output)))
                    .foregroundStyle(by: .value("Series", Self.beforeLabel))
                    .symbol(by: .value("Series", Self.beforeLabel))
                    .symbolSize(10)
                    .opacity(0.5)
            }
            ForEach(after) { p in
                PointMark(x: .value("|u|", Double(p.input)), y: .value(yLabel, Double(p.output)))
                    .foregroundStyle(by: .value("Series", Self.afterLabel))
                    .symbol(by: .value("Series", Self.afterLabel))
                    .symbolSize(10)
                    .opacity(0.5)
            }
        }
        .chartForegroundStyleScale([
            Self.beforeLabel: CategoricalPalette.color(slot: 1, colorScheme),
            Self.afterLabel: CategoricalPalette.color(slot: 0, colorScheme)
        ])
        .chartXAxisLabel("Reference |u|")
        .chartYAxisLabel(yLabel)
        .chartLegend(position: .top, alignment: .leading)
    }
}

#Preview("Phase 3 charts (live data)") {
    let runs = IdentificationExperiment.sweep(IdentificationConfiguration(), signal: SignalConfiguration(), amplifier: PAConfiguration())
    let dpd = DPDLoop.run(signal: SignalConfiguration(), amplifier: PAConfiguration(), dpd: DPDConfiguration())
    return VStack(spacing: 16) {
        LearningCurveChart(runs: runs).frame(height: 260)
        DPDConvergenceChart(result: dpd).frame(height: 220)
        HStack {
            BeforeAfterScatter(before: dpd.amamBefore, after: dpd.amamAfter, yLabel: "|y| / |G|")
            BeforeAfterScatter(before: dpd.ampmBefore, after: dpd.ampmAfter, yLabel: "Phase (°)")
        }
        .frame(height: 260)
    }
    .padding()
    .frame(width: 1000)
}
