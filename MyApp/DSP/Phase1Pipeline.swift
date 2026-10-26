import Accelerate
import Foundation

/// One sample of the time-domain overlay chart.
nonisolated struct TimeSample: Identifiable, Sendable {
    let id: Int
    let timeMicroseconds: Double
    let cleanEnvelope: Float
    let distortedEnvelope: Float
    let cleanInPhase: Float
    let distortedInPhase: Float
}

/// One point of an AM/AM or AM/PM transfer plot.
nonisolated struct TransferPoint: Identifiable, Sendable {
    let id: Int
    let input: Float
    let output: Float
}

nonisolated struct Phase1SimulationResult: Sendable {
    let clean: ComplexSignalBlock
    let distorted: ComplexSignalBlock
    let metrics: DistortionMetrics

    let synthesisTime: Duration
    let amplifierTime: Duration
    let blockSize: Int

    let timeSeries: [TimeSample]
    let amamScatter: [TransferPoint]
    let ampmScatter: [TransferPoint]
    let amamCurve: [TransferPoint]
    let ampmCurve: [TransferPoint]

    /// PA throughput in mega-samples per second.
    var amplifierThroughputMSps: Double {
        let seconds = Double(amplifierTime.components.seconds) + Double(amplifierTime.components.attoseconds) * 1e-18
        guard seconds > 0 else { return 0 }
        return Double(clean.count) / seconds / 1e6
    }
}

/// Phase 1 pipeline: synthesize → virtual PA (block-based) → metrics → chart data.
nonisolated enum Phase1Pipeline {

    static let timeWindowSamples = 400
    static let maxScatterPoints = 1_500
    static let curveResolution = 120

    static func run(signal: SignalConfiguration, amplifier: PAConfiguration, blockSize: Int = 1_024) -> Phase1SimulationResult {
        let clock = ContinuousClock()

        var clean = ComplexSignalBlock(count: 0, sampleRate: signal.sampleRate)
        let synthesisTime = clock.measure {
            clean = SignalSynthesizer.generate(signal)
        }

        var pa = VirtualPowerAmplifier(configuration: amplifier)
        var distorted = clean
        let amplifierTime = clock.measure {
            distorted = pa.process(stream: clean, blockSize: blockSize)
        }

        let metrics = DistortionMetrics.measure(input: clean, output: distorted)
        let curves = makeCurve(clean: clean, amplifier: amplifier)

        return Phase1SimulationResult(
            clean: clean,
            distorted: distorted,
            metrics: metrics,
            synthesisTime: synthesisTime,
            amplifierTime: amplifierTime,
            blockSize: blockSize,
            timeSeries: makeTimeSeries(clean: clean, distorted: distorted, gain: metrics.linearGain),
            amamScatter: makeAMAMScatter(clean: clean, distorted: distorted),
            ampmScatter: makeAMPMScatter(clean: clean, distorted: distorted),
            amamCurve: curves.amam,
            ampmCurve: curves.ampm
        )
    }

    // MARK: - Chart data

    /// First `timeWindowSamples` of envelope and I-channel. The distorted trace
    /// is de-rotated and divided by the linear gain ĝ so it overlays the clean
    /// trace; any residual difference is pure distortion.
    private static func makeTimeSeries(clean: ComplexSignalBlock, distorted: ComplexSignalBlock, gain: DSPComplex) -> [TimeSample] {
        let window = min(timeWindowSamples, clean.count)
        guard window > 0 else { return [] }

        let gMag2 = gain.real * gain.real + gain.imag * gain.imag
        let inverseGain = gMag2 > 0
            ? DSPComplex(real: gain.real / gMag2, imag: -gain.imag / gMag2)
            : DSPComplex(real: 1, imag: 0)

        let cleanWindow = clean.slice(0..<window)
        let aligned = distorted.slice(0..<window).multiplied(by: inverseGain)
        let cleanEnv = cleanWindow.magnitude()
        let alignedEnv = aligned.magnitude()
        let samplePeriodMicroseconds = 1e6 / clean.sampleRate

        return (0..<window).map { n in
            TimeSample(
                id: n,
                timeMicroseconds: Double(n) * samplePeriodMicroseconds,
                cleanEnvelope: cleanEnv[n],
                distortedEnvelope: alignedEnv[n],
                cleanInPhase: cleanWindow.real[n],
                distortedInPhase: aligned.real[n]
            )
        }
    }

    private static func scatterStride(_ count: Int) -> Int {
        max(1, count / maxScatterPoints)
    }

    /// Measured |y| vs |x|. With memory enabled this spreads into a cloud
    /// around the static curve — the visual signature of memory effects.
    private static func makeAMAMScatter(clean: ComplexSignalBlock, distorted: ComplexSignalBlock) -> [TransferPoint] {
        let inMag = clean.magnitude()
        let outMag = distorted.magnitude()
        return stride(from: 0, to: inMag.count, by: scatterStride(inMag.count)).map {
            TransferPoint(id: $0, input: inMag[$0], output: outMag[$0])
        }
    }

    /// Measured ∠(x*·y) vs |x|, in degrees.
    private static func makeAMPMScatter(clean: ComplexSignalBlock, distorted: ComplexSignalBlock) -> [TransferPoint] {
        let inMag = clean.magnitude()
        let phase = DistortionMetrics.relativePhaseDegrees(input: clean, output: distorted)
        return stride(from: 0, to: inMag.count, by: scatterStride(inMag.count)).map {
            TransferPoint(id: $0, input: inMag[$0], output: phase[$0])
        }
    }

    /// Theoretical static AM/AM and AM/PM curves from 0 to the input peak.
    private static func makeCurve(clean: ComplexSignalBlock, amplifier: PAConfiguration) -> (amam: [TransferPoint], ampm: [TransferPoint]) {
        let peak = max(clean.peakAmplitude, 1e-3)
        let r = vDSP.ramp(in: 0...peak, count: curveResolution)
        let (amam, ampm) = VirtualPowerAmplifier.staticCharacteristic(amplitudes: r, amplifier)
        let amamPoints = r.indices.map { TransferPoint(id: $0, input: r[$0], output: amam[$0]) }
        let ampmPoints = r.indices.map { TransferPoint(id: $0, input: r[$0], output: ampm[$0]) }
        return (amamPoints, ampmPoints)
    }
}
