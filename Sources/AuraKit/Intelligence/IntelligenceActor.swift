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

  /// `true` while ``compressIdleMemories(referenceDate:)`` is running.
  ///
  /// Actors are reentrant: without this flag a second call arriving during
  /// the (long) LLM inference would select and archive the same nodes twice.
  private var isCompressing = false

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

    // 4. Resolve recall counts (n) for persisted events. Events that are not
    //    (yet) in an encrypted store — e.g. fresh L1 buffer drains — use n = 0.
    let recallCounts: [UUID: Int]
    if let encryptedStore = store as? EncryptedMemoryStore {
      recallCounts = await encryptedStore.recalledCounts(for: Set(events.map(\.id)))
    } else {
      recallCounts = [:]
    }

    // 5. Calculate Survival Index for each event and construct updated models
    var evaluatedEvents: [SpatialEvent] = []
    evaluatedEvents.reserveCapacity(events.count)

    for event in events {
      let initialScore = parsedScores[event.id] ?? event.score
      let ageInSeconds = referenceDate.timeIntervalSince(event.timestamp)

      // Calculate SI(t) = S₀ · Rⁿ · e^(-λt)
      let calculatedSI = SurvivalIndex.calculate(
        initialScore: initialScore,
        recallCount: recallCounts[event.id] ?? 0,
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
  /// - Important: This is a **destructive** operation driven by model output,
  ///   so it requires a provider with
  ///   ``MLXModelProvider/isProductionInferenceBackend`` set to `true`.
  ///
  /// - Parameters:
  ///   - events: Events to evaluate and prune.
  ///   - referenceDate: Reference date for decay calculation.
  /// - Returns: Tuple containing (evaluatedEvents, prunedCount).
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if the provider is a
  ///   placeholder; any inference error from ``evaluateBatch(_:referenceDate:)``.
  @discardableResult
  public func processAndPrune(
    _ events: [SpatialEvent],
    referenceDate: Date = Date()
  ) async throws -> (evaluatedEvents: [SpatialEvent], prunedCount: Int) {
    try validateProviderForDestructiveOperation(operation: "Semantic pruning")
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
  /// 1. `EncryptedMemoryStore` selects all nodes whose Survival Index
  ///    `SI(t) = S₀·Rⁿ·e^(-λt)` at `referenceDate` is below the threshold
  /// 2. MLX analyzes them in a single prompt: _"Summarize the key spatial events
  ///    in one sentence."_
  /// 3. The resulting natural-language summary is encrypted with AES-GCM,
  ///    bound to the archive ID via AAD
  /// 4. A ``MemoryArchiveNode`` is written with the encrypted summary
  /// 5. Source ``RawMemoryNode`` records that **still exist** are deleted atomically
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
  /// This method requires the backing store to be an ``EncryptedMemoryStore``
  /// and a provider with ``MLXModelProvider/isProductionInferenceBackend``.
  /// Concurrent calls are rejected while a compression is in progress.
  ///
  /// - Parameter referenceDate: Evaluation time for the decay term. Inject a
  ///   fixed date for deterministic tests.
  /// - Returns: A ``CompressionReport`` describing the outcome.
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if compression fails.
  public func compressIdleMemories(referenceDate: Date = Date()) async throws -> CompressionReport {
    guard !isCompressing else {
      throw AuraError.compressionFailed(reason: "A compression operation is already in progress.")
    }
    isCompressing = true
    defer { isCompressing = false }

    let startTime = ContinuousClock.now
    emitCompressionEvent(.started, detail: "Compression operation started.")

    let encryptedStore = try validateEncryptedStore()
    try validateProviderForDestructiveOperation(operation: "Cognitive compression")
    let threshold = config.intelligence.survivalIndexThreshold
    let snapshots = await encryptedStore.fetchNodesBelowSurvivalIndex(
      threshold: threshold,
      decayConstant: config.intelligence.decayConstant,
      recallMultiplier: config.intelligence.recallMultiplier,
      referenceDate: referenceDate
    )

    guard !snapshots.isEmpty else {
      emitCompressionEvent(.completed, detail: "No nodes below SI threshold \(threshold). Nothing to compress.")
      return .empty
    }

    let signpostID = SignpostLogger.beginCompression(nodeCount: snapshots.count)

    emitCompressionEvent(.nodesSelected, detail: "Selected \(snapshots.count) nodes below SI threshold \(threshold).")
    Self.logger.info("[AuraKit] IntelligenceActor: Compression — \(snapshots.count) nodes selected below SI \(threshold).")

    let summaryText = try await generateConsolidatedSummary(for: snapshots, signpostID: signpostID)

    // The archive ID is bound into the ciphertext (AAD), so create it first.
    let archiveNodeID = UUID()
    let encryptedSummaryData = try await encryptSummary(
      summaryText,
      archiveID: archiveNodeID,
      store: encryptedStore,
      signpostID: signpostID
    )

    let sourceNodeIDs = Set(snapshots.map(\.id))
    let bytesRecovered = await encryptedStore.totalPayloadSize(for: sourceNodeIDs)

    emitCompressionEvent(.archiveCreated, detail: "Archive node \(archiveNodeID) created with \(snapshots.count) source references.")
    let prunedCount = try await commitCompressionTransaction(
      store: encryptedStore,
      encryptedSummary: encryptedSummaryData,
      sourceNodeIDs: sourceNodeIDs,
      archiveNodeID: archiveNodeID,
      signpostID: signpostID
    )

    SignpostLogger.endCompression(signpostID)
    let report = CompressionReport(
      nodesPruned: prunedCount,
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

  /// Refuses to run destructive operations with an untrusted provider.
  ///
  /// Compression deletes the source nodes after archiving the model's summary,
  /// and pruning deletes nodes based on model scores. With a provider that does
  /// not run a real model (e.g. the default ``SandboxedMLXModelProvider``),
  /// that output would be meaningless and the user's memories would be
  /// irreversibly lost. Fail before any read or write happens.
  private func validateProviderForDestructiveOperation(operation: String) throws {
    guard modelProvider.isProductionInferenceBackend else {
      let error = AuraError.compressionFailed(
        reason: "\(operation) requires a real MLXModelProvider. "
          + "The configured provider is a placeholder and would replace or delete stored memories "
          + "based on meaningless output. Inject a production provider (isProductionInferenceBackend == true) via "
          + "IntelligenceActor(modelProvider:) / CaptureActor.intelligenceActor(modelProvider:)."
      )
      Self.logger.error("[AuraKit] IntelligenceActor: \(operation) refused — placeholder model provider.")
      emitCompressionEvent(.failed, detail: error.localizedDescription)
      throw error
    }
  }

  private func generateConsolidatedSummary(
    for snapshots: [RawMemoryNodeSnapshot],
    signpostID: OSSignpostID
  ) async throws -> String {
    let prompt = ConsolidationPromptBuilder.build(from: snapshots)
    do {
      let summaryText = try await modelProvider.infer(prompt: prompt)
      guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AuraError.compressionFailed(reason: "Model returned an empty summary.")
      }
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
    archiveID: UUID,
    store: EncryptedMemoryStore,
    signpostID: OSSignpostID
  ) async throws -> Data {
    do {
      return try await store.sealArchiveSummary(summaryText, archiveID: archiveID)
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
  ) async throws -> Int {
    do {
      let deleted = try await store.archiveAndPruneNodes(
        encryptedSummary: encryptedSummary,
        sourceNodeIDs: sourceNodeIDs,
        archiveNodeID: archiveNodeID
      )
      emitCompressionEvent(.sourceNodesDeleted, detail: "Deleted \(deleted) source nodes.")
      return deleted
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
