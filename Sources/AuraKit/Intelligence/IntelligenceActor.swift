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

  static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "IntelligenceActor"
  )

  // MARK: - Properties

  let modelProvider: any MLXModelProvider
  let store: any SpatialEventStore
  let config: AuraConfiguration

  // MARK: - Compression Telemetry

  /// Continuation for the compression event notification stream.
  let _compressionContinuation: AsyncStream<MemoryCompressionEvent>.Continuation

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

    let (stream, continuation) = AsyncStream<MemoryCompressionEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )
    self.compressionEventStream = stream
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

    // 4. Resolve recall counts (n) for persisted events. Stores without recall
    //    tracking, and events not (yet) persisted — e.g. fresh L1 buffer
    //    drains — use n = 0.
    let recallCounts: [UUID: Int]
    if let recallStore = store as? any RecallTrackingSpatialEventStore {
      recallCounts = await recallStore.recalledCounts(for: Set(events.map(\.id)))
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
      Self.logger.info(
        "[AuraKit] IntelligenceActor: Pruned \(deletedCount) events below SI threshold \(self.config.intelligence.survivalIndexThreshold)."
      )
    } else {
      deletedCount = 0
    }

    return (evaluated, deletedCount)
  }

  // MARK: - Public API — Phase 4 Cognitive Compression

  /// Default upper bound on source nodes consolidated into one archive.
  ///
  /// Bounds the prompt size (on-device models have small context windows)
  /// and the blast radius of a single destructive transaction. Remaining
  /// candidates are picked up by the next call.
  public static let defaultMaxNodesPerCompression = 256

  /// Compresses idle memories below the Survival Index threshold into a single
  /// semantic archive node.
  ///
  /// This is the core Phase 4 cognitive compression API. The full pipeline:
  ///
  /// 1. The store selects nodes whose Survival Index `SI(t) = S₀·Rⁿ·e^(-λt)`
  ///    at `referenceDate` is below the threshold (oldest first, at most
  ///    `maxNodes`).
  /// 2. The candidates are **decrypted and verified**: a node whose plaintext
  ///    metadata does not match its authenticated payload is excluded and
  ///    never deleted.
  /// 3. The model summarises the verified events — including their decrypted
  ///    positions — in a single prompt.
  /// 4. The summary is encrypted with AES-GCM, bound to the archive ID via AAD.
  /// 5. A ``MemoryArchiveNode`` is written and the verified sources that
  ///    **still exist** are deleted in the same transaction.
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
  /// The backing store must conform to ``ArchivingSpatialEventStore`` (e.g.
  /// ``EncryptedMemoryStore``) and the provider must report
  /// ``MLXModelProvider/isProductionInferenceBackend``. Concurrent calls are
  /// rejected while a compression is in progress.
  ///
  /// - Parameters:
  ///   - referenceDate: Evaluation time for the decay term. Inject a fixed date
  ///     for deterministic tests.
  ///   - maxNodes: Maximum source nodes consolidated by this call.
  /// - Returns: A ``CompressionReport`` describing the outcome.
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if compression fails.
  public func compressIdleMemories(
    referenceDate: Date = Date(),
    maxNodes: Int = IntelligenceActor.defaultMaxNodesPerCompression
  ) async throws -> CompressionReport {
    guard !isCompressing else {
      throw AuraError.compressionFailed(reason: "A compression operation is already in progress.")
    }
    isCompressing = true
    defer { isCompressing = false }

    let startTime = ContinuousClock.now
    emitCompressionEvent(.started, detail: "Compression operation started.")

    do {
      let report = try await performCompression(
        referenceDate: referenceDate, maxNodes: max(maxNodes, 1))
      let detail =
        report.didCompress
        ? "Compression completed — \(report.nodesPruned) nodes → 1 archive, \(report.bytesRecovered) bytes recovered."
        : "No nodes below SI threshold \(config.intelligence.survivalIndexThreshold). Nothing to compress."
      emitCompressionEvent(.completed, detail: detail)
      return report.didCompress
        ? report.withDuration(startTime.duration(to: ContinuousClock.now)) : report
    } catch {
      // Single failure exit: every error path emits exactly one `.failed`.
      emitCompressionEvent(.failed, detail: error.localizedDescription)
      throw error
    }
  }
}

// MARK: - IntelligenceActor + Private Compression Pipeline

extension IntelligenceActor {

  func performCompression(
    referenceDate: Date,
    maxNodes: Int
  ) async throws -> CompressionReport {
    let archivingStore = try requireArchivingStore()
    try validateProviderForDestructiveOperation(operation: "Cognitive compression")

    let candidates = await selectCompressionCandidates(
      from: archivingStore,
      referenceDate: referenceDate,
      maxNodes: maxNodes
    )
    guard !candidates.isEmpty else { return .empty }

    let signpostID = SignpostLogger.beginCompression(nodeCount: candidates.count)
    defer { SignpostLogger.endCompression(signpostID) }

    let threshold = config.intelligence.survivalIndexThreshold
    emitCompressionEvent(
      .nodesSelected, detail: "Selected \(candidates.count) nodes below SI threshold \(threshold).")
    Self.logger.info(
      "[AuraKit] IntelligenceActor: Compression — \(candidates.count) nodes selected below SI \(threshold)."
    )

    let events = try await loadVerifiedEvents(for: candidates, from: archivingStore)
    let summaryText = try await generateConsolidatedSummary(for: events)
    return try await archiveAndPrune(
      events: events,
      summaryText: summaryText,
      in: archivingStore
    )
  }

