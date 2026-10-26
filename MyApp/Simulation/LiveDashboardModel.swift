import Foundation
import Observation

/// Main-actor state for the live dashboard. Drives the engine in a loop and
/// publishes each frame's snapshot; control edits are forwarded between frames.
@Observable
final class LiveDashboardModel {
    var configuration = LiveConfiguration()
    private(set) var snapshot: LiveSnapshot?
    private(set) var isRunning = false

    /// Frame pacing (≈ 20 fps). Chart redraw, not DSP, is the main-thread cost.
    static let minimumFrameInterval: Duration = .milliseconds(50)

    private let engine: LinearizationEngine
    private var loop: Task<Void, Never>?

    init() {
        let initial = LiveConfiguration()
        engine = LinearizationEngine(configuration: initial, metal: MetalVolterraEngine())
    }

    var layout: VolterraKernelLayout { VolterraKernelLayout(configuration.volterra) }

    var driveLevelDB: Double {
        get { 20 * log10(Double(max(configuration.signal.rmsAmplitude, 1e-6))) }
        set { configuration.signal.rmsAmplitude = Float(pow(10, newValue / 20)) }
    }

    func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [engine] in
            var sent = LiveConfiguration()
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let frameStart = clock.now
                // Forward edits made since the previous frame (applied atomically between frames).
                if configuration != sent {
                    sent = configuration
                    await engine.update(sent)
                }
                let next = await engine.advance()
                snapshot = next
                // Yield so the UI renders; pace to the refresh cap.
                let remaining = Self.minimumFrameInterval - (clock.now - frameStart)
                try? await Task.sleep(for: max(remaining, .milliseconds(1)))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    func resetDPD() {
        Task { await engine.resetDPD() }
    }
}
