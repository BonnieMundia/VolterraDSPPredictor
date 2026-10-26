import Charts
import SwiftUI

/// Shared series styling: one fixed hue per entity, used consistently across all panels.
enum SeriesStyle {
    static let clean = "Clean input"
    static let distorted = "PA output ÷ ĝ"
    static let measured = "Measured (PA output)"
    static let model = "Static model curve"

    static let cleanColor = Color.blue
    static let distortedColor = Color.orange
}

/// Flattened point for multi-series line charts.
private struct SeriesPoint: Identifiable {
    let id: String
    let series: String
    let x: Double
    let y: Double
}

// MARK: - Time-domain overlay

/// Clean vs. gain-normalized PA output over the first few hundred samples.
/// Hovering shows a crosshair with both values at the selected instant.
struct TimeDomainChart: View {
    enum Quantity: String {
        case envelope = "Envelope |x|"
        case inPhase = "In-phase (I)"
    }

    let samples: [TimeSample]
    let quantity: Quantity

    @State private var selectedTime: Double?

    private var points: [SeriesPoint] {
        samples.flatMap { s -> [SeriesPoint] in
            let (clean, distorted): (Float, Float) = switch quantity {
            case .envelope: (s.cleanEnvelope, s.distortedEnvelope)
            case .inPhase: (s.cleanInPhase, s.distortedInPhase)
            }
            return [
                SeriesPoint(id: "c\(s.id)", series: SeriesStyle.clean, x: s.timeMicroseconds, y: Double(clean)),
                SeriesPoint(id: "d\(s.id)", series: SeriesStyle.distorted, x: s.timeMicroseconds, y: Double(distorted))
            ]
        }
    }

    /// Nearest sample to the hovered time.
    private var selectedSample: TimeSample? {
        guard let selectedTime, let first = samples.first, samples.count > 1 else { return nil }
        let dt = samples[1].timeMicroseconds - first.timeMicroseconds
        let index = Int(((selectedTime - first.timeMicroseconds) / dt).rounded())
        return samples.indices.contains(index) ? samples[index] : nil
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Time (µs)", p.x),
                    y: .value(quantity.rawValue, p.y),
                    series: .value("Signal", p.series)
                )
                .foregroundStyle(by: .value("Signal", p.series))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }

            if let sample = selectedSample {
                RuleMark(x: .value("Time (µs)", sample.timeMicroseconds))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(for: sample)
                    }
            }
        }
        .chartForegroundStyleScale([
            SeriesStyle.clean: SeriesStyle.cleanColor,
            SeriesStyle.distorted: SeriesStyle.distortedColor
        ])
        .chartXAxisLabel("Time (µs)")
        .chartYAxisLabel(quantity.rawValue)
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selectedTime)
    }

    private func tooltip(for sample: TimeSample) -> some View {
        let (clean, distorted): (Float, Float) = switch quantity {
        case .envelope: (sample.cleanEnvelope, sample.distortedEnvelope)
        case .inPhase: (sample.cleanInPhase, sample.distortedInPhase)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(sample.timeMicroseconds, format: .number.precision(.fractionLength(3))) µs")
                .font(.caption.bold())
            HStack(spacing: 4) {
                Circle().fill(SeriesStyle.cleanColor).frame(width: 8, height: 8)
                Text("Clean \(clean, format: .number.precision(.fractionLength(4)))")
            }
            HStack(spacing: 4) {
                Circle().fill(SeriesStyle.distortedColor).frame(width: 8, height: 8)
                Text("PA \(distorted, format: .number.precision(.fractionLength(4)))")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}

// MARK: - Transfer characteristics

/// Measured AM/AM or AM/PM scatter overlaid with the static model curve.
/// Spread of the scatter around the curve is caused by PA memory.
struct TransferChart: View {
    let scatter: [TransferPoint]
    let curve: [TransferPoint]
    let xLabel: String
    let yLabel: String

    var body: some View {
        Chart {
            ForEach(scatter) { p in
                PointMark(
                    x: .value(xLabel, Double(p.input)),
                    y: .value(yLabel, Double(p.output))
                )
                .foregroundStyle(by: .value("Series", SeriesStyle.measured))
                .symbolSize(8)
                .opacity(0.45)
            }
            ForEach(curve) { p in
                LineMark(
                    x: .value(xLabel, Double(p.input)),
                    y: .value(yLabel, Double(p.output)),
                    series: .value("Series", SeriesStyle.model)
                )
                .foregroundStyle(by: .value("Series", SeriesStyle.model))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartForegroundStyleScale([
            SeriesStyle.measured: SeriesStyle.distortedColor,
            SeriesStyle.model: SeriesStyle.cleanColor
        ])
        .chartXAxisLabel(xLabel)
        .chartYAxisLabel(yLabel)
        .chartLegend(position: .top, alignment: .leading)
    }
}
