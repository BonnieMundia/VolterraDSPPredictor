import SwiftUI

/// Phase 2 workbench: kernel structure, backend benchmark and correctness checks.
struct Phase2EngineView: View {
    @State private var model = Phase2EngineModel()

    private static let blockSizes = [256, 512, 1_024, 2_048, 4_096]

    var body: some View {
        NavigationSplitView {
            Form {
                Section("Kernel structure") {
                    Picker("Order", selection: $model.configuration.order) {
                        ForEach(VolterraOrder.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("Memory depth M: \(model.configuration.memoryDepth)",
                            value: $model.configuration.memoryDepth,
                            in: 1...VolterraConfiguration.maxMemoryDepth)
                    Toggle("Constant term h₀", isOn: $model.configuration.includeConstant)
                    KernelStats(layout: model.layout, regressionBytes: model.regressionMatrixBytes,
                                blockSize: model.blockSize)
                }

                Section("Benchmark") {
                    Picker("Order", selection: $model.benchmarkOrder) {
                        ForEach(VolterraOrder.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Block size N", selection: $model.blockSize) {
                        ForEach(Self.blockSizes, id: \.self) { Text("\($0)").tag($0) }
                    }
                    LabeledContent("GPU", value: model.metal?.deviceName ?? "Unavailable")
                    Button {
                        Task { await model.runBenchmark() }
                    } label: {
                        Label("Run benchmark", systemImage: "speedometer")
                    }
                    .disabled(model.isRunning)
                    if model.isRunning {
                        ProgressView(value: model.progress)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Panel(title: "Cubic kernel energy per (τ₁, τ₂), summed over τ₃ — synthetic PA kernel (dB)") {
                        KernelEnergyMap(kernels: .syntheticPA(layout: model.layout))
                            .frame(maxHeight: 340)
                    }

                    if let report = model.report {
                        BenchmarkResults(report: report)
                    } else {
                        Panel(title: "Benchmark") {
                            ContentUnavailableView(
                                "No benchmark yet",
                                systemImage: "speedometer",
                                description: Text("Run the benchmark to time all backends across memory depths 1–16.")
                            )
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Volterra Engine — Phase 2")
        }
    }
}

// MARK: - Sidebar stats

private struct KernelStats: View {
    let layout: VolterraKernelLayout
    let regressionBytes: Int
    let blockSize: Int

    var body: some View {
        let full = layout.fullTensorTermCount
        let saving = full > 0 ? 100 * (1 - Double(layout.termCount) / Double(full)) : 0
        LabeledContent("Unique coefficients K", value: "\(layout.termCount)")
        LabeledContent("Full-tensor coefficients", value: "\(full)")
        LabeledContent("Symmetry saving", value: saving.formatted(.number.precision(.fractionLength(1))) + " %")
        LabeledContent("Kernel memory",
                       value: (layout.termCount * 8).formatted(.byteCount(style: .memory)))
        LabeledContent("Φ per \(blockSize)-sample block",
                       value: regressionBytes.formatted(.byteCount(style: .memory)))
    }
}

// MARK: - Results

private struct BenchmarkResults: View {
    let report: VolterraBenchmarkReport

    private var sortedEntries: [VolterraBenchmarkEntry] {
        report.entries.sorted {
            ($0.memoryDepth, VolterraBackend.allCases.firstIndex(of: $0.backend) ?? 0)
                < ($1.memoryDepth, VolterraBackend.allCases.firstIndex(of: $1.backend) ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel(title: "Throughput vs. memory depth  (\(report.order.label), N = \(report.blockSize))") {
                VStack(alignment: .leading, spacing: 8) {
                    ThroughputChart(entries: report.entries)
                        .frame(height: 300)
                    crossoverNote
                }
            }

            Panel(title: "Correctness checks") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.checks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(check.passed ? .green : .red)
                            Text(check.passed ? "Pass" : "Fail").bold()
                            Text(check.name)
                            Text(check.detail).foregroundStyle(.secondary)
                            Spacer()
                            Text("err \(check.error, format: .number.notation(.scientific).precision(.significantDigits(2)))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Panel(title: "Results") {
                Table(sortedEntries) {
                    TableColumn("M") { Text("\($0.memoryDepth)").monospacedDigit() }
                        .width(40)
                    TableColumn("K") { Text("\($0.termCount)").monospacedDigit() }
                        .width(60)
                    TableColumn("Backend") { e in
                        Text(e.backend.rawValue).help(e.backend.detail)
                    }
                    TableColumn("µs / block") {
                        Text($0.secondsPerBlock * 1e6, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    }
                    TableColumn("GPU µs") { e in
                        if let gpu = e.gpuSecondsPerBlock {
                            Text(gpu * 1e6, format: .number.precision(.fractionLength(1))).monospacedDigit()
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    TableColumn("MS/s") {
                        Text($0.throughputMSps, format: .number.precision(.significantDigits(3))).monospacedDigit()
                    }
                    TableColumn("G-terms/s") {
                        Text($0.gigaTermsPerSecond, format: .number.precision(.significantDigits(3))).monospacedDigit()
                    }
                    TableColumn("Rel. error") { e in
                        if e.backend == .scalarReference {
                            Text("reference").foregroundStyle(.secondary)
                        } else {
                            Text(e.relativeError, format: .number.notation(.scientific).precision(.significantDigits(2)))
                                .monospacedDigit()
                        }
                    }
                }
                .frame(minHeight: 360)
            }
        }
    }

    @ViewBuilder private var crossoverNote: some View {
        if let depth = report.gpuCrossoverDepth {
            Label("Metal overtakes the fastest CPU backend from M = \(depth) at N = \(report.blockSize).",
                  systemImage: "cpu")
        } else if report.gpuName != nil {
            Label("CPU backends win at every depth for N = \(report.blockSize); try larger blocks to amortize GPU dispatch.",
                  systemImage: "cpu")
        } else {
            Label("Metal unavailable — GPU backend skipped.", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct Panel<Content: View>: View {
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
    Phase2EngineView()
        .frame(width: 1280, height: 900)
}
