import SwiftUI

/// Phase 1 dashboard: stimulus + virtual PA controls on the left,
/// distortion metrics and clean-vs-distorted waveform profiles on the right.
struct Phase1DashboardView: View {
    @State private var model = Phase1SimulationModel()

    var body: some View {
        NavigationSplitView {
            Phase1ControlPanel(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            Group {
                if let result = model.result {
                    Phase1ResultsView(result: result)
                } else {
                    ProgressView("Synthesizing…")
                }
            }
            .navigationTitle("VolterraDSPPredictor — Phase 1")
            .toolbar {
                ToolbarItem {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        // Re-run whenever any input changes; the short sleep debounces slider drags
        // and `.task(id:)` cancels the superseded run automatically.
        .task(id: model.inputs) {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await model.simulate()
        }
    }
}

// MARK: - Results

private struct Phase1ResultsView: View {
    let result: Phase1SimulationResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MetricsStrip(result: result)

                Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                    GridRow {
                        ChartPanel(title: "Envelope — clean vs. distorted") {
                            TimeDomainChart(samples: result.timeSeries, quantity: .envelope)
                        }
                        ChartPanel(title: "In-phase waveform") {
                            TimeDomainChart(samples: result.timeSeries, quantity: .inPhase)
                        }
                    }
                    GridRow {
                        ChartPanel(title: "AM/AM conversion") {
                            TransferChart(
                                scatter: result.amamScatter,
                                curve: result.amamCurve,
                                xLabel: "Input |x|",
                                yLabel: "Output |y|"
                            )
                        }
                        ChartPanel(title: "AM/PM conversion") {
                            TransferChart(
                                scatter: result.ampmScatter,
                                curve: result.ampmCurve,
                                xLabel: "Input |x|",
                                yLabel: "Phase shift (°)"
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct ChartPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content.frame(minHeight: 240)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MetricsStrip: View {
    let result: Phase1SimulationResult

    private var m: DistortionMetrics { result.metrics }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { tiles }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) { tiles }
        }
    }

    @ViewBuilder private var tiles: some View {
        MetricTile(title: "NMSE (vs. linear)", value: m.nmseDB.formatted(.number.precision(.fractionLength(1))), unit: "dB")
        MetricTile(title: "Waveform EVM", value: m.evmPercent.formatted(.number.precision(.fractionLength(2))), unit: "%")
        MetricTile(title: "PAPR in → out", value: "\(m.inputPAPRdB.formatted(.number.precision(.fractionLength(2)))) → \(m.outputPAPRdB.formatted(.number.precision(.fractionLength(2))))", unit: "dB")
        MetricTile(title: "Linear gain |ĝ|", value: (20 * log10(max(m.linearGainMagnitude, 1e-9))).formatted(.number.precision(.fractionLength(2))), unit: "dB")
        MetricTile(title: "Avg. compression", value: m.averageCompressionDB.formatted(.number.precision(.fractionLength(2))), unit: "dB")
        MetricTile(
            title: "PA throughput",
            value: result.amplifierThroughputMSps.formatted(.number.precision(.fractionLength(1))),
            unit: "MS/s",
            caption: "\(result.clean.count) samples · \(result.blockSize)-sample blocks"
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Phase1DashboardView()
        .frame(width: 1280, height: 860)
}
