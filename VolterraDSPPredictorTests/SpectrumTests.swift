import Accelerate
import Foundation
import Testing
@testable import VolterraDSPPredictor

@Suite("Welch spectrum analyzer (vDSP_fft_zrip)")
struct SpectrumTests {
    let analyzer = WelchSpectrumAnalyzer(fftLength: 1_024)
    let fs = 122.88e6

    /// Complex exponential exp(j2πf·n/fs) centred on FFT bin `bin` (negative = lower sideband).
    private func tone(bin: Int, count: Int = 16_384) -> ComplexSignalBlock {
        let w = 2 * Double.pi * Double(bin) / Double(analyzer.fftLength)
        return ComplexSignalBlock(
            real: (0..<count).map { Float(cos(w * Double($0))) },
            imag: (0..<count).map { Float(sin(w * Double($0))) },
            sampleRate: fs
        )
    }

    @Test("Complex tones land on the correct sideband", arguments: [37, -37, 200, -411])
    func sidebandSign(bin: Int) throws {
        let psd = analyzer.psd(tone(bin: bin))
        let peak = try #require(psd.indices.max { psd[$0] < psd[$1] })
        // psd is fft-shifted: index n/2 is DC.
        #expect(peak - analyzer.fftLength / 2 == bin)
    }

    @Test("Integrated PSD equals mean signal power (Parseval)")
    func parseval() {
        let x = randomBlock(count: 32_768, seed: 21, rms: 0.4, sampleRate: fs)
        let psd = analyzer.psd(x)
        let total = analyzer.bandPower(psd, sampleRate: fs, from: -fs / 2, to: fs / 2)
        #expect(abs(total / Double(x.meanPower) - 1) < 0.02)
    }

    @Test("A unit tone integrates to unit power")
    func tonePower() {
        let psd = analyzer.psd(tone(bin: 100))
        let total = analyzer.bandPower(psd, sampleRate: fs, from: -fs / 2, to: fs / 2)
        #expect(abs(total - 1) < 0.01)
    }

    @Test("ACLR of a clean in-band signal is far below the PA's")
    func aclrOfIdealVersusAmplified() {
        var signal = SignalConfiguration()
        signal.sampleCount = 32_768
        let u = SignalSynthesizer.generate(signal)
        var pa = VirtualPowerAmplifier(configuration: PAConfiguration())
        let y = pa.process(stream: u, blockSize: 4_096)
        let plan = ChannelPlan.forSignal(signal)
        let ideal = analyzer.aclr(analyzer.psd(u), sampleRate: signal.sampleRate, plan: plan)
        let amplified = analyzer.aclr(analyzer.psd(y), sampleRate: signal.sampleRate, plan: plan)
        #expect(ideal.worstDBc < -50)
        #expect(amplified.worstDBc > -40)
        #expect(amplified.worstDBc - ideal.worstDBc > 15)
    }
}
