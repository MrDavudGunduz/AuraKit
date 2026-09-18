// VectorSearchResultTests.swift
// AuraKitTests — Models
//
// Tests for VectorSearchResult value type — Comparable ordering,
// Equatable, Hashable, Codable round-trip, and CustomStringConvertible.

import Testing
import Foundation
@testable import AuraKit

// MARK: - VectorSearchResultTests

@Suite("VectorSearchResult — Value Type Conformances")
struct VectorSearchResultTests {

  // MARK: - Comparable (Descending Similarity)

  @Test("Comparable sorts by descending similarity")
  func comparableSortingDescending() {
    let low = VectorSearchResult(id: UUID(), similarity: 0.1)
    let mid = VectorSearchResult(id: UUID(), similarity: 0.5)
    let high = VectorSearchResult(id: UUID(), similarity: 0.9)

    var results = [low, high, mid]
    results.sort()

    #expect(results[0].similarity == 0.9)
    #expect(results[1].similarity == 0.5)
    #expect(results[2].similarity == 0.1)
  }

  @Test("Comparable handles negative similarities")
  func comparableNegativeSimilarities() {
    let positive = VectorSearchResult(id: UUID(), similarity: 0.5)
    let zero = VectorSearchResult(id: UUID(), similarity: 0.0)
    let negative = VectorSearchResult(id: UUID(), similarity: -0.5)

    var results = [negative, positive, zero]
    results.sort()

    #expect(results[0].similarity == 0.5)
    #expect(results[1].similarity == 0.0)
    #expect(results[2].similarity == -0.5)
  }

  // MARK: - Equatable

  @Test("Equatable matches on same id and similarity")
  func equatableIdentical() {
    let id = UUID()
    let a = VectorSearchResult(id: id, similarity: 0.95)
    let b = VectorSearchResult(id: id, similarity: 0.95)

    #expect(a == b)
  }

  @Test("Equatable differs on different id")
  func equatableDifferentID() {
    let a = VectorSearchResult(id: UUID(), similarity: 0.95)
    let b = VectorSearchResult(id: UUID(), similarity: 0.95)

    #expect(a != b)
  }

  @Test("Equatable differs on different similarity")
  func equatableDifferentSimilarity() {
    let id = UUID()
    let a = VectorSearchResult(id: id, similarity: 0.95)
    let b = VectorSearchResult(id: id, similarity: 0.50)

    #expect(a != b)
  }

  // MARK: - Hashable

  @Test("Hashable produces consistent hashes")
  func hashableConsistency() {
    let id = UUID()
    let result = VectorSearchResult(id: id, similarity: 0.8)

    var set: Set<VectorSearchResult> = [result]
    set.insert(VectorSearchResult(id: id, similarity: 0.8))

    #expect(set.count == 1)
  }

  // MARK: - Codable

  @Test("Codable JSON round-trip preserves values")
  func codableRoundTrip() throws {
    let original = VectorSearchResult(id: UUID(), similarity: 0.7654)

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VectorSearchResult.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.similarity == original.similarity)
  }

  @Test("Codable encodes array of results")
  func codableArray() throws {
    let results = [
      VectorSearchResult(id: UUID(), similarity: 0.9),
      VectorSearchResult(id: UUID(), similarity: 0.5),
      VectorSearchResult(id: UUID(), similarity: 0.1),
    ]

    let data = try JSONEncoder().encode(results)
    let decoded = try JSONDecoder().decode([VectorSearchResult].self, from: data)

    #expect(decoded.count == 3)
    #expect(decoded[0].similarity == 0.9)
    #expect(decoded[2].similarity == 0.1)
  }

  // MARK: - Identifiable

  @Test("Identifiable id matches UUID property")
  func identifiableID() {
    let uuid = UUID()
    let result = VectorSearchResult(id: uuid, similarity: 0.5)

    #expect(result.id == uuid)
  }

  // MARK: - CustomStringConvertible

  @Test("Description contains truncated UUID and formatted similarity")
  func descriptionFormat() {
    let id = UUID()
    let result = VectorSearchResult(id: id, similarity: 0.9876)

    let description = result.description
    #expect(description.contains("VectorSearchResult"))
    #expect(description.contains("0.9876"))
    #expect(description.contains(String(id.uuidString.prefix(8))))
  }

  // MARK: - Sendable

  @Test("Sendable — safe to pass across actor boundaries")
  func sendableCompliance() async {
    let result = VectorSearchResult(id: UUID(), similarity: 0.5)

    // Pass across an actor boundary — Swift 6 strict concurrency check
    let captured = await Task.detached {
      result
    }.value

    #expect(captured.similarity == 0.5)
  }

  // MARK: - Edge Cases

  @Test("Perfect similarity value 1.0")
  func perfectSimilarity() {
    let result = VectorSearchResult(id: UUID(), similarity: 1.0)
    #expect(result.similarity == 1.0)
  }

  @Test("Perfect anti-correlation value -1.0")
  func perfectAntiCorrelation() {
    let result = VectorSearchResult(id: UUID(), similarity: -1.0)
    #expect(result.similarity == -1.0)
  }

  @Test("Zero similarity")
  func zeroSimilarity() {
    let result = VectorSearchResult(id: UUID(), similarity: 0.0)
    #expect(result.similarity == 0.0)
  }
}
