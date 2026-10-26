import SwiftUI

/// Phase 3 workbench: adaptive kernel identification and closed-loop DPD.
struct Phase3DPDView: View {
    @State private var model = Phase3Model()

    var body: some View {
        NavigationSplitView {
            Phase3ControlPanel(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    IdentificationPanel(runs: model.identificationRuns)
                    if let result = model.dpdResult {
                        DPDPanel(result: result)
                    } else {
                        Phase3Panel(title: "Digital pre-distortion") {
                            ContentUnavailableView(
                                "DPD not run yet",
                                systemImage: "arrow.triangle.2.circlepath",
                                description: Text("Run the DPD loop to linearize the virtual PA with the indirect learning architecture.")
                            )
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Adaptive DPD — Phase 3")
            .toolbar {
                ToolbarItem {
                    if let activity = model.activity {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(activity.rawValue).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Controls

private struct Phase3ControlPanel: View {
    @Bindable var model: Phase3Model

    private static let sampleCounts = [4_096, 8_192, 16_384, 32_768, 65_536]

    var body: some View {
        Form {
            Section("Volterra model") {
                Picker("Order", selection: $model.volterra.order) {
                    ForEach(VolterraOrder.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Memory depth M: \(model.volterra.memoryDepth)",
                        value: $model.volterra.memoryDepth, in: 1...VolterraConfiguration.maxMemoryDepth)
                LabeledContent("Coefficients K", value: "\(model.layout.termCount)")
            }

            Section("Adaptation") {
                Picker("Algorithm", selection: $model.adaptation.algorithm) {
                    ForEach(AdaptiveAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch model.adaptation.algorithm {
                case .nlms:
                    LogSlider(title: "Step size μ", value: $model.adaptation.stepSize,
                              range: 1e-3...1.5, format: "%.3g")
                case .rls, .blockRLS:
                    LogSlider(
                        title: "Forgetting λ",
                        // Slider on (1 − λ) in log space: 1e-5 … 1e-2.
                        value: Binding(
                            get: { 1 - model.adaptation.forgettingFactor },
                            set: { model.adaptation.forgettingFactor = 1 - $0 }
                        ),
                        range: 1e-5...1e-2,
                        format: "1 − λ = %.1e"
                    )
                    Text("λ = \(model.adaptation.forgettingFactor, specifier: "%.5f") · memory ≈ \(Int(1 / max(1 - model.adaptation.forgettingFactor, 1e-9))) samples")
                        .font(.caption).foregroundStyle(.secondary)
                    LogSlider(title: "Regularization δ", value: $model.adaptation.delta,
                              range: 1e-6...1, format: "%.1e")
                }
                if let warning = model.rlsCostWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Plant") {
                Picker("PA model", selection: $model.amplifier.model) {
                    ForEach(PAModelKind.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("PA memory effects", isOn: $model.amplifier.memoryEnabled)
                LabeledSliderRow(title: "RMS drive level", value: $model.driveLevelDB,
                                 range: -30...0, format: "%.1f dBFS")
                Toggle("Noiseless observation", isOn: $model.noiseless)
                if !model.noiseless {
                    LabeledSliderRow(title: "Observation SNR", value: $model.snrDB,
                                     range: 20...100, format: "%.0f dB")
                }
            }

            Section("Identification") {
                Picker("Target", selection: $model.target) {
                    ForEach(IdentificationTarget.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Samples", selection: $model.identificationSamples) {
                    ForEach(Self.sampleCounts, id: \.self) { Text("\($0)").tag($0) }
                }
                HStack {
                    Button("Identify") { Task { await model.runIdentification() } }
                    Button("Compare step sizes") { Task { await model.runSweep() } }
                        .help("NLMS at μ = 0.05, 0.2, 0.5, 1.0 plus RLS on the same record")
                }
                .disabled(model.activity != nil)
            }

            Section("Digital pre-distortion") {
                Stepper("Passes over stimulus: \(model.dpdPasses)", value: $model.dpdPasses, in: 1...16)
                Button {
                    Task { await model.runDPD() }
                } label: {
                    Label("Run DPD loop", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.activity != nil)
            }
        }
        .formStyle(.grouped)
    }
}

/// Slider operating on log₁₀(value).
private struct LogSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { log10(min(max(value, range.lowerBound), range.upperBound)) },
                    set: { value = pow(10, $0) }
                ),
                in: log10(range.lowerBound)...log10(range.upperBound)
            )
            .accessibilityLabel(title)
            .accessibilityValue(String(format: format, value))
        }
    }
}

private struct LabeledSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value))
        }
    }
}

// MARK: - Identification results

private struct IdentificationPanel: View {
    let runs: [IdentificationRun]

    var body: some View {
        Phase3Panel(title: "Kernel identification — learning curves") {
            if runs.isEmpty {
                ContentUnavailableView(
                    "No identification yet",
                    systemImage: "chart.line.downtrend.xyaxis",
                    description: Text("Identify the PA kernels, or compare NLMS step sizes against RLS.")
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    LearningCurveChart(runs: runs)
                        .frame(height: 300)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text("Run").bold()
                            Text("Model NMSE").bold()
                            Text("Coefficient error").bold()
                            Text("Time").bold()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(runs) { run in
                            GridRow {
                                Text(run.label)
                                if run.diverged {
                                    Label("Diverged", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                } else {
                                    Text("\(run.modelNMSEdB, specifier: "%.1f") dB")
                                }
                                Text(run.coefficientErrorDB.map { String(format: "%.1f dB", $0) } ?? "—")
                                Text("\(run.seconds * 1000, specifier: "%.0f") ms")
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - DPD results

private struct DPDPanel: View {
    let result: DPDResult

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Phase3Panel(title: "Digital pre-distortion — closed-loop convergence") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Tile(title: "NMSE", value: "\(format(result.baseline.nmseDB)) → \(format(result.linearized.nmseDB))", unit: "dB")
                        Tile(title: "Improvement", value: format(result.nmseImprovementDB), unit: "dB")
                        Tile(title: "EVM", value: "\(format(result.baseline.evmPercent, 2)) → \(format(result.linearized.evmPercent, 2))", unit: "%")
                        Tile(title: "PAPR u → z", value: "\(format(result.reference.paprDB, 2)) → \(format(result.predistorted.paprDB, 2))", unit: "dB")
                        Tile(title: "Loop time", value: format(Float(result.seconds * 1000), 0), unit: "ms")
                    }
                    if result.diverged {
                        Label("The adaptive loop diverged — reduce μ, raise λ, or lower the drive level.",
                              systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    DPDConvergenceChart(result: result)
                        .frame(height: 260)
                }
            }

            Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                GridRow {
                    Phase3Panel(title: "AM/AM of y/G — before vs. after DPD") {
                        BeforeAfterScatter(before: result.amamBefore, after: result.amamAfter, yLabel: "|y| / |G|")
                            .frame(height: 280)
                    }
                    Phase3Panel(title: "AM/PM of y/G — before vs. after DPD") {
                        BeforeAfterScatter(before: result.ampmBefore, after: result.ampmAfter, yLabel: "Phase (°)")
                            .frame(height: 280)
                    }
                }
            }
        }
    }

    private func format(_ v: Float, _ digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct Phase3Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    Phase3DPDView()
        .frame(width: 1280, height: 900)
}
