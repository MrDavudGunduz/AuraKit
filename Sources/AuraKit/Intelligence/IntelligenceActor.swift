// IntelligenceActor.swift
// AuraKit — Intelligence & Semantic Memory Layer
//
// Dedicated actor executing network-isolated LLM inference and Survival Index pruning.
// Phase 4 adds cognitive compression: consolidating low-SI clusters into archive nodes.

import Foundation
import os.log

/// Dedicated actor executing network-isolated LLM inference, semantic pruning,
/// and cognitive compression.
///
/// `IntelligenceActor` orchestrates Phase 3 on-device intelligence and Phase 4
/// cognitive compression:
///
/// ### Phase 3 — Semantic Pruning
///
/// ```
/// Batch Events → BatchPromptBuilder → MLXModelProvider (Sandbox)
///                  ↓
///             SurvivalIndexParser → SurvivalIndex.calculate(S₀, n, t, λ, R)
///                  ↓
///             Prune nodes where SI < threshold from SpatialEventStore
/// ```
///
/// ### Phase 4 — Cognitive Compression
///
/// ```
/// fetchNodesBelowThreshold(SI)
///     → ConsolidationPromptBuilder → MLXModelProvider.infer()
///         → EncryptionService.encrypt(summary)
///             → MemoryArchiveNode(encryptedSummary)
///                 → archiveAndPruneNodes() — atomic commit
/// ```
public actor IntelligenceActor {

  // MARK: - Logger

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "IntelligenceActor"
  )

  // MARK: - Properties

  private let modelProvider: any MLXModelProvider
  private let store: any SpatialEventStore
  private let config: AuraConfiguration

  // MARK: - Compression Telemetry

  /// Continuation for the compression event notification stream.
  private let _compressionContinuation: AsyncStream<MemoryCompressionEvent>.Continuation

  /// An `AsyncStream` that emits a ``MemoryCompressionEvent`` at each phase
  /// of a cognitive compression operation.
  ///
  /// Subscribe to this stream for real-time telemetry during compression:
  ///
  /// ```swift
  /// Task {
  ///     for await event in await intelligence.compressionEventStream {
  ///         logger.info("Compression: \(event.phase.rawValue) — \(event.detail)")
  ///     }
  /// }
  /// ```
  ///
  /// The stream is infinite — it never finishes on its own. It yields events
  /// only during active compression operations.
  ///
  /// - Note: The stream uses a buffer policy of `.bufferingNewest(32)` to prevent
  ///   unbounded memory growth if the consumer falls behind.
  public let compressionEventStream: AsyncStream<MemoryCompressionEvent>

  // MARK: - Init

  /// Initializes an `IntelligenceActor`.
  ///
  /// - Parameters:
  ///   - config: Configuration specifying thresholds and formula coefficients.
  ///   - store: Target persistence store for semantic pruning and compression.
  ///   - modelProvider: Network-isolated LLM model provider.
  public init(
    config: AuraConfiguration = .default,
    store: any SpatialEventStore,
    modelProvider: (any MLXModelProvider)? = nil
  ) {
    self.config = config
    self.store = store
    self.modelProvider = modelProvider ?? SandboxedMLXModelProvider()

    var continuation: AsyncStream<MemoryCompressionEvent>.Continuation!
    self.compressionEventStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
      continuation = $0
    }
    self._compressionContinuation = continuation
  }

  // MARK: - Public API — Phase 3 Evaluation

  /// Evaluates a batch of spatial events using the on-device LLM and Survival Index formula.
  ///
  /// - Parameters:
  ///   - events: The batch of events to evaluate (e.g., drained from L1 RingBuffer).
  ///   - referenceDate: Reference timestamp for age calculation ($t$).
  /// - Returns: Array of evaluated events with updated Survival Index scores.
  public func evaluateBatch(
    _ events: [SpatialEvent],
    referenceDate: Date = Date()
  ) async throws -> [SpatialEvent] {
    guard !events.isEmpty else { return [] }

    // 1. Serialize events into JSON prompt
    let prompt = BatchPromptBuilder.build(from: events)

    // 2. Perform network-isolated on-device LLM inference pass
    let rawOutput = try await modelProvider.infer(prompt: prompt)

    // 3. Parse scored manifest from LLM output
    let parsedScores = SurvivalIndexParser.parse(rawOutput, referencing: events)

    // 4. Calculate Survival Index for each event and construct updated models
    var evaluatedEvents: [SpatialEvent] = []
    evaluatedEvents.reserveCapacity(events.count)

    for event in events {
      let initialScore = parsedScores[event.id] ?? event.score
      let ageInSeconds = referenceDate.timeIntervalSince(event.timestamp)

      // Calculate SI(t) = S₀ · Rⁿ · e^(-λt)
      let calculatedSI = SurvivalIndex.calculate(
        initialScore: initialScore,
        recallCount: 0,
        ageInSeconds: ageInSeconds,
        decayConstant: config.intelligence.decayConstant,
        recallMultiplier: config.intelligence.recallMultiplier
      )

      evaluatedEvents.append(event.withScore(calculatedSI))
    }

    return evaluatedEvents
  }

  /// Evaluates the batch and automatically prunes low-SI nodes from the backing store.
  ///
  /// - Parameters:
  ///   - events: Events to evaluate and prune.
  ///   - referenceDate: Reference date for decay calculation.
  /// - Returns: Tuple containing (evaluatedEvents, prunedCount).
  @discardableResult
  public func processAndPrune(
    _ events: [SpatialEvent],
    referenceDate: Date = Date()
  ) async throws -> (evaluatedEvents: [SpatialEvent], prunedCount: Int) {
    let evaluated = try await evaluateBatch(events, referenceDate: referenceDate)

    var pruneIDs = Set<UUID>()
    for event in evaluated {
      if event.score < config.intelligence.survivalIndexThreshold {
        pruneIDs.insert(event.id)
      }
    }

    let deletedCount: Int
    if !pruneIDs.isEmpty {
      deletedCount = await store.removeEvents(withIDs: pruneIDs)
      Self.logger.info("[AuraKit] IntelligenceActor: Pruned \(deletedCount) events below SI threshold \(self.config.intelligence.survivalIndexThreshold).")
    } else {
      deletedCount = 0
    }

    return (evaluated, deletedCount)
  }

  // MARK: - Public API — Phase 4 Cognitive Compression

  /// Compresses idle memories below the Survival Index threshold into a single
  /// semantic archive node.
  ///
  /// This is the core Phase 4 cognitive compression API. The full pipeline:
  ///
  /// 1. `EncryptedMemoryStore` selects all nodes below the SI threshold
  /// 2. MLX analyzes them in a single prompt: _"Summarize the key spatial events
  ///    in one sentence."_
  /// 3. The resulting natural-language summary is encrypted with AES-GCM
  /// 4. A ``MemoryArchiveNode`` is written with the encrypted summary
  /// 5. Source ``RawMemoryNode`` records are deleted atomically
  ///
  /// ## IoC Design
  ///
  /// Compression is **never automatic**. The host application triggers it
  /// explicitly to avoid FPS drops:
  ///
  /// ```swift
  /// // Safe to call during loading screens, cutscenes, or in-game sleep sessions
  /// try await AuraKit.shared.memory.compressIdleMemories()
  /// ```
  ///
  /// ## Requirements
  ///
  /// This method requires the backing store to be an ``EncryptedMemoryStore``.
  /// When configured with a ``MemoryStore`` (Phase 1 in-memory store),
  /// compression is not supported and throws ``AuraError/compressionFailed(reason:)``.
  ///
  /// - Returns: A ``CompressionReport`` describing the outcome.
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if compression fails.
  public func compressIdleMemories() async throws -> CompressionReport {
    let startTime = ContinuousClock.now
    emitCompressionEvent(.started, detail: "Compression operation started.")

    let encryptedStore = try validateEncryptedStore()
    let threshold = config.intelligence.survivalIndexThreshold
    let snapshots = await encryptedStore.fetchNodesBelowThreshold(threshold)

    guard !snapshots.isEmpty else {
      emitCompressionEvent(.completed, detail: "No nodes below SI threshold \(threshold). Nothing to compress.")
      return .empty
    }

    let signpostID = SignpostLogger.beginCompression(nodeCount: snapshots.count)

    emitCompressionEvent(.nodesSelected, detail: "Selected \(snapshots.count) nodes below SI threshold \(threshold).")
    Self.logger.info("[AuraKit] IntelligenceActor: Compression — \(snapshots.count) nodes selected below SI \(threshold).")

    let summaryText = try await generateConsolidatedSummary(for: snapshots, signpostID: signpostID)
    let encryptedSummaryData = try await encryptSummary(summaryText, using: encryptedStore.keyManager, signpostID: signpostID)

    let sourceNodeIDs = Set(snapshots.map(\.id))
    let bytesRecovered = await encryptedStore.totalPayloadSize(for: sourceNodeIDs)
    let archiveNodeID = UUID()

    emitCompressionEvent(.archiveCreated, detail: "Archive node \(archiveNodeID) created with \(snapshots.count) source references.")
    try await commitCompressionTransaction(
      store: encryptedStore,
      encryptedSummary: encryptedSummaryData,
      sourceNodeIDs: sourceNodeIDs,
      archiveNodeID: archiveNodeID,
      signpostID: signpostID
    )

    SignpostLogger.endCompression(signpostID)
    let report = CompressionReport(
      nodesPruned: sourceNodeIDs.count,
      archiveNodesCreated: 1,
      bytesRecovered: bytesRecovered,
      summary: summaryText,
      archiveNodeID: archiveNodeID,
      duration: startTime.duration(to: ContinuousClock.now)
    )

    emitCompressionEvent(
      .completed,
      detail: "Compression completed — \(report.nodesPruned) nodes → 1 archive, \(report.bytesRecovered) bytes recovered."
    )
    Self.logger.info(
      "[AuraKit] IntelligenceActor: Compression completed — \(report.nodesPruned) nodes consolidated into archive \(archiveNodeID)."
    )
    return report
  }

  // MARK: - Private Compression Helpers

  private func validateEncryptedStore() throws -> EncryptedMemoryStore {
    guard let encryptedStore = store as? EncryptedMemoryStore else {
      let error = AuraError.compressionFailed(
        reason: "Cognitive compression requires EncryptedMemoryStore. The current store type does not support archive operations."
      )
      emitCompressionEvent(.failed, detail: error.localizedDescription)
      throw error
    }
    return encryptedStore
  }

  private func generateConsolidatedSummary(
    for snapshots: [RawMemoryNodeSnapshot],
    signpostID: OSSignpostID
  ) async throws -> String {
    let prompt = ConsolidationPromptBuilder.build(from: snapshots)
    do {
      let summaryText = try await modelProvider.infer(prompt: prompt)
      emitCompressionEvent(.summaryGenerated, detail: "Summary generated (\(summaryText.count) characters).")
      return summaryText
    } catch {
      SignpostLogger.endCompression(signpostID)
      let compressionError = AuraError.compressionFailed(reason: "LLM inference failed: \(error.localizedDescription)")
      emitCompressionEvent(.failed, detail: compressionError.localizedDescription)
      throw compressionError
    }
  }

  private func encryptSummary(
    _ summaryText: String,
    using keyManager: KeyManager,
    signpostID: OSSignpostID
  ) async throws -> Data {
    do {
      let encryptionService = EncryptionService()
      let key = try await keyManager.symmetricKey()
      let summaryData = Data(summaryText.utf8)
      return try encryptionService.encrypt(summaryData, using: key)
    } catch {
      SignpostLogger.endCompression(signpostID)
      let compressionError = AuraError.compressionFailed(reason: "Summary encryption failed: \(error.localizedDescription)")
      emitCompressionEvent(.failed, detail: compressionError.localizedDescription)
      throw compressionError
    }
  }

  private func commitCompressionTransaction(
    store: EncryptedMemoryStore,
    encryptedSummary: Data,
    sourceNodeIDs: Set<UUID>,
    archiveNodeID: UUID,
    signpostID: OSSignpostID
  ) async throws {
    do {
      try await store.archiveAndPruneNodes(
        encryptedSummary: encryptedSummary,
        sourceNodeIDs: sourceNodeIDs,
        archiveNodeID: archiveNodeID
      )
      emitCompressionEvent(.sourceNodesDeleted, detail: "Deleted \(sourceNodeIDs.count) source nodes.")
    } catch {
      SignpostLogger.endCompression(signpostID)
      emitCompressionEvent(.failed, detail: "Archive-and-prune transaction failed: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Telemetry Helpers

  /// Emits a ``MemoryCompressionEvent`` to the telemetry stream.
  private func emitCompressionEvent(_ phase: MemoryCompressionEvent.Phase, detail: String) {
    _compressionContinuation.yield(
      MemoryCompressionEvent(phase: phase, detail: detail)
    )
  }
}
