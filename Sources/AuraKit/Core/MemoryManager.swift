// MemoryManager.swift
// AuraKit — Core
//
// The public IoC surface for Phase 4 cognitive compression.
// MemoryManager provides the developer-controlled API for triggering
// memory consolidation operations — compression is never automatic.

import Foundation
import os.log

// MARK: - MemoryManager

/// The public API surface for AuraKit's memory management operations,
/// including Phase 4 cognitive compression.
///
/// `MemoryManager` is the **Inversion of Control** gateway — compression
/// is never triggered automatically by the framework. The host application
/// explicitly calls ``compressIdleMemories()`` at safe points (loading
/// screens, cutscenes, or in-game sleep sessions) to avoid FPS drops.
///
/// ## Usage
///
/// ```swift
/// // Safe to call during loading screens, cutscenes, or in-game sleep sessions
/// let report = try await AuraKit.shared.memory.compressIdleMemories()
/// logger.info("Compressed \(report.nodesPruned) nodes → \(report.archiveNodesCreated) archive(s)")
/// ```
///
/// ## Concurrency
///
/// All operations are `async throws` — fully non-blocking. The compression
/// pipeline runs on the ``IntelligenceActor``'s executor, never on the
/// main thread.
///
/// ## Thread Safety
///
/// `MemoryManager` is a lightweight `Sendable` struct that holds only actor
/// references. It can be passed across concurrency boundaries freely.
public struct MemoryManager: Sendable {

