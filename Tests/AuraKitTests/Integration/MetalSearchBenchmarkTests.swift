// MetalSearchBenchmarkTests.swift
// AuraKitTests — Performance Regression Detection
//
// Validates that MetalSearchEngine meets its documented performance targets.
// Uses ContinuousClock with generous thresholds to account for CI runner
// variability while catching catastrophic regressions.
//
// Performance targets from README.md / ARCHITECTURE.md:
// - < 0.5ms for 1,000 vectors (384-dimensional)
// - < 2ms for 10,000 vectors
//
// Note: Metal availability depends on the hardware. These tests are skipped
// on platforms where Metal is unavailable (e.g., Linux CI, some simulators).

import Foundation
import Testing

@testable import AuraKit

// MARK: - MetalSearchEngine Benchmark Helpers

/// Generates a random Float array of the given dimension for vector search testing.
private func randomVector(dimension: Int) -> [Float] {
  (0..<dimension).map { _ in Float.random(in: -1.0...1.0) }
}

/// Generates an array of random vectors for benchmark testing.
private func randomVectors(count: Int, dimension: Int) -> [[Float]] {
  (0..<count).map { _ in randomVector(dimension: dimension) }
}

// MARK: - MetalSearchEngine Performance

@Suite("Performance — MetalSearchEngine Benchmarks")
struct MetalSearchBenchmarkTests {

  @Test("Search across 100 vectors completes under 50ms")
  func search100Vectors() async throws {
    let dimension = 384
    let vectorCount = 100

    let engine: MetalSearchEngine
    do {
      engine = try MetalSearchEngine()
    } catch AuraError.metalUnavailable {
      // Metal not available on this platform — skip
      return
    }

    let query = randomVector(dimension: dimension)
    let vectors = randomVectors(count: vectorCount, dimension: dimension)
    let ids = (0..<vectorCount).map { _ in UUID() }

    // Warm-up pass
    _ = try await engine.search(query: query, vectors: vectors, ids: ids, topK: 5)

    // Measured pass
    let start = ContinuousClock.now
    let results = try await engine.search(
      query: query,
      vectors: vectors,
      ids: ids,
      topK: 10
    )
    let elapsed = ContinuousClock.now - start

    #expect(results.count <= 10)
    #expect(
      elapsed < .milliseconds(50),
      "Search across 100 vectors took \(elapsed) — expected < 50ms"
    )
  }

  @Test("Search across 1,000 vectors completes under 100ms")
  func search1KVectors() async throws {
    let dimension = 384
    let vectorCount = 1_000

    let engine: MetalSearchEngine
    do {
      engine = try MetalSearchEngine()
    } catch AuraError.metalUnavailable {
      return
    }

    let query = randomVector(dimension: dimension)
    let vectors = randomVectors(count: vectorCount, dimension: dimension)
    let ids = (0..<vectorCount).map { _ in UUID() }

    // Warm-up pass
    _ = try await engine.search(query: query, vectors: vectors, ids: ids, topK: 5)

    // Measured pass
    let start = ContinuousClock.now
    let results = try await engine.search(
      query: query,
      vectors: vectors,
      ids: ids,
      topK: 10
    )
    let elapsed = ContinuousClock.now - start

    #expect(results.count == 10)
    #expect(
      elapsed < .milliseconds(100),
      "Search across 1K vectors took \(elapsed) — expected < 100ms"
    )
  }

  @Test("Repeated searches benefit from engine caching (no re-initialization)")
  func cachedEngineRepeatedSearch() async throws {
    let dimension = 384
    let vectorCount = 500

    let engine: MetalSearchEngine
    do {
      engine = try MetalSearchEngine()
    } catch AuraError.metalUnavailable {
      return
    }

    let query = randomVector(dimension: dimension)
    let vectors = randomVectors(count: vectorCount, dimension: dimension)
    let ids = (0..<vectorCount).map { _ in UUID() }

    // Warm-up
    _ = try await engine.search(query: query, vectors: vectors, ids: ids, topK: 5)

    // Run 10 sequential searches on the same engine instance
    let start = ContinuousClock.now
    for _ in 0..<10 {
      _ = try await engine.search(
        query: randomVector(dimension: dimension),
        vectors: vectors,
        ids: ids,
        topK: 5
      )
    }
    let elapsed = ContinuousClock.now - start

    // 10 searches at < 100ms each = < 1s total; generous threshold for CI
    #expect(
      elapsed < .seconds(2),
      "10 sequential searches on cached engine took \(elapsed) — expected < 2s"
    )
  }

  @Test("Similarity results are correctly sorted in descending order")
  func resultsSortedDescending() async throws {
    let dimension = 384
    let vectorCount = 50

    let engine: MetalSearchEngine
    do {
      engine = try MetalSearchEngine()
    } catch AuraError.metalUnavailable {
      return
    }

    let query = randomVector(dimension: dimension)
    let vectors = randomVectors(count: vectorCount, dimension: dimension)
    let ids = (0..<vectorCount).map { _ in UUID() }

    let results = try await engine.search(
      query: query,
      vectors: vectors,
      ids: ids,
      topK: vectorCount
    )

    // Verify descending sort order
    for i in 1..<results.count {
      #expect(
        results[i - 1].similarity >= results[i].similarity,
        "Results not sorted: index \(i - 1) (\(results[i - 1].similarity)) < index \(i) (\(results[i].similarity))"
      )
    }
  }
}
