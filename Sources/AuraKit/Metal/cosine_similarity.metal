// cosine_similarity.metal
// AuraKit — Metal Compute Shaders
//
// GPU-accelerated cosine similarity search kernel.
// Each thread computes the cosine similarity between the query vector
// and a single stored memory vector, enabling massively parallel search
// across thousands of vectors in sub-millisecond time.
//
// Performance target: < 0.5ms for 10,000 vectors on A17 Pro.

#include <metal_stdlib>
using namespace metal;

/// Computes cosine similarity between a query vector and each stored vector.
///
/// ## Memory Layout
///
/// - `queryVector`: A single vector of `dimension` floats (the search query).
/// - `memoryVectors`: A packed array of N vectors, each `dimension` floats.
///   Vector i starts at offset `i * dimension`.
/// - `results`: Output buffer of N floats, one similarity score per vector.
/// - `params`: Uniform buffer containing `dimension` and `vectorCount`.
///
/// ## Algorithm
///
/// For each thread index `gid`:
///
/// ```
///            dot(query, memory[gid])
/// cos(θ) = ─────────────────────────────
///           ‖query‖ · ‖memory[gid]‖
/// ```
///
/// The kernel handles degenerate cases (zero-magnitude vectors) by outputting
/// a similarity of `0.0` rather than producing `NaN` from division by zero.
///
/// ## Dispatch
///
/// Dispatched as a 1D grid where `gid` ∈ [0, vectorCount).
/// Threads beyond `vectorCount` are no-ops (bounds check).
struct CosineSimilarityParams {
    uint dimension;     // Number of floats per vector
    uint vectorCount;   // Total number of stored vectors
};

kernel void cosine_similarity_kernel(
    device const float* queryVector       [[buffer(0)]],
    device const float* memoryVectors     [[buffer(1)]],
    device float*       results           [[buffer(2)]],
    constant CosineSimilarityParams& params [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    // Bounds check — threads beyond vectorCount are no-ops
    if (gid >= params.vectorCount) {
        return;
    }

    const uint dim = params.dimension;
    const uint offset = gid * dim;

    // Accumulate dot product and magnitudes in a single pass
    float dotProduct = 0.0f;
    float queryMagnitudeSq = 0.0f;
    float memoryMagnitudeSq = 0.0f;

    for (uint i = 0; i < dim; i++) {
        float q = queryVector[i];
        float m = memoryVectors[offset + i];

        dotProduct += q * m;
        queryMagnitudeSq += q * q;
        memoryMagnitudeSq += m * m;
    }

    // Compute denominator with degenerate case handling
    float denominator = sqrt(queryMagnitudeSq) * sqrt(memoryMagnitudeSq);

    // Guard against division by zero (zero-magnitude vectors → similarity 0.0)
    if (denominator < 1e-8f) {
        results[gid] = 0.0f;
    } else {
        results[gid] = dotProduct / denominator;
    }
}
