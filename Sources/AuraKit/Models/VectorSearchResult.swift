// VectorSearchResult.swift
// AuraKit — Models
//
// Represents a single cosine similarity search result from the Metal GPU pipeline.
// Fully Sendable and Comparable for safe cross-actor transport and sorting.

import Foundation

// MARK: - VectorSearchResult

/// A single result from a GPU-accelerated cosine similarity search.
///
/// `VectorSearchResult` pairs a memory node's identifier with its cosine
/// similarity score relative to a query vector. Results are returned sorted
/// by descending similarity from ``MetalSearchEngine/search(query:vectors:ids:topK:)``.
///
/// ## Usage
///
/// ```swift
/// let results = try await AuraKit.shared.memory.searchSimilarMemories(
///     queryVector: embedding,
///     topK: 5
/// )
/// for result in results {
///     print("\(result.id): \(result.similarity)")
/// }
/// ```
///
/// ## Ordering
///
/// `VectorSearchResult` conforms to `Comparable` — results with higher
/// similarity sort first (descending). This enables natural top-K filtering
/// via standard library sorting.
///
/// ## Thread Safety
///
/// Fully `Sendable` — safe to pass across actor boundaries without synchronisation.
public struct VectorSearchResult: Sendable, Hashable, Codable, Identifiable {

  // MARK: - Properties

  /// The unique identifier of the memory node that matched.
  public let id: UUID

  /// The cosine similarity score in the range `[-1.0, 1.0]`.
  ///
  /// | Value | Interpretation |
  /// |-------|----------------|
  /// | `1.0` | Identical direction (perfect match) |
  /// | `0.0` | Orthogonal (unrelated) |
  /// | `-1.0` | Opposite direction (anti-correlated) |
  public let similarity: Float

  // MARK: - Init

  /// Creates a new vector search result.
  ///
  /// - Parameters:
  ///   - id: The UUID of the matching memory node.
  ///   - similarity: The cosine similarity score `[-1.0, 1.0]`.
  public init(id: UUID, similarity: Float) {
    self.id = id
    self.similarity = similarity
  }
}

// MARK: - Comparable

extension VectorSearchResult: Comparable {

  /// Compares two results by descending similarity — higher similarity sorts first.
  ///
  /// This enables natural top-K filtering:
  /// ```swift
  /// let topResults = results.sorted().prefix(10)
  /// ```
  public static func < (lhs: VectorSearchResult, rhs: VectorSearchResult) -> Bool {
    // Descending order: higher similarity = "less than" for sort-first behaviour
    lhs.similarity > rhs.similarity
  }
}

// MARK: - CustomStringConvertible

extension VectorSearchResult: CustomStringConvertible {

  public var description: String {
    "VectorSearchResult(id: \(id.uuidString.prefix(8))…, similarity: \(String(format: "%.4f", similarity)))"
  }
}