  private func selectCompressionCandidates(
    from store: any ArchivingSpatialEventStore,
    referenceDate: Date,
    maxNodes: Int
  ) async -> [RawMemoryNodeSnapshot] {
    let allCandidates = await store.fetchNodesBelowSurvivalIndex(
      threshold: config.intelligence.survivalIndexThreshold,
      decayConstant: config.intelligence.decayConstant,
      recallMultiplier: config.intelligence.recallMultiplier,
      referenceDate: referenceDate
    )
    let candidates = Array(allCandidates.prefix(maxNodes))
    if allCandidates.count > candidates.count {
      Self.logger.info(
        "[AuraKit] IntelligenceActor: \(allCandidates.count) nodes qualify; compressing the oldest \(candidates.count)."
      )
    }
    return candidates
  }

  private func loadVerifiedEvents(
    for candidates: [RawMemoryNodeSnapshot],
    from store: any ArchivingSpatialEventStore
  ) async throws -> [SpatialEvent] {
    let events = await store.eventsForConsolidation(ids: Set(candidates.map(\.id)))
    guard !events.isEmpty else {
      throw AuraError.compressionFailed(
        reason: "None of the \(candidates.count) selected nodes could be decrypted and verified "
          + "(key unavailable or metadata tampered); nothing was deleted."
      )
    }
    if events.count < candidates.count {
      Self.logger.warning(
        "[AuraKit] IntelligenceActor: \(candidates.count - events.count) node(s) failed verification and were excluded."
      )
    }
    return events
  }

  private func archiveAndPrune(
    events: [SpatialEvent],
    summaryText: String,
    in store: any ArchivingSpatialEventStore
  ) async throws -> CompressionReport {
    let archiveNodeID = UUID()
    let encryptedSummaryData: Data
    do {
      encryptedSummaryData = try await store.sealArchiveSummary(
        summaryText, archiveID: archiveNodeID)
    } catch {
      throw AuraError.compressionFailed(
        reason: "Summary encryption failed: \(error.localizedDescription)")
    }

    let sourceNodeIDs = Set(events.map(\.id))
    let bytesRecovered = await store.totalPayloadSize(for: sourceNodeIDs)

    emitCompressionEvent(
      .archiveCreated,
      detail: "Archive node \(archiveNodeID) created with \(sourceNodeIDs.count) source references."
    )
    let prunedCount = try await store.archiveAndPruneNodes(
      encryptedSummary: encryptedSummaryData,
      sourceNodeIDs: sourceNodeIDs,
      archiveNodeID: archiveNodeID
    )
    emitCompressionEvent(.sourceNodesDeleted, detail: "Deleted \(prunedCount) source nodes.")

    Self.logger.info(
      "[AuraKit] IntelligenceActor: Compression completed — \(prunedCount) nodes consolidated into \(archiveNodeID)."
    )
    return CompressionReport(
      nodesPruned: prunedCount,
      archiveNodesCreated: 1,
      bytesRecovered: bytesRecovered,
      summary: summaryText,
      archiveNodeID: archiveNodeID,
      duration: .zero
    )
  }

  private func requireArchivingStore() throws -> any ArchivingSpatialEventStore {
    guard let archivingStore = store as? any ArchivingSpatialEventStore else {
      throw AuraError.compressionFailed(
        reason: "Cognitive compression requires a store conforming to ArchivingSpatialEventStore "
          + "(e.g. EncryptedMemoryStore). The current store does not support archive operations."
      )
    }
    return archivingStore
  }

  /// Refuses to run destructive operations with an untrusted provider.
  func validateProviderForDestructiveOperation(operation: String) throws {
    guard modelProvider.isProductionInferenceBackend else {
      Self.logger.error(
        "[AuraKit] IntelligenceActor: \(operation) refused — placeholder model provider.")
      throw AuraError.compressionFailed(
        reason: "\(operation) requires a real MLXModelProvider. "
          + "The configured provider is a placeholder and would replace or delete stored memories "
          + "based on meaningless output. Inject a production provider (isProductionInferenceBackend == true) via "
          + "IntelligenceActor(modelProvider:) / CaptureActor.intelligenceActor(modelProvider:)."
      )
    }
  }

  private func generateConsolidatedSummary(for events: [SpatialEvent]) async throws -> String {
    let prompt = ConsolidationPromptBuilder.build(from: events)
    let summaryText: String
    do {
      summaryText = try await modelProvider.infer(prompt: prompt)
    } catch {
      throw AuraError.compressionFailed(
        reason: "LLM inference failed: \(error.localizedDescription)")
    }
    guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AuraError.compressionFailed(
        reason: "LLM inference failed: Model returned an empty summary.")
    }
    emitCompressionEvent(
      .summaryGenerated, detail: "Summary generated (\(summaryText.count) characters).")
    return summaryText
  }

  // MARK: - Telemetry Helpers

  func emitCompressionEvent(_ phase: MemoryCompressionEvent.Phase, detail: String) {
    _compressionContinuation.yield(
      MemoryCompressionEvent(phase: phase, detail: detail)
    )
  }
}
