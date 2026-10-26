import Foundation
import Observation

/// Main-actor state for the live dashboard. Drives the engine in a loop and
/// publishes snapshots at a capped rate; control edits are forwarded between frames.
@Observable
final class LiveDashboardModel {
    var configuration = LiveConfiguration()
    private(set) var snapshot: LiveSnapshot?
    private(set) var isRunning = false

    /// Engine pacing (≈ 20 frames/s of DSP).
    static let minimumFrameInterval: Duration = .milliseconds(50)
    /// UI refresh cap (≈ 10 Hz); the engine keeps adapting between published snapshots.
    /// Each dashboard redraw costs ≈ 20–25 ms of main thread, so publishing at the
    /// engine's 20 Hz kept it 44 % busy (Release, standalone) versus 26 % at 10 Hz.
    /// Sessions launched from Xcode run the main thread about 3× busier, so measure
    /// UI load on a standalone launch.
    static let minimumPublishInterval: Duration = .milliseconds(100)

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
            var lastPublish = clock.now - Self.minimumPublishInterval
            while !Task.isCancelled {
                let frameStart = clock.now
                // Forward edits made since the previous frame (applied atomically between frames).
                if configuration != sent {
                    sent = configuration
                    await engine.update(sent)
                }
                let next = await engine.advance()
                if clock.now - lastPublish >= Self.minimumPublishInterval {
                    snapshot = next
                    lastPublish = clock.now
                }
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
