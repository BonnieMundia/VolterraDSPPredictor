import Accelerate
import Foundation
import os

// MARK: - Configuration & snapshot types

nonisolated struct LiveConfiguration: Sendable, Equatable {
    var signal = SignalConfiguration()
    var amplifier = PAConfiguration()
    var volterra = VolterraConfiguration(memoryDepth: 4, order: .third)
    /// Block RLS: same LS solution as RLS at frame boundaries (the predistorter is
    /// only refreshed once per frame anyway) at a fraction of the cost — see profiler.
    var adaptation = AdaptationParameters(algorithm: .blockRLS, forgettingFactor: 0.9999, delta: 1e-2)
    var dpdEnabled = true
    var adaptationEnabled = true
    /// Run identification on one frame in every `adaptationInterval` (1 = every frame).
    /// The predistorter is still applied to every sample. A PA drifts slowly
    /// compared with a frame (33 µs here), so adapting on a subset of frames trades
    /// convergence speed for throughput, as production DPD loops do.
    var adaptationInterval = 1
    static let adaptationIntervalRange = 1...32
    /// Observation-receiver SNR (dB); `nil` = ideal feedback.
    var feedbackSNRdB: Double? = 70
    /// Samples per real-time frame (one DPD block / one coefficient update).
    var frameSize = 4_096
}

nonisolated enum ProcessingStage: String, CaseIterable, Identifiable, Sendable {
    case source = "Signal source"
    case predistort = "DPD apply"
    case amplifier = "Virtual PA (×2 paths)"
    case adaptation = "Regressors + adapt"
    case analysis = "FFT, ACLR, metrics"

    var id: String { rawValue }
}

nonisolated enum DPDStatus: String, Sendable {
    case adapting = "Adapting"
    case frozen = "Frozen"
    case bypassed = "Bypassed"
    case recovered = "Reset after divergence"
}

nonisolated struct SpectrumBin: Identifiable, Sendable {
    let id: Int
    let frequencyMHz: Double
    let idealDB: Double
    let withoutDPDDB: Double
    let withDPDDB: Double
}

nonisolated struct ErrorHistoryPoint: Identifiable, Sendable {
    var id: Int { iteration }
    /// Cumulative sample index n at the end of the bin.
    let iteration: Int
    let withoutDPDDB: Double
    let withDPDDB: Double
}

nonisolated struct IQPoint: Identifiable, Sendable {
    let id: Int
    let i: Float
    let q: Float
}

nonisolated struct LiveSnapshot: Sendable {
    let frame: Int
    let samplesProcessed: Int
    let sampleRate: Double
    let frameSize: Int

    let spectrum: [SpectrumBin]
    let channelPlan: ChannelPlan
    let aclrIdeal: ACLRMeasurement
    let aclrWithoutDPD: ACLRMeasurement
    let aclrWithDPD: ACLRMeasurement

    /// Smoothed NMSE of y/G vs. u (dB).
    let nmseWithoutDPD: Double
    let nmseWithDPD: Double
    let errorHistory: [ErrorHistoryPoint]

    /// Matched-filtered symbols, scaled so ideal points sit on the odd-integer grid.
    let constellationWithoutDPD: [IQPoint]
    let constellationWithDPD: [IQPoint]
    let symbolEVMWithoutDPD: Double?
    let symbolEVMWithDPD: Double?
    /// Axis half-width: one unit beyond the outermost grid point (√M for square M-QAM).
    let constellationExtent: Double

    /// Smoothed seconds per frame for each stage.
    let stageSeconds: [ProcessingStage: Double]
    let frameSeconds: Double
    /// Unsmoothed timings of this frame alone. Averaging these over many frames gives
    /// the true mean cost when adaptation runs on only some frames; the smoothed values
    /// above depend on how recently the last adapting frame ran.
    let rawStageSeconds: [ProcessingStage: Double]
    let rawFrameSeconds: Double

    let termCount: Int
    let backend: VolterraBackend
    let status: DPDStatus
    let divergenceResets: Int

    var throughputMSps: Double { frameSeconds > 0 ? Double(frameSize) / frameSeconds / 1e6 : 0 }
    /// Processed sample rate relative to the simulated RF sample rate (1.0 = real time).
    var realTimeFactor: Double { throughputMSps * 1e6 / sampleRate }
}

nonisolated enum EngineSignposts {
    static let signposter = OSSignposter(subsystem: "VolterraDSPPredictor", category: .pointsOfInterest)
}

