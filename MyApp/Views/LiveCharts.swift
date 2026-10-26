import Charts
import SwiftUI

/// Fixed series identity shared by every live chart.
enum LiveSeries {
    static let ideal = "Ideal input u"
    static let withoutDPD = "PA without DPD"
    static let withDPD = "PA with DPD"

    /// Fixed slot per path, independent of which subset a chart draws.
    private static func slot(_ series: String) -> Int {
        switch series {
        case withDPD: 0
        case withoutDPD: 1
        default: 2
        }
    }

    /// Color scale domain limited to the series a chart actually plots, so the
    /// legend never lists absent series (and merges with a matching symbol scale).
    static let allPaths = [withDPD, withoutDPD, ideal]
    static let paPaths = [withDPD, withoutDPD]

    static func colors(for series: [String], _ scheme: ColorScheme) -> [Color] {
        series.map { CategoricalPalette.color(slot: slot($0), scheme) }
    }
}

/// Flat point for vectorized plots (`LinePlot` / `PointPlot`). A whole series renders
/// as one plot instead of one mark per point — profiling showed per-mark chart
/// layout, not DSP, dominated the main thread at ~3 700 marks per frame.
struct PlotPoint {
    let x: Double
    let y: Double
    let series: String
}

// MARK: - Spectrum

/// Welch PSD of all three paths with main/adjacent channel bands shaded.
struct SpectrumChart: View {
    let snapshot: LiveSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedFrequency: Double?

    private struct Band: Identifiable {
        let id: String
        let low: Double
        let high: Double
    }

    private var bands: [Band] {
        let plan = snapshot.channelPlan
        let half = plan.bandwidth / 2e6, spacing = plan.spacing / 1e6
        let nyquist = snapshot.sampleRate / 2e6
        return [
            Band(id: "Adj L", low: max(-spacing - half, -nyquist), high: -spacing + half),
            Band(id: "Main", low: -half, high: half),
            Band(id: "Adj U", low: spacing - half, high: min(spacing + half, nyquist))
        ]
    }

    var body: some View {
        Chart {
            ForEach(bands) { band in
                RectangleMark(
                    xStart: .value("Frequency (MHz)", band.low),
                    xEnd: .value("Frequency (MHz)", band.high),
                    yStart: .value("PSD", -100.0),
                    yEnd: .value("PSD", 10.0)
                )
                .foregroundStyle(.gray.opacity(band.id == "Main" ? 0.10 : 0.05))
                .annotation(position: .overlay, alignment: .top) {
                    Text(band.id).font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                }
            }

            LinePlot(
                points,
                x: .value("Frequency (MHz)", \.x),
                y: .value("PSD", \.y),
                series: .value("Path", \.series)
            )
            .foregroundStyle(by: .value("Path", \.series))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            if let selectedFrequency, let bin = nearestBin(to: selectedFrequency) {
                RuleMark(x: .value("Frequency (MHz)", bin.frequencyMHz))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(bin)
                    }
            }
        }
        .chartForegroundStyleScale(domain: LiveSeries.allPaths, range: LiveSeries.colors(for: LiveSeries.allPaths, colorScheme))
        .chartYScale(domain: -100...10)
        .chartXScale(domain: -snapshot.sampleRate / 2e6 ... snapshot.sampleRate / 2e6)
        .chartXAxisLabel("Frequency offset (MHz)")
        .chartYAxisLabel("PSD (dB rel. in-band)")
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selectedFrequency)
    }

    /// Draw order: ideal underneath, then without-DPD, then with-DPD on top.
    private var points: [PlotPoint] {
        let s = snapshot.spectrum
        return s.map { PlotPoint(x: $0.frequencyMHz, y: max($0.idealDB, -100), series: LiveSeries.ideal) }
            + s.map { PlotPoint(x: $0.frequencyMHz, y: max($0.withoutDPDDB, -100), series: LiveSeries.withoutDPD) }
            + s.map { PlotPoint(x: $0.frequencyMHz, y: max($0.withDPDDB, -100), series: LiveSeries.withDPD) }
    }

    private func nearestBin(to f: Double) -> SpectrumBin? {
        snapshot.spectrum.min { abs($0.frequencyMHz - f) < abs($1.frequencyMHz - f) }
    }

    private func tooltip(_ bin: SpectrumBin) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(bin.frequencyMHz, format: .number.precision(.fractionLength(2))) MHz").font(.caption.bold())
            row(LiveSeries.withDPD, bin.withDPDDB, slot: 0)
            row(LiveSeries.withoutDPD, bin.withoutDPDDB, slot: 1)
            row(LiveSeries.ideal, bin.idealDB, slot: 2)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(8)
        .frame(width: 220)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private func row(_ label: String, _ value: Double, slot: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(CategoricalPalette.color(slot: slot, colorScheme)).frame(width: 8, height: 8)
            Text(label)
            Spacer(minLength: 8)
            Text("\(value, format: .number.precision(.fractionLength(1))) dB")
        }
    }
}

