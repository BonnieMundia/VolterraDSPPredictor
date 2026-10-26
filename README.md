# VolterraDSPPredictor

A native macOS app (SwiftUI, Apple Silicon) that simulates RF power-amplifier nonlinearity and memory effects, models them with a truncated **Volterra series**, and linearizes the amplifier with an **adaptive digital predistortion (DPD)** loop. All math is native Swift on Accelerate (vDSP/BLAS) and Metal, with no third-party dependencies.

## What's inside

| Tab | Phase | What it does |
|---|---|---|
| Signal & PA | 1 | Synthesizes multi-tone / QAM wideband stimuli and passes them through a configurable virtual PA (Rapp and Saleh AM/AM and AM/PM, optional memory) |
| Volterra Engine | 2 | True multidimensional Volterra kernels (P = 1 or P = 3, memory depth M up to 16), evaluated on vDSP and on a Metal compute kernel, with benchmarks |
| Adaptive DPD | 3 | NLMS, RLS and Block RLS kernel identification; indirect-learning DPD with convergence curves versus step size |
| Live Dashboard | 4 | Real-time streaming pipeline: Welch PSD via `vDSP_fft_zrip`, ACLR, NMSE, EVM, an error-convergence trace, a constellation, and per-stage timings, with live controls for order, memory depth, step size and PA saturation |

The model is the complex-baseband form of the Volterra series for a band-pass PA. Even-order terms fall outside the carrier zone, so the in-band kernels are h₁ and h₃:

y(n) = h₀ + Σ_τ h₁(τ)·x(n−τ) + Σ_{τ₁≤τ₂} Σ_{τ₃} h₃(τ₁,τ₂;τ₃)·x(n−τ₁)·x(n−τ₂)·x*(n−τ₃)

The τ₁↔τ₂ symmetry is exploited, so storage is M²(M+1)/2 cubic coefficients instead of M³.

## Requirements

- macOS 27 or later on Apple Silicon
- Xcode 27 or later

## Build and run

Open `Untitled Project.xcodeproj` in Xcode and run the `MyApp` scheme.

### Headless profiling

The app has a headless profiling mode that runs the live pipeline without a UI and prints per-stage timings. Use an optimized build:

```sh
xcodebuild -project "Untitled Project.xcodeproj" -scheme MyApp -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/VolterraRelease build
/tmp/VolterraRelease/Build/Products/Release/MyApp.app/Contents/MacOS/MyApp --profile 150
```

Stages are also emitted as `os_signpost` intervals (Points of Interest) for Instruments.

## Verified results (Apple M5, Release)

| Check | Result |
|---|---|
| RLS identification of a known synthetic Volterra system | Coefficients recovered to −119.7 dB |
| Live DPD, Rapp PA with memory, 16-QAM at 122.88 MS/s, M = 4 (K = 44) | ACLR −31.6 → −45.3 dBc, NMSE −23.4 → −39.3 dB, EVM 5.1 → 0.7 % |
| Live dashboard | About 19 fps (target 20 fps) |
