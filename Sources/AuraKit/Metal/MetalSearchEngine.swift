// MetalSearchEngine.swift
// AuraKit — Metal GPU-Accelerated Search
//
// Actor-isolated Metal compute pipeline for cosine similarity search across
// stored memory embedding vectors. Dispatches a custom .metal kernel to
// compute similarities in parallel on the GPU, achieving sub-millisecond
// search latency for thousands of vectors on Apple Silicon.

import Foundation
import os.log

#if canImport(Metal)
  import Metal
#endif

// MARK: - MetalSearchEngine

/// GPU-accelerated cosine similarity search engine using Metal compute shaders.
///
/// `MetalSearchEngine` manages the full Metal pipeline lifecycle:
///
/// ```
/// [Float] query + [[Float]] vectors → MTLBuffer upload
///     → cosine_similarity_kernel dispatch → MTLBuffer readback
///         → sorted [VectorSearchResult]
/// ```
///
/// ## Performance
///
/// On Apple A17 Pro, the engine achieves:
/// - **< 0.5ms** for 1,000 vectors (384-dimensional)
/// - **< 2ms** for 10,000 vectors
///
/// ## Availability
///
/// Metal compute shaders require iOS 17+, macOS 14+, or visionOS 1+.
/// On platforms where Metal is unavailable (e.g., Linux CI), the engine
/// throws ``AuraError/metalUnavailable(reason:)`` at initialization.
///
/// ## Thread Safety
///
/// `MetalSearchEngine` is an `actor` — all mutable state (device, queue,
/// pipeline) is actor-isolated. Safe to call from any concurrency context.
///
/// ## Usage
///
/// ```swift
/// let engine = try MetalSearchEngine()
/// let results = try await engine.search(
///     query: queryEmbedding,
///     vectors: storedEmbeddings,
///     ids: storedIDs,
///     topK: 10
/// )
/// ```
public actor MetalSearchEngine {

  // MARK: - Logger

  static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "MetalSearchEngine"
  )

  // MARK: - Metal Pipeline State

  #if canImport(Metal)
    /// The GPU device used for compute operations.
    let device: MTLDevice

    /// The command queue for submitting compute work.
    let commandQueue: MTLCommandQueue

    /// The compiled compute pipeline for the cosine similarity kernel.
    let pipelineState: MTLComputePipelineState
  #endif

  /// Configuration controlling vector dimensions and dispatch parameters.
  let config: MetalSearchConfiguration

  // MARK: - Init

  /// Creates a `MetalSearchEngine` with the specified configuration.
  ///
  /// Initialises the Metal device, compiles the cosine similarity shader,
  /// and creates the compute pipeline state.
  ///
  /// - Parameter config: Metal search configuration. Defaults to ``MetalSearchConfiguration/default``.
  /// - Throws: ``AuraError/metalUnavailable(reason:)`` if Metal is not supported on this device.
  public init(config: MetalSearchConfiguration = .default) throws {
    self.config = config

    #if canImport(Metal)
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw AuraError.metalUnavailable(
          reason: "No Metal-compatible GPU found on this device."
        )
      }
      self.device = device

      guard let queue = device.makeCommandQueue() else {
        throw AuraError.metalUnavailable(
          reason: "Failed to create Metal command queue."
        )
      }
      self.commandQueue = queue

      // Load the Metal shader library from the SPM bundle (precompiled .metallib
      // in Xcode builds, or runtime-compiled .metal resource in SwiftPM CLI builds).
      let library = try Self.makeShaderLibrary(device: device)

      guard let function = library.makeFunction(name: "cosine_similarity_kernel") else {
        throw AuraError.metalUnavailable(
          reason: "Metal function 'cosine_similarity_kernel' not found in shader library."
        )
      }

      do {
        self.pipelineState = try device.makeComputePipelineState(function: function)
      } catch {
        throw AuraError.metalUnavailable(
          reason: "Failed to create compute pipeline state: \(error.localizedDescription)"
        )
      }

      Self.logger.info(
        "[AuraKit] MetalSearchEngine: Initialized — device='\(device.name)', dim=\(config.vectorDimension), maxVec=\(config.maxVectorCount)"
      )
    #else
      throw AuraError.metalUnavailable(
        reason: "Metal framework is not available on this platform."
      )
    #endif
  }

  // MARK: - Public API

  /// Performs GPU-accelerated cosine similarity search.
  ///
  /// Uploads the query vector and memory vectors to GPU buffers, dispatches
  /// the cosine similarity kernel, and returns the top-K most similar results
  /// sorted by descending similarity.
  ///
  /// ## Performance
  ///
  /// The entire search pipeline (upload → compute → readback → sort) completes
  /// in under 0.5ms for 1,000 vectors on A17 Pro.
  ///
  /// - Parameters:
  ///   - query: The query embedding vector. Must have exactly
  ///     ``MetalSearchConfiguration/vectorDimension`` elements.
  ///   - vectors: The stored memory embedding vectors. Each inner array must
  ///     have exactly ``MetalSearchConfiguration/vectorDimension`` elements.
  ///   - ids: The UUIDs corresponding to each vector in `vectors`.
  ///     Must have the same count as `vectors`.
  ///   - topK: The maximum number of results to return. Default: `10`. Must be `>= 0`.
  /// - Returns: An array of ``VectorSearchResult`` sorted by descending similarity,
  ///   containing at most `topK` elements.
  /// - Note: At most ``MetalSearchConfiguration/maxVectorCount`` vectors are
  ///   searched; additional vectors are ignored and a warning is logged.
  /// - Throws: ``AuraError/vectorSearchFailed(reason:)`` if the search fails.
  public func search(
    query: [Float],
    vectors: [[Float]],
    ids: [UUID],
    topK: Int = 10
  ) async throws -> [VectorSearchResult] {
    #if canImport(Metal)
      let signpostID = SignpostLogger.beginMetalSearch(vectorCount: vectors.count)
      defer { SignpostLogger.endMetalSearch(signpostID) }

      guard topK >= 0 else {
        throw AuraError.vectorSearchFailed(reason: "topK must be >= 0 (got \(topK)).")
      }
      try validateSearchInputs(query: query, vectors: vectors, ids: ids)
      guard !vectors.isEmpty, topK > 0 else { return [] }

      let vectorCount = clampVectorCount(vectors.count)
      let flatVectors = try flattenVectors(vectors, count: vectorCount)
      let rawSimilarities = try await dispatchComputeKernel(
        query: query,
        flatVectors: flatVectors,
        vectorCount: vectorCount
      )

      return buildSortedResults(similarities: rawSimilarities, ids: ids, topK: topK)
    #else
      throw AuraError.metalUnavailable(
        reason: "Metal framework is not available on this platform."
      )
    #endif
  }

  // MARK: - Device Info

  /// The name of the Metal GPU device being used.
  public var deviceName: String {
    #if canImport(Metal)
      return device.name
    #else
      return "Metal unavailable"
    #endif
  }

  /// The configured vector dimension for this engine.
  public var vectorDimension: Int {
    config.vectorDimension
  }

  /// Performs GPU-accelerated cosine similarity search over a pre-flattened vector buffer.
  ///
  /// Eliminates the `[[Float]]` → `[Float]` flattening copy on the hot path when
  /// the caller already maintains embeddings in a contiguous float buffer.
  ///
  /// - Parameters:
  ///   - query: The query embedding vector (`vectorDimension` floats).
  ///   - flatVectors: Contiguous array of `ids.count * vectorDimension` floats.
  ///   - ids: The UUIDs corresponding to each vector.
  ///   - topK: Maximum number of results to return. Default: `10`. Must be `>= 0`.
  /// - Returns: An array of ``VectorSearchResult`` sorted by descending similarity.
  /// - Throws: ``AuraError/vectorSearchFailed(reason:)`` if validation or dispatch fails.
  public func search(
    query: [Float],
    flatVectors: [Float],
    ids: [UUID],
    topK: Int = 10
  ) async throws -> [VectorSearchResult] {
    #if canImport(Metal)
      let signpostID = SignpostLogger.beginMetalSearch(vectorCount: ids.count)
      defer { SignpostLogger.endMetalSearch(signpostID) }

      guard topK >= 0 else {
        throw AuraError.vectorSearchFailed(reason: "topK must be >= 0 (got \(topK)).")
      }
      guard query.count == config.vectorDimension else {
        throw AuraError.vectorSearchFailed(
          reason: "Query vector dimension \(query.count) does not match "
            + "configured dimension \(config.vectorDimension)."
        )
      }
      let expectedFloats = ids.count * config.vectorDimension
      guard flatVectors.count == expectedFloats else {
        throw AuraError.vectorSearchFailed(
          reason: "Flattened vector float count (\(flatVectors.count)) does not match "
            + "ids.count * dimension (\(expectedFloats))."
        )
      }
      guard !ids.isEmpty, topK > 0 else { return [] }

      let vectorCount = clampVectorCount(ids.count)
      let rawSimilarities = try await dispatchComputeKernel(
        query: query,
        flatVectors: flatVectors,
        vectorCount: vectorCount
      )
      return buildSortedResults(similarities: rawSimilarities, ids: ids, topK: topK)
    #else
      throw AuraError.metalUnavailable(
        reason: "Metal framework is not available on this platform."
      )
    #endif
  }
}