// MARK: - Error convergence

/// Instantaneous normalized error |y/G − u|² / P_u over the iteration axis.
struct ErrorConvergenceChart: View {
    let history: [ErrorHistoryPoint]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Chart {
            LinePlot(
                points,
                x: .value("Iteration n", \.x),
                y: .value("Error (dB)", \.y),
                series: .value("Path", \.series)
            )
            .foregroundStyle(by: .value("Path", \.series))
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartForegroundStyleScale(domain: LiveSeries.paPaths, range: LiveSeries.colors(for: LiveSeries.paPaths, colorScheme))
        .chartYScale(domain: -60...0)
        .chartXScale(domain: (history.first?.iteration ?? 0)...max(history.last?.iteration ?? 1, (history.first?.iteration ?? 0) + 1))
        .chartXAxisLabel("Iteration n (samples)")
        .chartYAxisLabel("|y/G − u|² / Pᵤ (dB)")
        .chartLegend(position: .top, alignment: .leading)
    }

    /// Points drawn per path. The history holds 480 bins; averaging adjacent bins keeps
    /// the trace's shape (unlike decimation, which can drop spikes) at half the marks.
    static let maxPlottedPoints = 240

    private var points: [PlotPoint] {
        let bin = max(1, (history.count + Self.maxPlottedPoints - 1) / Self.maxPlottedPoints)
        let groups = stride(from: 0, to: history.count, by: bin).map { history[$0..<min($0 + bin, history.count)] }
        func averaged(_ value: KeyPath<ErrorHistoryPoint, Double>, series: String) -> [PlotPoint] {
            groups.compactMap { group in
                guard let last = group.last else { return nil }
                let mean = group.reduce(0) { $0 + $1[keyPath: value] } / Double(group.count)
                return PlotPoint(x: Double(last.iteration), y: mean, series: series)
            }
        }
        return averaged(\.withoutDPDDB, series: LiveSeries.withoutDPD) + averaged(\.withDPDDB, series: LiveSeries.withDPD)
    }
}

// MARK: - Constellation

struct ConstellationChart: View {
    let withoutDPD: [IQPoint]
    let withDPD: [IQPoint]
    let gridExtent: Double
    @Environment(\.colorScheme) private var colorScheme

    /// Symbols drawn per path. EVM still uses the core's full symbol buffer; symbol
    /// marks are the costliest per-point chart content, and 256 per path halves the
    /// redraw time while keeping every 16/64-QAM cluster well populated.
    static let plottedSymbolsPerPath = 256

    var body: some View {
        Chart {
            // Key-path modifiers first, then constant ones (vectorized-plot requirement).
            PointPlot(points, x: .value("I", \.x), y: .value("Q", \.y))
                .foregroundStyle(by: .value("Path", \.series))
                .symbol(by: .value("Path", \.series))
                .symbolSize(12)
                .opacity(0.75)
        }
        .chartForegroundStyleScale(domain: LiveSeries.paPaths, range: LiveSeries.colors(for: LiveSeries.paPaths, colorScheme))
        .chartSymbolScale(domain: LiveSeries.paPaths, range: [BasicChartSymbolShape.circle, .cross])
        .chartXScale(domain: -gridExtent...gridExtent)
        .chartYScale(domain: -gridExtent...gridExtent)
        .chartXAxisLabel("In-phase")
        .chartYAxisLabel("Quadrature")
        .chartLegend(position: .top, alignment: .leading)
        .aspectRatio(1, contentMode: .fit)
    }

    private var points: [PlotPoint] {
        let n = Self.plottedSymbolsPerPath
        return withoutDPD.suffix(n).map { PlotPoint(x: Double($0.i), y: Double($0.q), series: LiveSeries.withoutDPD) }
            + withDPD.suffix(n).map { PlotPoint(x: Double($0.i), y: Double($0.q), series: LiveSeries.withDPD) }
    }
}

// MARK: - Stage profile

struct StageProfileChart: View {
    let snapshot: LiveSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Chart(ProcessingStage.allCases) { stage in
            let ms = (snapshot.stageSeconds[stage] ?? 0) * 1000
            BarMark(x: .value("ms / frame", ms), y: .value("Stage", stage.rawValue))
                .foregroundStyle(CategoricalPalette.color(slot: 0, colorScheme))
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(ms, format: .number.precision(.fractionLength(2))) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxisLabel("Milliseconds per \(snapshot.frameSize)-sample frame")
    }
}
