#include <metal_stdlib>
using namespace metal;

// Must match `VolterraGPUParams` in MetalVolterraEngine.swift.
struct VolterraGPUParams {
    uint outputCount;
    uint memoryDepth;
    uint hasConstant;
    uint hasCubic;
    uint pairSpan;      // largest stored tau2 - tau1 (M - 1 = unpruned)
};

constant uint kMaxMemoryDepth = 16;

inline float2 cmul(float2 a, float2 b) {
    return float2(fma(a.x, b.x, -a.y * b.y), fma(a.x, b.y, a.y * b.x));
}

inline float2 conjugate(float2 a) { return float2(a.x, -a.y); }

/// Fused complex Volterra evaluation: one thread per output sample.
///
/// Unlike the CPU regression path, Φ is never materialized — each thread
/// loads its M-sample input window into registers once, then streams the
/// coefficient vector (identical for every thread, so it is broadcast from the
/// constant cache). Coefficient order matches `VolterraKernelLayout`:
///   [h0] [h1(0..M-1)] [h3(a,b,c) for a<M, b in a...min(a+D, M-1), c<M]
///
/// x: extended input, x(n - tau) = x[n + M - 1 - tau]; length N + M - 1.
kernel void volterra_evaluate(device const float2 *x          [[buffer(0)]],
                              constant float2 *h              [[buffer(1)]],
                              device float2 *y                [[buffer(2)]],
                              constant VolterraGPUParams &p   [[buffer(3)]],
                              uint n                          [[thread_position_in_grid]])
{
    if (n >= p.outputCount) { return; }

    const uint M = min(p.memoryDepth, kMaxMemoryDepth);
    const uint base = n + M - 1;

    // Register-resident input window w[tau] = x(n - tau) and its conjugate.
    float2 w[kMaxMemoryDepth];
    float2 wc[kMaxMemoryDepth];
    for (uint t = 0; t < M; ++t) {
        w[t] = x[base - t];
        wc[t] = conjugate(w[t]);
    }

    uint k = 0;
    float2 acc = float2(0.0f);

    if (p.hasConstant != 0) {
        acc += h[0];
        k = 1;
    }

    for (uint t = 0; t < M; ++t) {
        acc += cmul(h[k + t], w[t]);
    }
    k += M;

    if (p.hasCubic != 0) {
        for (uint a = 0; a < M; ++a) {
            const uint bEnd = min(M, a + p.pairSpan + 1);
            for (uint b = a; b < bEnd; ++b) {
                const float2 pab = cmul(w[a], w[b]);
                // g = sum_c h3(a,b;c) * conj(x(n - c))
                float2 g = float2(0.0f);
                for (uint c = 0; c < M; ++c) {
                    g += cmul(h[k + c], wc[c]);
                }
                acc += cmul(pab, g);
                k += M;
            }
        }
    }

    y[n] = acc;
}
