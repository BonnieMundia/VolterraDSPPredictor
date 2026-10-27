# VolterraDSPPredictor

A native macOS app (SwiftUI, Apple Silicon) that simulates RF power-amplifier nonlinearity and memory effects, models them with a truncated **Volterra series**, and linearizes the amplifier with an **adaptive digital predistortion (DPD)** loop. All math is native Swift on Accelerate (vDSP/BLAS) and Metal, with no third-party dependencies.

## What's inside

| Tab | Phase | What it does |
|---|---|---|
| Signal & PA | 1 | Synthesizes multi-tone / QAM wideband stimuli and passes them through a configurable virtual PA (Rapp and Saleh AM/AM and AM/PM, optional memory) |
| Volterra Engine | 2 | True multidimensional Volterra kernels (P = 1 or P = 3, memory depth M up to 16), evaluated on vDSP and on a Metal compute kernel, with benchmarks |
| Adaptive DPD | 3 | NLMS, RLS and Block RLS kernel identification; indirect-learning DPD with convergence curves versus step size |
| Live Dashboard | 4 | Real-time streaming pipeline: Welch PSD via `vDSP_fft_zrip`, ACLR, NMSE, EVM, an error-convergence trace, a constellation, and per-stage timings, with live controls for order, memory depth, cross-term span, adaptive algorithm, step size, adaptation rate and PA saturation |

The model is the complex-baseband form of the Volterra series for a band-pass PA. Even-order terms fall outside the carrier zone, so the in-band kernels are h₁ and h₃:

y(n) = h₀ + Σ_τ h₁(τ)·x(n−τ) + Σ_{τ₁≤τ₂} Σ_{τ₃} h₃(τ₁,τ₂;τ₃)·x(n−τ₁)·x(n−τ₂)·x*(n−τ₃)

The τ₁↔τ₂ symmetry is exploited, so storage is M²(M+1)/2 cubic coefficients instead of M³.

## Performance features

- **Block RLS** (the default) solves the same exponentially weighted least-squares problem as sample-by-sample RLS, but once per block with BLAS matrix products.
- **Adapt every N frames**: identification runs on one frame in N, while the predistorter still processes every sample.
- **Cross-term span D** (kernel pruning): keeps only cubic terms with |τ₁ − τ₂| ≤ D. It is still a true Volterra kernel and every backend keeps its fast path.
- **Online backend selection**: DPD application is timed on both vDSP and Metal, and the faster path is kept, judged by the median of recent frames.

## Requirements

- macOS 27 or later on Apple Silicon
- Xcode 27 or later

## Build, run and test

Open `Untitled Project.xcodeproj` in Xcode and run the `VolterraDSPPredictor` scheme. **Product ▸ Test** (⌘U) runs the Swift Testing suite.

### Headless profiling

The app has a headless profiling mode that runs the live pipeline without a UI and prints mean per-stage timings and the selected DPD backend. Use an optimized build:

```sh
xcodebuild -project "Untitled Project.xcodeproj" -scheme VolterraDSPPredictor -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/VolterraRelease build
/tmp/VolterraRelease/Build/Products/Release/VolterraDSPPredictor.app/Contents/MacOS/VolterraDSPPredictor --profile 160
```

Stages are also emitted as `os_signpost` intervals (Points of Interest) for Instruments.

Measure UI load on a standalone launch. Sessions started from Xcode showed about 3× the main-thread load of the same build launched directly.

## Verified results (Apple M5, Release)

| Check | Result |
|---|---|
| RLS identification of a known synthetic Volterra system | Coefficients recovered to −119.7 dB |
| Live DPD, Rapp PA with memory, 16-QAM at 122.88 MS/s, M = 4 (K = 44) | ACLR −31.7 → −45.6 dBc, NMSE −23.4 → −39.3 dB, EVM 5.1 → 0.7 % |
| Block RLS, M = 8, full kernel (K = 296), adapting every frame | 15.3 ms per 4,096-sample frame (0.27 MS/s) |
| Same, adapting every 8th frame | 2.6 ms (1.6 MS/s), same ACLR |
| Same, D = 0 (K = 72), adapting every 8th frame | 0.58 ms (7.0 MS/s), same ACLR, 26× faster |
| Live dashboard main thread, standalone Release launch | 26 % busy at 10 Hz UI refresh (44 % at 20 Hz) |

On the built-in virtual PA, pruning costs nothing measurable: the oversampled QAM stimulus makes cross products nearly collinear with diagonal terms. That will not hold for every PA or stimulus, so the default stays unpruned.
