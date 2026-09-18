// MetalSearchEngineTests.swift
// AuraKitTests — Metal GPU Search
//
// Test suite for MetalSearchEngine cosine similarity GPU pipeline.
// Tests cover correctness (identical, orthogonal, opposite vectors),
// result ordering, edge cases, and performance benchmarks.

import Testing
import Foundation
@testable import AuraKit

// MARK: - MetalSearchEngineTests

@Suite("MetalSearchEngine — GPU Cosine Similarity Search")
struct MetalSearchEngineTests {

  // MARK: - Helper: Create Engine

  /// Attempts to create a MetalSearchEngine. Returns nil if Metal is unavailable.
  private func makeEngine(
    dimension: Int = 4,
    maxVectorCount: Int = 1_000,
    threadgroupSize: Int = 256
  ) -> MetalSearchEngine? {
    let config = try? MetalSearchConfiguration(
      vectorDimension: dimension,
      maxVectorCount: maxVectorCount,
      threadgroupSize: threadgroupSize
    )
    guard let config else { return nil }
    return try? MetalSearchEngine(config: config)
  }

  // MARK: - Correctness Tests

  @Test("Identical vectors produce similarity ≈ 1.0")
  func identicalVectors() async throws {
    guard let engine = makeEngine(dimension: 4) else {
      // Metal unavailable — skip test gracefully
      return
    }

    let vector: [Float] = [1.0, 2.0, 3.0, 4.0]
    let id = UUID()

    let results = try await engine.search(
      query: vector,
      vectors: [vector],
      ids: [id],
      topK: 1
    )

    #expect(results.count == 1)
    #expect(results[0].id == id)
    // Cosine similarity of identical vectors should be ~1.0
    #expect(results[0].similarity > 0.999)
  }

  @Test("Orthogonal vectors produce similarity ≈ 0.0")
  func orthogonalVectors() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let query: [Float] = [1.0, 0.0, 0.0, 0.0]
    let orthogonal: [Float] = [0.0, 1.0, 0.0, 0.0]
    let id = UUID()

    let results = try await engine.search(
      query: query,
      vectors: [orthogonal],
      ids: [id],
      topK: 1
    )