  // MARK: - Internal Logger

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "MemoryManager"
  )

  // MARK: - Dependencies

  /// The capture actor providing access to intelligence and store.
  private let captureActor: CaptureActor

  // MARK: - Init

  /// Creates a `MemoryManager` backed by the given capture actor.
  ///
  /// - Parameter captureActor: The active ``CaptureActor`` from the
  ///   configured AuraKit pipeline.
  init(captureActor: CaptureActor) {
    self.captureActor = captureActor
  }

  // MARK: - Public API

  /// Compresses idle memories below the Survival Index threshold into a
  /// single semantic archive node.
  ///
  /// This method triggers the full Phase 4 cognitive compression pipeline:
  ///
  /// 1. Selects all ``RawMemoryNode`` records below the SI threshold
  /// 2. Generates a natural-language summary via on-device LLM
  /// 3. Encrypts the summary and creates a ``MemoryArchiveNode``
  /// 4. Atomically deletes the source nodes
  ///
  /// ## When to Call
  ///
  /// Compression is **never automatic** — the host application controls
  /// exactly when it runs to avoid FPS drops:
  ///
  /// ```swift
  /// // ✅ Loading screen — user expects a pause
  /// try await AuraKit.shared.memory.compressIdleMemories()
  ///
  /// // ✅ Cutscene — rendering is non-interactive
  /// try await AuraKit.shared.memory.compressIdleMemories()
  ///
  /// // ✅ In-game sleep session — time skip
  /// try await AuraKit.shared.memory.compressIdleMemories()
  ///
  /// // ❌ During active gameplay — will cause FPS drops
  /// ```
  ///
  /// ## Return Value
  ///
  /// Returns a ``CompressionReport`` with:
  /// - ``CompressionReport/nodesPruned``: Number of source nodes deleted
  /// - ``CompressionReport/archiveNodesCreated``: Number of archives created (0 or 1)
  /// - ``CompressionReport/bytesRecovered``: Estimated bytes freed
  /// - ``CompressionReport/summary``: The LLM-generated summary text
  /// - ``CompressionReport/duration``: Wall-clock time of the operation
  ///
  /// - Returns: A ``CompressionReport`` describing the compression outcome.
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if compression fails.
  public func compressIdleMemories() async throws -> CompressionReport {
    Self.logger.info("[AuraKit] MemoryManager: compressIdleMemories() invoked.")

    let intelligence = await captureActor.intelligenceActor()
    let report = try await intelligence.compressIdleMemories()

    if report.didCompress {
      let pruned = report.nodesPruned
      let created = report.archiveNodesCreated
      let recovered = report.bytesRecovered
      Self.logger.info(
        "[AuraKit] MemoryManager: Compression completed — \(pruned) nodes → \(created) archive(s), \(recovered) bytes recovered."
      )
    } else {
      Self.logger.info("[AuraKit] MemoryManager: No nodes qualified for compression.")
    }

    return report
  }

  /// An `AsyncStream` that emits ``MemoryCompressionEvent`` telemetry
  /// at each phase of a compression operation.
  ///
  /// Subscribe before calling ``compressIdleMemories()`` to receive
  /// real-time progress updates:
  ///
  /// ```swift
  /// Task {
  ///     for await event in try await AuraKit.shared.memory.compressionEvents {
  ///         switch event.phase {
  ///         case .started: showLoadingIndicator()
  ///         case .completed: hideLoadingIndicator()
  ///         case .failed: showError(event.detail)
  ///         default: updateProgress(event.detail)
  ///         }
  ///     }
  /// }
  /// ```
  public var compressionEvents: AsyncStream<MemoryCompressionEvent> {
    get async {
      let intelligence = await captureActor.intelligenceActor()
      return intelligence.compressionEventStream
    }
  }

  // MARK: - Metal GPU Search

  /// Performs a GPU-accelerated cosine similarity search across stored memory vectors.
  ///
  /// Uses Metal compute shaders to search in parallel across all stored embedding
  /// vectors, returning the top-K most similar results sorted by descending
  /// cosine similarity.
  ///
  /// ## Performance
  ///
  /// On Apple A17 Pro, typical search latency is:
  /// - **< 0.5ms** for 1,000 vectors (384-dimensional)
  /// - **< 2ms** for 10,000 vectors
  ///
  /// The ``MetalSearchEngine`` is lazily cached on the ``CaptureActor`` — the
  /// Metal pipeline (device, shader, compute pipeline state) is created once
  /// and reused across all subsequent searches, eliminating per-search
  /// initialization overhead.
  ///
  /// ## When to Call
  ///
  /// Unlike ``compressIdleMemories()``, search is lightweight enough to
  /// call during active gameplay:
  ///
  /// ```swift
  /// // Find memories most similar to the current context
  /// let results = try await AuraKit.shared.memory.searchSimilarMemories(
  ///     queryVector: currentContextEmbedding,
  ///     vectors: storedEmbeddings,
  ///     ids: storedIDs,
  ///     topK: 5
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - queryVector: The embedding vector to search for. Must have exactly
  ///     ``MetalSearchConfiguration/vectorDimension`` elements (default: 384).
  ///   - vectors: The stored memory embedding vectors to search against.
  ///   - ids: The UUIDs corresponding to each vector. Must match `vectors.count`.
  ///   - topK: Maximum number of results to return. Default: `10`.
  ///   - config: Metal search configuration. Default: ``MetalSearchConfiguration/default``.
  /// - Returns: An array of ``VectorSearchResult`` sorted by descending similarity.
  /// - Throws: ``AuraError/metalUnavailable(reason:)`` or
  ///   ``AuraError/vectorSearchFailed(reason:)``.
  public func searchSimilarMemories(
    queryVector: [Float],
    vectors: [[Float]],
    ids: [UUID],
    topK: Int = 10,
    config: MetalSearchConfiguration = .default
  ) async throws -> [VectorSearchResult] {
    Self.logger.info("[AuraKit] MemoryManager: searchSimilarMemories() invoked with \(vectors.count) vectors.")

    let engine = try await captureActor.metalSearchEngine(config: config)
    let results = try await engine.search(
      query: queryVector,
      vectors: vectors,
      ids: ids,
      topK: topK
    )

    Self.logger.info("[AuraKit] MemoryManager: Search returned \(results.count) results.")
    return results
  }
}

