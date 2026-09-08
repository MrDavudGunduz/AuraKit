// AuraKit+StaticAPI.swift
// AuraKit — Convenience Static API
//
// Extracted from AuraKit.swift for file-length compliance and logical separation.
// These static methods delegate to `AuraKit.shared` for ergonomic call-site syntax:
//
//     try AuraKit.configure(with: config)
//     let capture = try AuraKit.capture()
//
// The canonical API surface is the instance methods on `AuraKit.shared`.

import Foundation

// MARK: - AuraKit + Convenience Static API

extension AuraKit {

  /// Convenience static wrapper for ``configure(with:)``.
  ///
  /// Equivalent to `try AuraKit.shared.configure(with: config)`.
  /// - Throws: ``AuraError/alreadyConfigured`` if the pipeline is already active.
  public static func configure(with config: AuraConfiguration) throws {
    try shared.configure(with: config)
  }

  /// Convenience static wrapper for ``configure(with:store:)``.
  ///
  /// Equivalent to `try AuraKit.shared.configure(with: config, store: store)`.
  /// - Throws: ``AuraError/alreadyConfigured`` if the pipeline is already active.
  public static func configure(
    with config: AuraConfiguration,
    store: (any SpatialEventStore)?
  ) throws {
    try shared.configure(with: config, store: store)
  }

  /// Convenience static wrapper for the throwing ``configure(interactionWeight:gazeWeight:bufferCapacity:storeCapacity:)`` overload.
  ///
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter is out of range,
  ///   or ``AuraError/alreadyConfigured`` if the pipeline is already active.
  public static func configure(
    interactionWeight: Double = AuraConfiguration.defaultInteractionWeight,
    gazeWeight: Double = AuraConfiguration.defaultGazeWeight,
    bufferCapacity: Int = AuraConfiguration.defaultBufferCapacity,
    storeCapacity: Int = AuraConfiguration.defaultStoreCapacity
  ) throws {
    try shared.configure(
      interactionWeight: interactionWeight,
      gazeWeight: gazeWeight,
      bufferCapacity: bufferCapacity,
      storeCapacity: storeCapacity
    )
  }

  /// Convenience static wrapper for ``capture()``.
  ///
  /// - Throws: ``AuraError/notConfigured`` if not yet configured.
  public static func capture() throws -> CaptureActor {
    try shared.capture()
  }

  /// Convenience static wrapper for ``captureOrNil``.
  ///
  /// Returns `nil` if not yet configured.
  public static var captureOrNil: CaptureActor? {
    shared.captureOrNil
  }

  /// Convenience static wrapper for ``configureIfNeeded(with:)``.
  ///
  /// Configures the pipeline only if it has not been configured yet.
  /// Safe to call multiple times — subsequent calls are no-ops.
  public static func configureIfNeeded(with config: AuraConfiguration) {
    shared.configureIfNeeded(with: config)
  }

  /// Convenience static wrapper for ``configureIfNeeded(with:store:)``.
  ///
  /// Configures the pipeline with an optional custom store only if it
  /// has not been configured yet.
  public static func configureIfNeeded(
    with config: AuraConfiguration,
    store: (any SpatialEventStore)?
  ) {
    shared.configureIfNeeded(with: config, store: store)
  }

  /// Convenience static wrapper for ``memory``\.
  ///
  /// Provides access to the memory management API for cognitive compression:
  ///
  /// ```swift
  /// let report = try await AuraKit.memory.compressIdleMemories()
  /// ```
  ///
  /// - Throws: ``AuraError/notConfigured`` if not yet configured.
  public static var memory: MemoryManager {
    get throws { try shared.memory }
  }

  /// Convenience static wrapper for ``MemoryManager/searchSimilarMemories(queryVector:vectors:ids:topK:config:)``.
  ///
  /// Performs GPU-accelerated cosine similarity search:
  ///
  /// ```swift
  /// let results = try await AuraKit.searchSimilarMemories(
  ///     queryVector: embedding,
  ///     vectors: storedVectors,
  ///     ids: storedIDs,
  ///     topK: 5
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - queryVector: The embedding vector to search for.
  ///   - vectors: The stored memory embedding vectors.
  ///   - ids: The UUIDs corresponding to each vector.
  ///   - topK: Maximum number of results. Default: `10`.
  ///   - config: Metal search configuration. Default: ``MetalSearchConfiguration/default``.
  /// - Returns: An array of ``VectorSearchResult`` sorted by descending similarity.
  /// - Throws: ``AuraError/notConfigured``, ``AuraError/metalUnavailable(reason:)``,
  ///   or ``AuraError/vectorSearchFailed(reason:)``.
  public static func searchSimilarMemories(
    queryVector: [Float],
    vectors: [[Float]],
    ids: [UUID],
    topK: Int = 10,
    config: MetalSearchConfiguration = .default
  ) async throws -> [VectorSearchResult] {
    try await memory.searchSimilarMemories(
      queryVector: queryVector,
      vectors: vectors,
      ids: ids,
      topK: topK,
      config: config
    )
  }
}