// MARK: - Core

/// The complete linearization pipeline, advanced one frame at a time.
///
///     source ─u─┬────────────► PA_ref ──► ÷G ──► ỹ_ref   (uncorrected reference path)
///               └─► DPD ─z─► PA ─────► ÷G ──► ỹ ──► post-inverse adapt (ỹ → z) ─► copy to DPD
///
/// Synchronous and value-typed: the `LinearizationEngine` actor wraps it for the
/// UI, and `HeadlessProfiler` drives it directly for Release-build profiling.
nonisolated struct LinearizationCore: Sendable {
    private(set) var configuration: LiveConfiguration

    private var source: StreamingSignalSource
    private var paReference: VirtualPowerAmplifier
    private var paLinearized: VirtualPowerAmplifier
    private var predistorter: VolterraFilter
    private var postInverseDelay: VolterraFilter
    private var identifier: AdaptiveVolterraIdentifier

    // Exponentially weighted LS estimate of the target gain G (from the reference path).
    private var gainNumerator = (re: 0.0, im: 0.0)
    private var gainDenominator = 0.0

    private let analyzer = WelchSpectrumAnalyzer(fftLength: 1_024)
    private var smoothedPSD: (ideal: [Float], reference: [Float], linearized: [Float])?

    private var matchedIdeal: FIRFilter
    private var matchedReference: FIRFilter
    private var matchedLinearized: FIRFilter
    private var symbolsIdeal: [DSPComplex] = []
    private var symbolsReference: [DSPComplex] = []
    private var symbolsLinearized: [DSPComplex] = []

    private var errorHistory: [ErrorHistoryPoint] = []
    private var smoothedNMSE = (reference: 0.0, linearized: 0.0)
    private var smoothedStages: [ProcessingStage: Double] = [:]
    private var smoothedFrameSeconds = 0.0

    private var rng = Xoshiro256StarStar(seed: 0xFEED_BEEF)
    private var frame = 0
    private var samplesProcessed = 0
    private var divergenceResets = 0
    private var recoveredFrames = 0

    private let metal: MetalVolterraEngine?

    static let historyLength = 480
    static let constellationLength = 600
    static let historyBinsPerFrame = 4
    /// Exponential smoothing weights (new-sample weight).
    static let spectrumSmoothing: Float = 0.3
    static let metricSmoothing = 0.3
    static let gainForgetting = 0.9

    init(configuration: LiveConfiguration, metal: MetalVolterraEngine? = nil) {
        self.configuration = configuration
        self.metal = metal
        source = StreamingSignalSource(configuration: configuration.signal)
        paReference = VirtualPowerAmplifier(configuration: configuration.amplifier)
        paLinearized = VirtualPowerAmplifier(configuration: configuration.amplifier)
        matchedIdeal = FIRFilter(taps: source.pulseTaps)
        matchedReference = FIRFilter(taps: source.pulseTaps)
        matchedLinearized = FIRFilter(taps: source.pulseTaps)

        let layout = VolterraKernelLayout(configuration.volterra)
        let identity = Self.identityKernels(layout)
        predistorter = VolterraFilter(kernels: identity)
        postInverseDelay = VolterraFilter(kernels: identity)
        identifier = AdaptiveVolterraIdentifier(layout: layout, parameters: configuration.adaptation, initial: identity)
    }

    var layout: VolterraKernelLayout { VolterraKernelLayout(configuration.volterra) }

    /// DPD-apply backend, chosen online from measured apply times. A Metal dispatch has
    /// a fixed ≈ 0.3–0.5 ms round trip, and GPU speed depends on its clock state and on
    /// CPU contention, so neither a fixed K threshold nor a one-off calibration picks
    /// reliably (both chose the slower path at M = 8 on an M5 in some runs). Instead,
    /// every frame's apply time updates a per-backend average, both backends are tried
    /// on the first frames, and the slower one is re-probed every 128 frames.
    private(set) var backend: VolterraBackend = .vDSPFactored
    private var backendKey: BackendKey?
    private var applyCost: [VolterraBackend: Double] = [:]
    private var applySamples: [VolterraBackend: Int] = [:]
    private var framesSinceProbe = 0

    private struct BackendKey: Equatable {
        let layout: VolterraKernelLayout
        let frameSize: Int
    }

    /// Smallest K for which the GPU is considered; below it vDSP always wins.
    static let metalCandidateTermCount = 128
    static let backendExplorationSamples = 4
    static let backendProbeInterval = 128
    static let backendCostSmoothing = 0.2

    private var backendCandidates: [VolterraBackend] {
        metal != nil && layout.order == .third && layout.termCount >= Self.metalCandidateTermCount
            ? [.vDSPFactored, .metalGPU] : [.vDSPFactored]
    }

    /// Backend for this frame: explore, exploit the cheaper one, or periodically re-probe.
    private mutating func backendForFrame(frameSize: Int) -> VolterraBackend {
        let key = BackendKey(layout: layout, frameSize: frameSize)
        if key != backendKey {
            backendKey = key
            applyCost.removeAll(); applySamples.removeAll(); framesSinceProbe = 0
        }
        let candidates = backendCandidates
        guard candidates.count > 1 else { backend = .vDSPFactored; return .vDSPFactored }

        // Exploration: alternate until each has enough samples (the first is warm-up, not recorded).
        if let next = candidates.min(by: { (applySamples[$0] ?? 0) < (applySamples[$1] ?? 0) }),
           (applySamples[next] ?? 0) < Self.backendExplorationSamples {
            return next
        }
        let best = candidates.min { (applyCost[$0] ?? .infinity) < (applyCost[$1] ?? .infinity) } ?? .vDSPFactored
        backend = best
        framesSinceProbe += 1
        if framesSinceProbe >= Self.backendProbeInterval {
            framesSinceProbe = 0
            return candidates.first { $0 != best } ?? best
        }
        return best
    }

    private mutating func recordApply(_ backend: VolterraBackend, seconds: Double) {
        let count = applySamples[backend, default: 0]
        applySamples[backend] = count + 1
        guard count > 0 else { return }     // first run per backend includes pipeline/buffer warm-up
        let a = Self.backendCostSmoothing
        applyCost[backend] = applyCost[backend].map { (1 - a) * $0 + a * seconds } ?? seconds
    }

    // MARK: Control

    /// Applies a new configuration, rebuilding only the state each change invalidates.
    mutating func update(_ new: LiveConfiguration) {
        let old = configuration
        guard new != old else { return }
        configuration = new

        if new.signal != old.signal {
            source = StreamingSignalSource(configuration: new.signal)
            matchedIdeal = FIRFilter(taps: source.pulseTaps)
            matchedReference = FIRFilter(taps: source.pulseTaps)
            matchedLinearized = FIRFilter(taps: source.pulseTaps)
            symbolsIdeal.removeAll(); symbolsReference.removeAll(); symbolsLinearized.removeAll()
            smoothedPSD = nil
            resetGain()
        }
        if new.amplifier != old.amplifier {
            paReference = VirtualPowerAmplifier(configuration: new.amplifier)
            paLinearized = VirtualPowerAmplifier(configuration: new.amplifier)
            resetGain()
        }
        if VolterraKernelLayout(new.volterra) != VolterraKernelLayout(old.volterra) {
            resetDPD()
        } else if new.adaptation != old.adaptation {
            identifier.parameters = new.adaptation
            // P (RLS) or R, b (block RLS) must be re-initialized when the algorithm
            // changes, and RLS's P(0) = δ⁻¹I also depends on δ.
            let algorithmChanged = old.adaptation.algorithm != new.adaptation.algorithm
            let needsCovarianceReset = new.adaptation.algorithm.usesForgettingFactor &&
                (algorithmChanged || (new.adaptation.algorithm == .rls && old.adaptation.delta != new.adaptation.delta))
            if needsCovarianceReset { identifier.resetCovariance() }
        }
    }

    /// Returns the predistorter to identity and restarts identification.
    mutating func resetDPD() {
        let identity = Self.identityKernels(layout)
        predistorter = VolterraFilter(kernels: identity)
        postInverseDelay = VolterraFilter(kernels: identity)
        identifier = AdaptiveVolterraIdentifier(layout: layout, parameters: configuration.adaptation, initial: identity)
    }

    private mutating func resetGain() {
        gainNumerator = (0, 0)
        gainDenominator = 0
    }

    // MARK: Frame processing

    mutating func advance() -> LiveSnapshot {
        let clock = ContinuousClock()
        let signposter = EngineSignposts.signposter
        let frameStart = clock.now
        var stages: [ProcessingStage: Double] = [:]
        let n = configuration.frameSize

        // 1. Stimulus
        var mark = clock.now
        var interval = signposter.beginInterval("Source")
        let u = source.next(n)
        signposter.endInterval("Source", interval)
        stages[.source] = (clock.now - mark).timeInterval

        // 2. Predistortion
        mark = clock.now
        interval = signposter.beginInterval("DPD apply")
        let z: ComplexSignalBlock
        if configuration.dpdEnabled {
            let frameBackend = backendForFrame(frameSize: n)
            z = predistorter.process(u, backend: frameBackend, metal: metal)
            recordApply(frameBackend, seconds: (clock.now - mark).timeInterval)
        } else {
            z = u
        }
        signposter.endInterval("DPD apply", interval)
        stages[.predistort] = (clock.now - mark).timeInterval

        // 3. Both PA paths + feedback receiver noise
        mark = clock.now
        interval = signposter.beginInterval("Virtual PA")
        var yReference = paReference.process(u)
        var yLinearized = paLinearized.process(z)
        if let snr = configuration.feedbackSNRdB {
            NoiseGenerator.addGaussianNoise(to: &yReference, snrDB: snr, using: &rng)
            NoiseGenerator.addGaussianNoise(to: &yLinearized, snrDB: snr, using: &rng)
        }
        signposter.endInterval("Virtual PA", interval)
        stages[.amplifier] = (clock.now - mark).timeInterval

        // Target gain G (exponentially weighted LS on the uncorrected path).
        let frameGain = DistortionMetrics.linearGain(input: u, output: yReference)
        let frameEnergy = Double(u.meanPower) * Double(n)
        gainNumerator.re = Self.gainForgetting * gainNumerator.re + Double(frameGain.real) * frameEnergy
        gainNumerator.im = Self.gainForgetting * gainNumerator.im + Double(frameGain.imag) * frameEnergy
        gainDenominator = Self.gainForgetting * gainDenominator + frameEnergy
        let gain = DSPComplex(real: Float(gainNumerator.re / gainDenominator), imag: Float(gainNumerator.im / gainDenominator))
        let inverseGain = Self.reciprocal(gain)
        let referenceNormalized = yReference.multiplied(by: inverseGain)
        let linearizedNormalized = yLinearized.multiplied(by: inverseGain)

        // 4. Indirect-learning adaptation: post-inverse maps ỹ → z, then copy to the DPD.
        mark = clock.now
        interval = signposter.beginInterval("Adapt")
        // The delay line advances every frame so regressors stay aligned on frames that do adapt.
        let extended = postInverseDelay.extend(linearizedNormalized)
        let adaptEvery = max(configuration.adaptationInterval, 1)
        if configuration.dpdEnabled && configuration.adaptationEnabled && frame % adaptEvery == 0 {
            let rows = RegressorRows.build(extended: extended, layout: layout)
            identifier.adapt(regressors: rows, desired: z)
            if identifier.diverged {
                divergenceResets += 1
                recoveredFrames = 30
                resetDPD()
            } else {
                predistorter.kernels = identifier.kernels
            }
        }
        signposter.endInterval("Adapt", interval)
        stages[.adaptation] = (clock.now - mark).timeInterval

        // 5. Analysis
        mark = clock.now
        interval = signposter.beginInterval("Analysis")
        let plan = ChannelPlan.forSignal(configuration.signal)
        let spectrum = updateSpectrum(ideal: u, reference: referenceNormalized, linearized: linearizedNormalized)
        updateErrorHistory(ideal: u, reference: referenceNormalized, linearized: linearizedNormalized)
        updateConstellation(ideal: u, reference: referenceNormalized, linearized: linearizedNormalized)
        signposter.endInterval("Analysis", interval)
        stages[.analysis] = (clock.now - mark).timeInterval

        // Bookkeeping
        samplesProcessed += n
        frame += 1
        if recoveredFrames > 0 { recoveredFrames -= 1 }
        let frameSeconds = (clock.now - frameStart).timeInterval
        let alpha = frame == 1 ? 1 : Self.metricSmoothing
        for stage in ProcessingStage.allCases {
            smoothedStages[stage] = (1 - alpha) * (smoothedStages[stage] ?? 0) + alpha * (stages[stage] ?? 0)
        }
        smoothedFrameSeconds = (1 - alpha) * smoothedFrameSeconds + alpha * frameSeconds

        let fs = configuration.signal.sampleRate
        let psd = smoothedPSD!
        return LiveSnapshot(
            frame: frame,
            samplesProcessed: samplesProcessed,
            sampleRate: fs,
            frameSize: n,
            spectrum: spectrum,
            channelPlan: plan,
            aclrIdeal: analyzer.aclr(psd.ideal, sampleRate: fs, plan: plan),
            aclrWithoutDPD: analyzer.aclr(psd.reference, sampleRate: fs, plan: plan),
            aclrWithDPD: analyzer.aclr(psd.linearized, sampleRate: fs, plan: plan),
            nmseWithoutDPD: smoothedNMSE.reference,
            nmseWithDPD: smoothedNMSE.linearized,
            errorHistory: errorHistory,
            constellationWithoutDPD: points(symbolsReference),
            constellationWithDPD: points(symbolsLinearized),
            symbolEVMWithoutDPD: Self.evm(symbolsReference, reference: symbolsIdeal),
            symbolEVMWithDPD: Self.evm(symbolsLinearized, reference: symbolsIdeal),
            constellationExtent: Double(configuration.signal.kind.qamOrder ?? 16).squareRoot(),
            stageSeconds: smoothedStages,
            frameSeconds: smoothedFrameSeconds,
            rawStageSeconds: stages,
            rawFrameSeconds: frameSeconds,
            termCount: layout.termCount,
            backend: backend,
            status: status,
            divergenceResets: divergenceResets
        )
    }

    private var status: DPDStatus {
        if !configuration.dpdEnabled { return .bypassed }
        if recoveredFrames > 0 { return .recovered }
        return configuration.adaptationEnabled ? .adapting : .frozen
    }

    // MARK: Analysis helpers

    /// Smoothed Welch PSDs → display bins in dB relative to the ideal in-band density.
    private mutating func updateSpectrum(ideal: ComplexSignalBlock, reference: ComplexSignalBlock, linearized: ComplexSignalBlock) -> [SpectrumBin] {
        let fresh = (analyzer.psd(ideal), analyzer.psd(reference), analyzer.psd(linearized))
        if let previous = smoothedPSD {
            let a = Self.spectrumSmoothing
            smoothedPSD = (
                vDSP.add(vDSP.multiply(1 - a, previous.ideal), vDSP.multiply(a, fresh.0)),
                vDSP.add(vDSP.multiply(1 - a, previous.reference), vDSP.multiply(a, fresh.1)),
                vDSP.add(vDSP.multiply(1 - a, previous.linearized), vDSP.multiply(a, fresh.2))
            )
        } else {
            smoothedPSD = fresh
        }
        let psd = smoothedPSD!
        let fs = configuration.signal.sampleRate
        let plan = ChannelPlan.forSignal(configuration.signal)

        // 0 dB = mean in-band density of the ideal signal.
        let inBand = analyzer.bandPower(psd.ideal, sampleRate: fs, from: -plan.bandwidth / 2, to: plan.bandwidth / 2)
        let referenceDensity = Float(max(inBand / plan.bandwidth, 1e-30))
        let freqs = analyzer.frequencies(sampleRate: fs)

        // Average bin pairs (linear) → 512 display points.
        func display(_ p: [Float]) -> [Double] {
            stride(from: 0, to: p.count - 1, by: 2).map {
                Double(10 * log10(max((p[$0] + p[$0 + 1]) / 2 / referenceDensity, 1e-15)))
            }
        }
        let ideal = display(psd.ideal), ref = display(psd.reference), lin = display(psd.linearized)
        return ideal.indices.map { i in
            SpectrumBin(
                id: i,
                frequencyMHz: (freqs[2 * i] + freqs[2 * i + 1]) / 2 / 1e6,
                idealDB: ideal[i],
                withoutDPDDB: ref[i],
                withDPDDB: lin[i]
            )
        }
    }

    /// Instantaneous error power |ỹ − u|² / P_u, binned along the iteration axis.
    private mutating func updateErrorHistory(ideal: ComplexSignalBlock, reference: ComplexSignalBlock, linearized: ComplexSignalBlock) {
        let referencePower = Double(max(ideal.meanPower, .leastNormalMagnitude))
        let referenceError = reference.subtracting(ideal).power()
        let linearizedError = linearized.subtracting(ideal).power()
        let bin = max(1, ideal.count / Self.historyBinsPerFrame)

        for start in stride(from: 0, to: ideal.count, by: bin) {
            let range = start..<min(start + bin, ideal.count)
            let ref = Double(vDSP.mean(referenceError[range])) / referencePower
            let lin = Double(vDSP.mean(linearizedError[range])) / referencePower
            errorHistory.append(ErrorHistoryPoint(
                iteration: samplesProcessed + range.upperBound,
                withoutDPDDB: 10 * log10(max(ref, 1e-15)),
                withDPDDB: 10 * log10(max(lin, 1e-15))
            ))
        }
        if errorHistory.count > Self.historyLength {
            errorHistory.removeFirst(errorHistory.count - Self.historyLength)
        }

        let frameRef = Double(vDSP.mean(referenceError)) / referencePower
        let frameLin = Double(vDSP.mean(linearizedError)) / referencePower
        let a = frame == 0 ? 1 : Self.metricSmoothing
        let refDB = 10 * log10(max(frameRef, 1e-15)), linDB = 10 * log10(max(frameLin, 1e-15))
        smoothedNMSE = (
            (1 - a) * smoothedNMSE.reference + a * refDB,
            (1 - a) * smoothedNMSE.linearized + a * linDB
        )
    }

    /// Matched-filters all three paths and keeps the most recent symbol decisions.
    private mutating func updateConstellation(ideal: ComplexSignalBlock, reference: ComplexSignalBlock, linearized: ComplexSignalBlock) {
        guard configuration.signal.kind != .multiTone else { return }
        let mi = matchedIdeal.process(ideal)
        let mr = matchedReference.process(reference)
        let ml = matchedLinearized.process(linearized)
        let sps = max(configuration.signal.samplesPerSymbol, 2)
        let delay = source.symbolDelay

        for i in 0..<ideal.count {
            let g = samplesProcessed + i - delay
            guard g >= 0, g % sps == 0 else { continue }
            symbolsIdeal.append(DSPComplex(real: mi.real[i], imag: mi.imag[i]))
            symbolsReference.append(DSPComplex(real: mr.real[i], imag: mr.imag[i]))
            symbolsLinearized.append(DSPComplex(real: ml.real[i], imag: ml.imag[i]))
        }
        let excess = symbolsIdeal.count - Self.constellationLength
        if excess > 0 {
            symbolsIdeal.removeFirst(excess)
            symbolsReference.removeFirst(excess)
            symbolsLinearized.removeFirst(excess)
        }

        // Scale so the ideal constellation has the grid RMS √(2(M−1)/3) → points at ±1, ±3, …
        let order = Double(configuration.signal.kind.qamOrder ?? 16)
        let idealRMS = (symbolsIdeal.reduce(0.0) { $0 + Double($1.real * $1.real + $1.imag * $1.imag) } / Double(max(symbolsIdeal.count, 1))).squareRoot()
        constellationScale = idealRMS > 0 ? Float((2 * (order - 1) / 3).squareRoot() / idealRMS) : 1
    }

    private var constellationScale: Float = 1

    private func points(_ symbols: [DSPComplex]) -> [IQPoint] {
        symbols.enumerated().map { IQPoint(id: $0.offset, i: $0.element.real * constellationScale, q: $0.element.imag * constellationScale) }
    }

    private static func evm(_ symbols: [DSPComplex], reference: [DSPComplex]) -> Double? {
        guard !symbols.isEmpty, symbols.count == reference.count else { return nil }
        var errorEnergy = 0.0, referenceEnergy = 0.0
        for (s, r) in zip(symbols, reference) {
            let dr = Double(s.real - r.real), di = Double(s.imag - r.imag)
            errorEnergy += dr * dr + di * di
            referenceEnergy += Double(r.real * r.real + r.imag * r.imag)
        }
        return referenceEnergy > 0 ? (errorEnergy / referenceEnergy).squareRoot() * 100 : nil
    }

    private static func identityKernels(_ layout: VolterraKernelLayout) -> VolterraKernels {
        var k = VolterraKernels(layout: layout)
        k.setLinear(0, DSPComplex(real: 1, imag: 0))
        return k
    }

    private static func reciprocal(_ g: DSPComplex) -> DSPComplex {
        let m2 = g.real * g.real + g.imag * g.imag
        guard m2 > 0, m2.isFinite else { return DSPComplex(real: 1, imag: 0) }
        return DSPComplex(real: g.real / m2, imag: -g.imag / m2)
    }
}
