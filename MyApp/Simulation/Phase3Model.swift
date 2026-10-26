import Foundation
import Observation

/// UI state for the Phase 3 adaptive identification & DPD workbench.
@Observable
final class Phase3Model {
    enum Activity: String {
        case identifying = "Identifying…"
        case sweeping = "Comparing step sizes…"
        case linearizing = "Running DPD loop…"
    }

    // Shared model & adaptation settings (used by identification and DPD).
    var volterra = VolterraConfiguration(memoryDepth: 4, order: .third)
    var adaptation = AdaptationParameters(algorithm: .blockRLS, forgettingFactor: 0.9999, delta: 1e-2)

    // Plant.
    var signal = SignalConfiguration()
    var amplifier = PAConfiguration()
    var noiseless = false
    var snrDB: Double = 60

    // Experiments.
    var target: IdentificationTarget = .virtualPA
    var identificationSamples = 16_384
    var dpdPasses = 4

    private(set) var identificationRuns: [IdentificationRun] = []
    private(set) var dpdResult: DPDResult?
    private(set) var activity: Activity?

    var layout: VolterraKernelLayout { VolterraKernelLayout(volterra) }

    var rlsCostWarning: String? {
        adaptation.algorithm.costWarning(termCount: layout.termCount)
    }

    var driveLevelDB: Double {
        get { 20 * log10(Double(max(signal.rmsAmplitude, 1e-6))) }
        set { signal.rmsAmplitude = Float(pow(10, newValue / 20)) }
    }

    private var identificationConfiguration: IdentificationConfiguration {
        IdentificationConfiguration(
            target: target,
            volterra: volterra,
            adaptation: adaptation,
            sampleCount: identificationSamples,
            blockSize: 1_024,
            measurementSNRdB: noiseless ? nil : snrDB
        )
    }

    private var dpdConfiguration: DPDConfiguration {
        DPDConfiguration(
            volterra: volterra,
            adaptation: adaptation,
            passes: dpdPasses,
            blockSize: 1_024,
            feedbackSNRdB: noiseless ? nil : snrDB
        )
    }

    func runIdentification() async {
        let config = identificationConfiguration, signal = signal, amplifier = amplifier
        let run = await perform(.identifying) {
            IdentificationExperiment.run(config, signal: signal, amplifier: amplifier)
        }
        if let run { identificationRuns = [run] }
    }

    func runSweep() async {
        let config = identificationConfiguration, signal = signal, amplifier = amplifier
        let runs = await perform(.sweeping) {
            IdentificationExperiment.sweep(config, signal: signal, amplifier: amplifier)
        }
        if let runs { identificationRuns = runs }
    }

    func runDPD() async {
        let config = dpdConfiguration, signal = signal, amplifier = amplifier
        let result = await perform(.linearizing) {
            DPDLoop.run(signal: signal, amplifier: amplifier, dpd: config)
        }
        if let result { dpdResult = result }
    }

    /// Runs DSP work off the main actor; ignores requests while another job is running.
    private func perform<T: Sendable>(_ kind: Activity, _ work: @escaping @Sendable () -> T) async -> T? {
        guard activity == nil else { return nil }
        activity = kind
        defer { activity = nil }
        return await Task.detached(priority: .userInitiated, operation: work).value
    }
}
