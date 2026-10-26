import Foundation
import Observation

/// UI-facing state for the Phase 1 dashboard. Lives on the main actor; all DSP
/// work is dispatched to a detached task so slider drags never block rendering.
@Observable
final class Phase1SimulationModel {

    /// Everything that triggers a re-simulation. Used as the `.task(id:)` key.
    nonisolated struct Inputs: Equatable, Sendable {
        var signal = SignalConfiguration()
        var amplifier = PAConfiguration()
        var blockSize = 1_024
    }

    var inputs = Inputs()
    private(set) var result: Phase1SimulationResult?
    private(set) var isRunning = false

    /// Input back-off convenience: RMS drive expressed in dBFS (0 dBFS = amplitude 1.0).
    var driveLevelDB: Double {
        get { 20 * log10(Double(max(inputs.signal.rmsAmplitude, 1e-6))) }
        set { inputs.signal.rmsAmplitude = Float(pow(10, newValue / 20)) }
    }

    /// Runs the pipeline off the main actor and publishes the result.
    /// Cancellation (from `.task(id:)` restarts) discards stale results.
    func simulate() async {
        let snapshot = inputs
        isRunning = true
        defer { isRunning = false }

        let computed = await Task.detached(priority: .userInitiated) {
            Phase1Pipeline.run(
                signal: snapshot.signal,
                amplifier: snapshot.amplifier,
                blockSize: snapshot.blockSize
            )
        }.value

        guard !Task.isCancelled else { return }
        result = computed
    }
}
