import Foundation

/// Concurrency boundary for the real-time pipeline. All DSP runs on the actor's
/// executor, off the main thread; the UI only ever receives immutable snapshots.
actor LinearizationEngine {
    private var core: LinearizationCore

    init(configuration: LiveConfiguration, metal: MetalVolterraEngine?) {
        core = LinearizationCore(configuration: configuration, metal: metal)
    }

    func update(_ configuration: LiveConfiguration) {
        core.update(configuration)
    }

    func resetDPD() {
        core.resetDPD()
    }

    func advance() -> LiveSnapshot {
        core.advance()
    }
}

/// `--profile [frames]` launch argument: runs the live pipeline without UI and prints
/// per-stage timings, so it can be measured in an optimized (Release) build:
///
///     xcodebuild -scheme MyApp -configuration Release build
///     …/MyApp.app/Contents/MacOS/MyApp --profile 200
///
/// Stages are also emitted as os_signpost intervals (Points of Interest) for Instruments.
nonisolated enum HeadlessProfiler {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--profile") else { return }
        let frames = arguments.indices.contains(flag + 1) ? Int(arguments[flag + 1]) ?? 200 : 200

        let metal = MetalVolterraEngine()
        print("VolterraDSPPredictor headless profile — \(frames) frames/config, GPU: \(metal?.deviceName ?? "none")")
        print("config                 | frame ms | MS/s   | RT×    | ACLR noDPD→DPD (dBc) | " +
              ProcessingStage.allCases.map(\.rawValue).joined(separator: " | "))

        var configurations: [(String, LiveConfiguration)] = []
        for (label, algorithm, depth) in [("NLMS M=4", AdaptiveAlgorithm.nlms, 4), ("RLS  M=4", .rls, 4),
                                          ("Block RLS M=4", .blockRLS, 4),
                                          ("NLMS M=8", .nlms, 8), ("RLS  M=8", .rls, 8),
                                          ("Block RLS M=8", .blockRLS, 8)] {
            var c = LiveConfiguration()
            c.adaptation.algorithm = algorithm
            c.volterra.memoryDepth = depth
            configurations.append((label, c))
        }
        var frozen = LiveConfiguration()
        frozen.volterra.memoryDepth = 8
        frozen.adaptationEnabled = false
        configurations.append(("Frozen M=8 (apply)", frozen))

        for (label, configuration) in configurations {
            var core = LinearizationCore(configuration: configuration, metal: metal)
            var snapshot = core.advance()
            for _ in 1..<frames { snapshot = core.advance() }
            let stages = ProcessingStage.allCases
                .map { String(format: "%.3f", (snapshot.stageSeconds[$0] ?? 0) * 1000) }
                .joined(separator: " | ")
            print(String(format: "%-22@ | %8.3f | %6.2f | %6.4f | %6.1f → %6.1f      | ",
                         label as NSString, snapshot.frameSeconds * 1000, snapshot.throughputMSps,
                         snapshot.realTimeFactor, snapshot.aclrWithoutDPD.worstDBc, snapshot.aclrWithDPD.worstDBc) + stages)
        }
        exit(0)
    }
}
