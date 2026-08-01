// IntelligenceActor.swift
// AuraKit — Intelligence & Semantic Memory Layer
//
// Dedicated actor executing network-isolated LLM inference and Survival Index pruning.

import Foundation
import os.log

/// Dedicated actor executing network-isolated LLM inference and semantic pruning.
///
/// `IntelligenceActor` orchestrates Phase 3 on-device intelligence:
///
/// ```
/// Batch Events → BatchPromptBuilder → MLXModelProvider (Sandbox)
///                  ↓
///             SurvivalIndexParser → SurvivalIndex.calculate(S₀, n, t, λ, R)
///                  ↓
///             Prune nodes where SI < threshold from SpatialEventStore
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

  // MARK: - Init

  /// Initializes an `IntelligenceActor`.
  ///
  /// - Parameters:
  ///   - config: Configuration specifying thresholds and formula coefficients.
  ///   - store: Target persistence store for semantic pruning.
  ///   - modelProvider: Network-isolated LLM model provider.
  public init(
    config: AuraConfiguration = .default,
    store: any SpatialEventStore,
    modelProvider: (any MLXModelProvider)? = nil
  ) {
    self.config = config
    self.store = store
    self.modelProvider = modelProvider ?? SandboxedMLXModelProvider()
  }

  // MARK: - Public API

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
}
