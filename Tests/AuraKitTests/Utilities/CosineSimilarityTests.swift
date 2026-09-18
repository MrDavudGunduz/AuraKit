// CosineSimilarityTests.swift
// AuraKitTests — Utilities
//
// Correctness tests for the Accelerate-backed CosineSimilarity primitive.

import Foundation
import Testing

@testable import AuraKit

@Suite("CosineSimilarity")
struct CosineSimilarityTests {

  // MARK: - similarity()

  @Test("Identical vectors have similarity 1.0")
  func identicalVectors() {
    let v: [Float] = [1, 2, 3, 4]
    let result = CosineSimilarity.similarity(v, v)
    #expect(result != nil)
    #expect(abs((result ?? 0) - 1.0) < 1e-5)
  }

  @Test("Orthogonal vectors have similarity ~0.0")
  func orthogonalVectors() {
    let a: [Float] = [1, 0]
    let b: [Float] = [0, 1]
    let result = CosineSimilarity.similarity(a, b)
    #expect(result != nil)
    #expect(abs(result ?? 1) < 1e-5)
  }

  @Test("Opposite direction vectors have similarity -1.0")
  func oppositeVectors() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [-1, -2, -3]
    let result = CosineSimilarity.similarity(a, b)
    #expect(result != nil)
    #expect(abs((result ?? 0) - (-1.0)) < 1e-5)
  }

  @Test("Scale-invariance: parallel vectors of different magnitude still score 1.0")
  func scaleInvariance() {
    let a: [Float] = [2, 0, 0]
    let b: [Float] = [50, 0, 0]
    let result = CosineSimilarity.similarity(a, b)
    #expect(result != nil)
    #expect(abs((result ?? 0) - 1.0) < 1e-5)
  }

  @Test("Mismatched-length vectors return nil")
  func mismatchedLength() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [1, 2]
    #expect(CosineSimilarity.similarity(a, b) == nil)
  }

  @Test("Empty vectors return nil")
  func emptyVectors() {
    let a: [Float] = []
    let b: [Float] = []
    #expect(CosineSimilarity.similarity(a, b) == nil)
  }

  @Test("Zero-magnitude vector returns nil (undefined cosine)")
  func zeroMagnitude() {
    let a: [Float] = [0, 0, 0]
    let b: [Float] = [1, 2, 3]
    #expect(CosineSimilarity.similarity(a, b) == nil)
  }

  @Test("Single-element vectors work correctly")
  func singleElement() {
    let result = CosineSimilarity.similarity([3.0], [7.0])
    #expect(result != nil)
    #expect(abs((result ?? 0) - 1.0) < 1e-5)
  }

  @Test("High-dimensional vectors (384-d embedding size) produce valid result")
  func highDimensional() {
    // 384 is the typical sentence-transformer embedding dimension.
    let a = (0..<384).map { Float($0) * 0.01 }
    let b = (0..<384).map { Float(383 - $0) * 0.01 }
    let result = CosineSimilarity.similarity(a, b)
    #expect(result != nil)
    // Just verify it's in valid range, not a specific value.
    #expect(result! >= -1.0 && result! <= 1.0)
  }

  // MARK: - rank()

  @Test("rank(query:candidates:) sorts descending by similarity")
  func rankSortsDescending() {
    let query: [Float] = [1, 0, 0]
    let candidates: [(id: String, vector: [Float])] = [
      ("far", [0, 1, 0]),
      ("close", [0.9, 0.1, 0]),
      ("exact", [1, 0, 0]),
    ]

    let ranked = CosineSimilarity.rank(query: query, candidates: candidates)

    #expect(ranked.map(\.id) == ["exact", "close", "far"])
  }

  @Test("rank(query:candidates:limit:) truncates results")
  func rankRespectsLimit() {
    let query: [Float] = [1, 0]
    let candidates: [(id: Int, vector: [Float])] = (0..<10).map { i in
      (i, [Float(10 - i), Float(i)])
    }

    let ranked = CosineSimilarity.rank(query: query, candidates: candidates, limit: 3)

    #expect(ranked.count == 3)
  }

  @Test("rank with limit returns same top-k as full sort")
  func rankLimitMatchesFullSort() {
    let query: [Float] = [1, 0, 0]
    let candidates: [(id: Int, vector: [Float])] = (0..<50).map { i in
      let angle = Float(i) * 0.1
      return (i, [cos(angle), sin(angle), 0])
    }

    let fullSort = CosineSimilarity.rank(query: query, candidates: candidates)
    let limited = CosineSimilarity.rank(query: query, candidates: candidates, limit: 5)

    let topFiveFromFull = Array(fullSort.prefix(5))
    #expect(limited.map(\.id) == topFiveFromFull.map(\.id))
  }

  @Test("rank(query:candidates:) silently excludes mismatched-dimension candidates")
  func rankExcludesMismatched() {
    let query: [Float] = [1, 0, 0]
    let candidates: [(id: String, vector: [Float])] = [
      ("valid", [1, 0, 0]),
      ("wrong-dimension", [1, 0]),
    ]

    let ranked = CosineSimilarity.rank(query: query, candidates: candidates)

    #expect(ranked.count == 1)
    #expect(ranked.first?.id == "valid")
  }

  @Test("rank with empty candidates returns empty array")
  func rankEmptyCandidates() {
    let query: [Float] = [1, 0, 0]
    let candidates: [(id: String, vector: [Float])] = []
    let ranked = CosineSimilarity.rank(query: query, candidates: candidates)
    #expect(ranked.isEmpty)
  }

  @Test("rank with limit larger than candidates returns all")
  func rankLimitLargerThanCandidates() {
    let query: [Float] = [1, 0]
    let candidates: [(id: Int, vector: [Float])] = [
      (0, [1, 0]),
      (1, [0, 1]),
    ]

    let ranked = CosineSimilarity.rank(query: query, candidates: candidates, limit: 100)
    #expect(ranked.count == 2)
  }
}
