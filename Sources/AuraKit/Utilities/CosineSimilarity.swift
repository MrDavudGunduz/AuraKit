// CosineSimilarity.swift
// AuraKit — Utilities
//
// CPU-based (Accelerate/vDSP) cosine similarity primitive.
//
// This provides a correct, reasonably fast cosine similarity function
// over `[Float]` vectors. It is NOT "the Search layer" from the README
// architecture diagram — that's `MetalSearchEngine`. This exists as a
// CPU fallback and building block for future embedding search work.
// See ROADMAP.md for the full search pipeline plan.

import Accelerate
import Foundation

// MARK: - CosineSimilarity

/// Vector similarity utilities backed by Accelerate's `vDSP`.
///
/// `CosineSimilarity` is a stateless, `Sendable` namespace — no instance
/// state, safe to call from any actor or task without synchronisation.
public enum CosineSimilarity {

  /// Computes the cosine similarity between two equal-length vectors.
  ///
  /// ```
  /// cos(θ) = (a · b) / (‖a‖ · ‖b‖)
  /// ```
  ///
  /// Result range is `[-1.0, 1.0]`; `1.0` = identical direction,
  /// `0.0` = orthogonal, `-1.0` = opposite.
  ///
  /// - Parameters:
  ///   - a: The first vector.
  ///   - b: The second vector. Must have the same `count` as `a`.
  /// - Returns: The cosine similarity, or `nil` if the vectors have
  ///   mismatched lengths, are empty, or either has zero magnitude.
  public static func similarity(_ a: [Float], _ b: [Float]) -> Float? {
    guard !a.isEmpty, a.count == b.count else { return nil }

    let dot = dotProduct(a, b)
    let magnitudeA = magnitude(a)
    let magnitudeB = magnitude(b)

    guard magnitudeA > 0, magnitudeB > 0 else { return nil }

    return dot / (magnitudeA * magnitudeB)
  }

  /// Ranks candidates by cosine similarity to a query vector (descending).
  ///
  /// O(n) linear scan — appropriate for small per-session working sets
  /// (hundreds to low thousands of nodes). When `limit` is specified,
  /// uses partial selection to avoid a full O(n log n) sort.
  ///
  /// - Parameters:
  ///   - query: The query vector.
  ///   - candidates: Candidate vectors paired with an opaque identifier.
  ///   - limit: Maximum number of results to return. Defaults to all.
  /// - Returns: `(id, similarity)` pairs sorted by descending similarity.
  ///   Candidates with mismatched dimensionality or zero magnitude are
  ///   silently excluded.
  public static func rank<ID: Sendable>(
    query: [Float],
    candidates: [(id: ID, vector: [Float])],
    limit: Int? = nil
  ) -> [(id: ID, similarity: Float)] {
    let scored = candidates.compactMap { candidate -> (id: ID, similarity: Float)? in
      guard let score = similarity(query, candidate.vector) else { return nil }
      return (candidate.id, score)
    }

    guard let limit, limit < scored.count else {
      // No limit or limit >= count — full sort is fine.
      return scored.sorted { $0.similarity > $1.similarity }
    }

    // Partial selection: extract top-k without fully sorting.
    // Uses a min-heap of size k — O(n + k log k) vs O(n log n).
    var heap = Array(scored.prefix(limit))
    heap.sort { $0.similarity < $1.similarity } // min-heap by ascending

    for i in limit..<scored.count {
      if scored[i].similarity > heap[0].similarity {
        heap[0] = scored[i]
        // Re-sift the root down to maintain min-heap.
        siftDown(&heap, from: 0)
      }
    }

    // Return in descending order.
    return heap.sorted { $0.similarity > $1.similarity }
  }

  // MARK: - Private Helpers

  /// Dot product via `vDSP_dotpr` (Accelerate).
  private static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
    var result: Float = 0
    vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
    return result
  }

  /// Euclidean (L2) magnitude via `vDSP_svesq` + `sqrt`.
  private static func magnitude(_ vector: [Float]) -> Float {
    var sumOfSquares: Float = 0
    vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
    return sqrt(sumOfSquares)
  }

  /// Sifts element at `index` down in a min-heap ordered by `.similarity`.
  private static func siftDown<ID>(
    _ heap: inout [(id: ID, similarity: Float)],
    from index: Int
  ) {
    let count = heap.count
    var parent = index
    while true {
      let left = 2 * parent + 1
      let right = 2 * parent + 2
      var smallest = parent

      if left < count, heap[left].similarity < heap[smallest].similarity {
        smallest = left
      }
      if right < count, heap[right].similarity < heap[smallest].similarity {
        smallest = right
      }
      if smallest == parent { break }
      heap.swapAt(parent, smallest)
      parent = smallest
    }
  }
}
