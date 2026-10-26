import SwiftUI

/// Stimulus and virtual-PA parameters.
struct Phase1ControlPanel: View {
    @Bindable var model: Phase1SimulationModel

    private static let sampleCounts = [4_096, 8_192, 16_384, 32_768, 65_536]
    private static let blockSizes = [256, 512, 1_024, 2_048, 4_096]

    var body: some View {
        Form {
            Section("Stimulus") {
                Picker("Waveform", selection: $model.inputs.signal.kind) {
                    ForEach(SignalKind.allCases) { Text($0.rawValue).tag($0) }
                }

                Picker("Samples", selection: $model.inputs.signal.sampleCount) {
                    ForEach(Self.sampleCounts, id: \.self) { Text("\($0)").tag($0) }
                }

                if model.inputs.signal.kind == .multiTone {
                    Stepper("Tones: \(model.inputs.signal.toneCount)",
                            value: $model.inputs.signal.toneCount, in: 2...64)
                    LabeledSlider(
                        title: "Tone span",
                        value: Binding(
                            get: { model.inputs.signal.toneSpan / 1e6 },
                            set: { model.inputs.signal.toneSpan = $0 * 1e6 }
                        ),
                        range: 1...60,
                        format: "%.1f MHz"
                    )
                } else {
                    Stepper("Samples / symbol: \(model.inputs.signal.samplesPerSymbol)",
                            value: $model.inputs.signal.samplesPerSymbol, in: 2...16)
                    LabeledSlider(title: "RRC roll-off β", value: $model.inputs.signal.rolloff,
                                  range: 0.05...1.0, format: "%.2f")
                }

                LabeledContent("Occupied BW") {
                    Text("\(model.inputs.signal.occupiedBandwidth / 1e6, specifier: "%.2f") MHz")
                        .monospacedDigit()
                }
                LabeledContent("Sample rate") {
                    Text("\(model.inputs.signal.sampleRate / 1e6, specifier: "%.2f") MHz")
                        .monospacedDigit()
                }
            }

            Section("Drive") {
                LabeledSlider(title: "RMS drive level", value: $model.driveLevelDB,
                              range: -30...0, format: "%.1f dBFS")
            }

            Section("Virtual power amplifier") {
                Picker("Model", selection: $model.inputs.amplifier.model) {
                    ForEach(PAModelKind.allCases) { Text($0.rawValue).tag($0) }
                }

                if model.inputs.amplifier.model == .rapp {
                    LabeledSlider(title: "Saturation V_sat", value: floatBinding(\.saturationAmplitude),
                                  range: 0.2...1.5, format: "%.2f")
                    LabeledSlider(title: "Knee smoothness p", value: floatBinding(\.smoothness),
                                  range: 0.5...8, format: "%.2f")
                    LabeledSlider(
                        title: "AM/PM max phase",
                        value: Binding(
                            get: { Double(model.inputs.amplifier.amPMMaxPhase) * 180 / .pi },
                            set: { model.inputs.amplifier.amPMMaxPhase = Float($0 * .pi / 180) }
                        ),
                        range: 0...90,
                        format: "%.1f°"
                    )
                    LabeledSlider(title: "AM/PM knee", value: floatBinding(\.amPMKnee),
                                  range: 0.1...1.5, format: "%.2f")
                } else {
                    Text("Saleh TWTA: αₐ = 2.1587, βₐ = 1.1517, α_φ = 4.0033, β_φ = 9.1040")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Memory effects (Wiener–Hammerstein)", isOn: $model.inputs.amplifier.memoryEnabled)
            }

            Section("Processing") {
                Picker("Block size", selection: $model.inputs.blockSize) {
                    ForEach(Self.blockSizes, id: \.self) { Text("\($0)").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Bridges a `Float` PA parameter to a `Double` slider binding.
    private func floatBinding(_ keyPath: WritableKeyPath<PAConfiguration, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model.inputs.amplifier[keyPath: keyPath]) },
            set: { model.inputs.amplifier[keyPath: keyPath] = Float($0) }
        )
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value))
        }
    }
}