    #expect(results.count == 1)
    #expect(abs(results[0].similarity) < 0.001)
  }

  @Test("Opposite vectors produce similarity ≈ -1.0")
  func oppositeVectors() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let query: [Float] = [1.0, 2.0, 3.0, 4.0]
    let opposite: [Float] = [-1.0, -2.0, -3.0, -4.0]
    let id = UUID()

    let results = try await engine.search(
      query: query,
      vectors: [opposite],
      ids: [id],
      topK: 1
    )

    #expect(results.count == 1)
    #expect(results[0].similarity < -0.999)
  }

  @Test("Multiple vectors sorted by descending similarity")
  func topKResultsOrdering() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let query: [Float] = [1.0, 0.0, 0.0, 0.0]

    // Three vectors with known similarities:
    // identical → 1.0, 45° → ~0.707, orthogonal → 0.0
    let identical: [Float] = [1.0, 0.0, 0.0, 0.0]
    let similar: [Float] = [1.0, 1.0, 0.0, 0.0] // cos(45°) ≈ 0.707
    let orthogonal: [Float] = [0.0, 1.0, 0.0, 0.0]

    let ids = [UUID(), UUID(), UUID()]

    let results = try await engine.search(
      query: query,
      vectors: [identical, similar, orthogonal],
      ids: ids,
      topK: 3
    )

    #expect(results.count == 3)

    // Verify descending similarity order
    #expect(results[0].similarity >= results[1].similarity)
    #expect(results[1].similarity >= results[2].similarity)

    // Verify the most similar is the identical vector
    #expect(results[0].id == ids[0])
    #expect(results[0].similarity > 0.999)

    // Verify the 45° vector is in the middle
    #expect(results[1].id == ids[1])
    #expect(results[1].similarity > 0.7)
    #expect(results[1].similarity < 0.72)
  }

  @Test("TopK limits result count")
  func topKLimit() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let query: [Float] = [1.0, 0.0, 0.0, 0.0]
    let vectors: [[Float]] = (0..<10).map { i in
      [Float(i), 1.0, 0.0, 0.0]
    }
    let ids = (0..<10).map { _ in UUID() }

    let results = try await engine.search(
      query: query,
      vectors: vectors,
      ids: ids,
      topK: 3
    )

    #expect(results.count == 3)
  }

  // MARK: - Edge Cases

  @Test("Empty vector store returns empty results")
  func emptyVectorStore() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let results = try await engine.search(
      query: [1.0, 0.0, 0.0, 0.0],
      vectors: [],
      ids: [],
      topK: 10
    )

    #expect(results.isEmpty)
  }

  @Test("Zero-magnitude vector returns similarity 0.0")
  func zeroMagnitudeVector() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let query: [Float] = [1.0, 0.0, 0.0, 0.0]
    let zeroVector: [Float] = [0.0, 0.0, 0.0, 0.0]
    let id = UUID()

    let results = try await engine.search(
      query: query,
      vectors: [zeroVector],
      ids: [id],
      topK: 1
    )

    #expect(results.count == 1)
    #expect(abs(results[0].similarity) < 0.001)
  }

  @Test("Dimension mismatch throws vectorSearchFailed")
  func dimensionMismatch() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    // Query has wrong dimension
    let wrongDimensionQuery: [Float] = [1.0, 0.0]

    do {
      _ = try await engine.search(
        query: wrongDimensionQuery,
        vectors: [[1.0, 0.0, 0.0, 0.0]],
        ids: [UUID()],
        topK: 1
      )
      Issue.record("Expected vectorSearchFailed error")
    } catch let error as AuraError {
      #expect(error == .vectorSearchFailed(
        reason: "Query vector dimension 2 does not match configured dimension 4."
      ))
    }
  }

  @Test("Vector/ID count mismatch throws vectorSearchFailed")
  func vectorIDCountMismatch() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    do {
      _ = try await engine.search(
        query: [1.0, 0.0, 0.0, 0.0],
        vectors: [[1.0, 0.0, 0.0, 0.0]],
        ids: [UUID(), UUID()], // More IDs than vectors
        topK: 1
      )
      Issue.record("Expected vectorSearchFailed error")
    } catch let error as AuraError {
      #expect(error == .vectorSearchFailed(
        reason: "Vector count (1) does not match ID count (2)."
      ))
    }
  }

  // MARK: - Configuration Tests

  @Test("Invalid vector dimension throws invalidConfiguration")
  func invalidVectorDimension() throws {
    do {
      _ = try MetalSearchConfiguration(vectorDimension: 0)
      Issue.record("Expected invalidConfiguration error")
    } catch let error as AuraError {
      #expect(error == .invalidConfiguration(
        reason: "vectorDimension must be > 0, got 0"
      ))
    }
  }

  @Test("Default MetalSearchConfiguration has expected values")
  func defaultConfiguration() {
    let config = MetalSearchConfiguration.default
    #expect(config.vectorDimension == 384)
    #expect(config.maxVectorCount == 10_000)
    #expect(config.threadgroupSize == 256)
  }

  // MARK: - Performance Tests

  @Test("Search performance benchmark — 100 vectors, 4D")
  func performanceBenchmark100Vectors() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }

    let query: [Float] = [1.0, 0.5, 0.3, 0.1]
    let vectors: [[Float]] = (0..<100).map { i in
      [Float(i) * 0.01, Float(100 - i) * 0.01, 0.5, 0.3]
    }
    let ids = (0..<100).map { _ in UUID() }

    let clock = ContinuousClock()
    let start = clock.now

    let results = try await engine.search(
      query: query,
      vectors: vectors,
      ids: ids,
      topK: 10
    )

    let elapsed = clock.now - start

    #expect(results.count == 10)
    // Verify results are sorted by descending similarity
    for i in 0..<(results.count - 1) {
      #expect(results[i].similarity >= results[i + 1].similarity)
    }

    // Log elapsed time for diagnostics
    let elapsedMs = Double(elapsed.components.attoseconds) / 1e15
    print("[AuraKit] MetalSearchEngine benchmark: 100 vectors in \(String(format: "%.3f", elapsedMs))ms")
  }

  // MARK: - Metal Unavailability

  @Test("MetalSearchEngine error codes are correct")
  func errorCodes() {
    let metalError = AuraError.metalUnavailable(reason: "test")
    let searchError = AuraError.vectorSearchFailed(reason: "test")

    #expect(metalError.errorCode == 1_011)
    #expect(searchError.errorCode == 1_012)
  }

  @Test("MetalSearchEngine device name is non-empty")
  func deviceName() async throws {
    guard let engine = makeEngine(dimension: 4) else { return }
    let name = await engine.deviceName
    #expect(!name.isEmpty)
  }
}
