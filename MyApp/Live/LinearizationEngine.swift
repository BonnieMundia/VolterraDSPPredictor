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
        let rows: [(String, AdaptiveAlgorithm, Int, Int?, Int)] = [
            ("NLMS M=4", .nlms, 4, nil, 1), ("RLS  M=4", .rls, 4, nil, 1),
            ("Block RLS M=4", .blockRLS, 4, nil, 1), ("Block RLS M=4 1/8", .blockRLS, 4, nil, 8),
            ("NLMS M=8", .nlms, 8, nil, 1), ("RLS  M=8", .rls, 8, nil, 1),
            ("Block RLS M=8", .blockRLS, 8, nil, 1), ("Block RLS M=8 1/8", .blockRLS, 8, nil, 8),
            ("Block RLS M=8 D=1", .blockRLS, 8, 1, 1), ("Block RLS M=8 D=1 1/8", .blockRLS, 8, 1, 8),
            ("Block RLS M=8 D=0 1/8", .blockRLS, 8, 0, 8)
        ]
        for (label, algorithm, depth, span, every) in rows {
            var c = LiveConfiguration()
            c.adaptation.algorithm = algorithm
            c.volterra.memoryDepth = depth
            c.volterra.maxPairSpan = span
            c.adaptationInterval = every
            configurations.append((label, c))
        }
        var frozen = LiveConfiguration()
        frozen.volterra.memoryDepth = 8
        frozen.adaptationEnabled = false
        configurations.append(("Frozen M=8 (apply)", frozen))

        // The first quarter of the frames is warm-up; timings are the mean of the raw
        // per-frame values over the rest, so frames that skip adaptation count correctly.
        let warmUp = max(frames / 4, 1)
        for (label, configuration) in configurations {
            var core = LinearizationCore(configuration: configuration, metal: metal)
            var snapshot = core.advance()
            var frameTotal = 0.0
            var stageTotals: [ProcessingStage: Double] = [:]
            for f in 1..<max(frames, warmUp + 1) {
                snapshot = core.advance()
                guard f >= warmUp else { continue }
                frameTotal += snapshot.rawFrameSeconds
                for (stage, seconds) in snapshot.rawStageSeconds { stageTotals[stage, default: 0] += seconds }
            }
            let measured = Double(max(frames, warmUp + 1) - warmUp)
            let frameSeconds = frameTotal / measured
            let throughput = Double(configuration.frameSize) / frameSeconds / 1e6
            let stages = ProcessingStage.allCases
                .map { String(format: "%.3f", (stageTotals[$0] ?? 0) / measured * 1000) }
                .joined(separator: " | ")
            print(String(format: "%-22@ | %8.3f | %6.2f | %6.4f | %6.1f → %6.1f      | ",
                         label as NSString, frameSeconds * 1000, throughput, throughput * 1e6 / snapshot.sampleRate,
                         snapshot.aclrWithoutDPD.worstDBc, snapshot.aclrWithDPD.worstDBc) + stages)
        }
        exit(0)
    }
}
