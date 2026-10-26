import SwiftUI

/// Phase 4: real-time linearization dashboard tying synthesis, PA, Volterra DPD,
/// adaptation and spectrum analysis into one live pipeline.
struct LiveDashboardView: View {
    @State private var model = LiveDashboardModel()

    var body: some View {
        NavigationSplitView {
            LiveControlPanel(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330)
        } detail: {
            Group {
                if let snapshot = model.snapshot {
                    LiveResultsView(snapshot: snapshot)
                } else {
                    ProgressView("Starting engine…")
                }
            }
            .navigationTitle("Live DPD Dashboard")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        model.isRunning ? model.stop() : model.start()
                    } label: {
                        Label(model.isRunning ? "Pause" : "Run",
                              systemImage: model.isRunning ? "pause.fill" : "play.fill")
                    }
                    Button {
                        model.resetDPD()
                    } label: {
                        Label("Reset DPD", systemImage: "arrow.counterclockwise")
                    }
                    .help("Return the predistorter to identity and restart adaptation")
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Controls

private struct LiveControlPanel: View {
    @Bindable var model: LiveDashboardModel

    var body: some View {
        Form {
            Section("DPD") {
                Toggle("Predistortion enabled", isOn: $model.configuration.dpdEnabled)
                Toggle("Adaptation running", isOn: $model.configuration.adaptationEnabled)
                    .disabled(!model.configuration.dpdEnabled)
                Picker("Order", selection: $model.configuration.volterra.order) {
                    ForEach(VolterraOrder.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Memory depth M: \(model.configuration.volterra.memoryDepth)",
                        value: $model.configuration.volterra.memoryDepth,
                        in: 1...VolterraConfiguration.maxMemoryDepth)
                LabeledContent("Coefficients K", value: "\(model.layout.termCount)")
            }

            Section("Adaptation") {
                Picker("Algorithm", selection: $model.configuration.adaptation.algorithm) {
                    ForEach(AdaptiveAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch model.configuration.adaptation.algorithm {
                case .nlms:
                    ValueSlider(
                        title: "Step size μ",
                        value: logBinding(\.adaptation.stepSize),
                        range: log10(1e-3)...log10(1.5),
                        text: String(format: "%.3g", model.configuration.adaptation.stepSize)
                    )
                case .rls, .blockRLS:
                    ValueSlider(
                        title: "Forgetting λ",
                        value: Binding(
                            get: { log10(1 - model.configuration.adaptation.forgettingFactor) },
                            set: { model.configuration.adaptation.forgettingFactor = 1 - pow(10, $0) }
                        ),
                        range: -5 ... -2,
                        text: String(format: "%.5f", model.configuration.adaptation.forgettingFactor)
                    )
                }
                Stepper(value: $model.configuration.adaptationInterval, in: LiveConfiguration.adaptationIntervalRange) {
                    LabeledContent("Adapt every", value: model.configuration.adaptationInterval == 1
                                   ? "frame" : "\(model.configuration.adaptationInterval) frames")
                }
                .help("Identification runs on one frame in N; the predistorter is applied to every sample")
                if model.configuration.adaptation.algorithm == .rls && model.layout.termCount > 300 {
                    Label("RLS is O(K²) per sample — expect a low frame rate at K = \(model.layout.termCount).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Stimulus") {
                Picker("Waveform", selection: $model.configuration.signal.kind) {
                    ForEach(SignalKind.allCases) { Text($0.rawValue).tag($0) }
                }
                ValueSlider(title: "RMS drive level", value: $model.driveLevelDB, range: -24...0,
                            text: String(format: "%.1f dBFS", model.driveLevelDB))
            }

            Section("Virtual power amplifier") {
                Picker("Model", selection: $model.configuration.amplifier.model) {
                    ForEach(PAModelKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.configuration.amplifier.model == .rapp {
                    ValueSlider(title: "Saturation V_sat", value: floatBinding(\.amplifier.saturationAmplitude),
                                range: 0.3...1.5,
                                text: String(format: "%.2f", model.configuration.amplifier.saturationAmplitude))
                    ValueSlider(title: "Knee smoothness p", value: floatBinding(\.amplifier.smoothness),
                                range: 0.5...8,
                                text: String(format: "%.2f", model.configuration.amplifier.smoothness))
                    ValueSlider(
                        title: "AM/PM max phase",
                        value: Binding(
                            get: { Double(model.configuration.amplifier.amPMMaxPhase) * 180 / .pi },
                            set: { model.configuration.amplifier.amPMMaxPhase = Float($0 * .pi / 180) }
                        ),
                        range: 0...90,
                        text: String(format: "%.1f°", Double(model.configuration.amplifier.amPMMaxPhase) * 180 / .pi)
                    )
                }
                Toggle("Memory effects", isOn: $model.configuration.amplifier.memoryEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private func floatBinding(_ keyPath: WritableKeyPath<LiveConfiguration, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model.configuration[keyPath: keyPath]) },
            set: { model.configuration[keyPath: keyPath] = Float($0) }
        )
    }

    /// Slider operating on log₁₀ of a Double parameter.
    private func logBinding(_ keyPath: WritableKeyPath<LiveConfiguration, Double>) -> Binding<Double> {
        Binding(
            get: { log10(max(model.configuration[keyPath: keyPath], 1e-12)) },
            set: { model.configuration[keyPath: keyPath] = pow(10, $0) }
        )
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(text)
        }
    }
}

// MARK: - Results

private struct LiveResultsView: View {
    let snapshot: LiveSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LiveMetricsRow(snapshot: snapshot)

                LivePanel(title: "Power spectral density — Welch, vDSP_fft_zrip (1024-pt, Hann, 50 % overlap)") {
                    SpectrumChart(snapshot: snapshot).frame(height: 320)
                }

                // Plain stack, not Grid: Grid measures its cells in several passes, and each
                // pass re-lays-out the charts (measured: 54 → 32 ms per live update).
                HStack(alignment: .top, spacing: 16) {
                    LivePanel(title: "Instantaneous error — convergence over iterations") {
                        ErrorConvergenceChart(history: snapshot.errorHistory).frame(height: 300)
                    }
                    LivePanel(title: "Constellation (matched filter, last \(plottedSymbols) symbols)") {
                        if snapshot.constellationWithDPD.isEmpty {
                            ContentUnavailableView("QAM only", systemImage: "circle.grid.cross",
                                                   description: Text("Select a QAM waveform to view the constellation."))
                                .frame(height: 300)
                        } else {
                            ConstellationChart(withoutDPD: snapshot.constellationWithoutDPD,
                                               withDPD: snapshot.constellationWithDPD,
                                               gridExtent: snapshot.constellationExtent)
                                .frame(height: 300)
                        }
                    }
                    .frame(width: 380)
                }

                LivePanel(title: "Per-stage profile (smoothed)") {
                    StageProfileChart(snapshot: snapshot).frame(height: 180)
                }
            }
            .padding(16)
        }
    }

    private var plottedSymbols: Int {
        min(snapshot.constellationWithDPD.count, ConstellationChart.plottedSymbolsPerPath)
    }
}

private struct LiveMetricsRow: View {
    let snapshot: LiveSnapshot

    var body: some View {
        let aclrGain = snapshot.aclrWithoutDPD.worstDBc - snapshot.aclrWithDPD.worstDBc
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            LiveTile(title: "ACLR (worst adjacent)",
                     value: "\(f(snapshot.aclrWithoutDPD.worstDBc)) → \(f(snapshot.aclrWithDPD.worstDBc))",
                     unit: "dBc",
                     caption: "Δ \(f(aclrGain)) dB · ideal \(f(snapshot.aclrIdeal.worstDBc)) dBc")
            LiveTile(title: "NMSE vs. G·u",
                     value: "\(f(snapshot.nmseWithoutDPD)) → \(f(snapshot.nmseWithDPD))",
                     unit: "dB",
                     caption: nil)
            LiveTile(title: "Symbol EVM",
                     value: evmText,
                     unit: "%",
                     caption: nil)
            LiveTile(title: "Throughput",
                     value: snapshot.throughputMSps.formatted(.number.precision(.significantDigits(3))),
                     unit: "MS/s",
                     caption: "Real-time factor \(snapshot.realTimeFactor.formatted(.number.precision(.significantDigits(2))))× of \(Int(snapshot.sampleRate / 1e6)) MS/s")
            LiveTile(title: "DPD",
                     value: snapshot.status.rawValue,
                     unit: "",
                     caption: "K = \(snapshot.termCount) · \(snapshot.backend.rawValue)" +
                        (snapshot.divergenceResets > 0 ? " · \(snapshot.divergenceResets) resets" : ""),
                     systemImage: statusIcon)
        }
    }

    private var evmText: String {
        guard let before = snapshot.symbolEVMWithoutDPD, let after = snapshot.symbolEVMWithDPD else { return "—" }
        return "\(f(before, 2)) → \(f(after, 2))"
    }

    private var statusIcon: String {
        switch snapshot.status {
        case .adapting: "waveform.path.ecg"
        case .frozen: "snowflake"
        case .bypassed: "pause.circle"
        case .recovered: "exclamationmark.triangle"
        }
    }

    private func f(_ v: Double, _ digits: Int = 1) -> String {
        v.isFinite ? v.formatted(.number.precision(.fractionLength(digits))) : "—"
    }
}

private struct LiveTile: View {
    let title: String
    let value: String
    let unit: String
    let caption: String?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(value).font(.title3.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LiveSurface.fill, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct LivePanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiveSurface.fill, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Card fill for live panels and tiles. A plain semantic color, not the hierarchical
/// `.background.secondary` style, which is re-resolved and composited on every live
/// update (measured +7.5 ms per chart panel per frame).
private enum LiveSurface {
    static let fill = Color(nsColor: .quaternarySystemFill)
}

#Preview {
    LiveDashboardView()
        .frame(width: 1400, height: 1000)
}

#Preview("Results after 60 frames") {
    var core = LinearizationCore(configuration: LiveConfiguration())
    var snapshot = core.advance()
    for _ in 0..<60 { snapshot = core.advance() }
    return LiveResultsView(snapshot: snapshot)
        .frame(width: 1100, height: 1150)
}
