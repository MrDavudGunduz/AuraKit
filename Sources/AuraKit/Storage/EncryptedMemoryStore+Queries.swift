// EncryptedMemoryStore+Queries.swift
// AuraKit — Core Infrastructure
//
// Metadata query and inspection methods for EncryptedMemoryStore.
// Extracted from EncryptedMemoryStore.swift for SwiftLint file_length compliance.
// These methods operate on unencrypted metadata — no decryption occurs.

import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Metadata Queries

extension EncryptedMemoryStore {

  // MARK: - Filtered Counts

  /// Counts memory nodes matching the given event type.
  ///
  /// This query operates on unencrypted metadata only — no decryption occurs.
  /// Returns a `Sendable` `Int` suitable for cross-actor access.
  ///
  /// - Parameter eventType: The ``SpatialEventType`` to filter by.
  /// - Returns: The number of matching nodes.
  public func fetchNodeCount(eventType: SpatialEventType) async -> Int {
    do {
      let typeValue = eventType.rawValue
      let descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.eventType == typeValue }
      )
      return try modelContext.fetchCount(descriptor)
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: fetchNodeCount failed — \(error.localizedDescription)"
      )
      return 0
    }
  }

  // MARK: - Filtered Fetch

  /// Internal actor-isolated method for fetching raw `@Model` nodes.
  /// Must NOT be exposed publicly across actor boundaries.
  func fetchRawNodes(
    eventType: SpatialEventType,
    limit: Int? = nil
  ) -> [RawMemoryNode] {
    do {
      let typeValue = eventType.rawValue
      var descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.eventType == typeValue },
        sortBy: [SortDescriptor(\.score, order: .reverse)]
      )
      descriptor.fetchLimit = limit

      return try modelContext.fetch(descriptor)
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: fetchRawNodes failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// Fetches memory node metadata snapshots filtered by event type and sorted by score.
  ///
  /// This query operates on unencrypted metadata only — no decryption occurs.
  /// Returns `Sendable` ``RawMemoryNodeSnapshot`` objects safe to transfer across actor boundaries.
  ///
  /// - Parameters:
  ///   - eventType: The ``SpatialEventType`` to filter by.
  ///   - limit: Maximum number of results. Pass `nil` for all matching nodes.
  /// - Returns: Matching ``RawMemoryNodeSnapshot`` records, highest score first.
  public func fetchNodeSnapshots(
    eventType: SpatialEventType,
    limit: Int? = nil
  ) async -> [RawMemoryNodeSnapshot] {
    let nodes = fetchRawNodes(eventType: eventType, limit: limit)
    return nodes.compactMap { RawMemoryNodeSnapshot(node: $0) }
  }

  // MARK: - Single-Node Projections

  /// Returns the `recalled` counter for a specific node, identified by UUID.
  ///
  /// This is a Sendable-safe projection of ``RawMemoryNode/recalled`` metadata,
  /// suitable for cross-actor access in test assertions and Survival Index queries.
  ///
  /// - Parameter id: The UUID of the target node.
  /// - Returns: The recalled count, or `nil` if no matching node exists.
  public func recalledCount(for id: UUID) async -> Int? {
    do {
      var descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.id == id }
      )
      descriptor.fetchLimit = 1

      let results = try modelContext.fetch(descriptor)
      return results.first?.recalled
    } catch {
      return nil
    }
  }

  /// Fetches the raw ciphertext for a specific node, for SQLite inspection
  /// and ciphertext verification during testing.
  ///
  /// - Parameter id: The UUID of the target node.
  /// - Returns: The encrypted payload `Data`, or `nil` if not found.
  public func rawCiphertext(for id: UUID) async -> Data? {
    do {
      var descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.id == id }
      )
      descriptor.fetchLimit = 1

      let results = try modelContext.fetch(descriptor)
      return results.first?.encryptedPayload
    } catch {
      return nil
    }
  }
}

// MARK: - EncryptedMemoryStore + Metrics

extension EncryptedMemoryStore {

  /// Atomically captures a snapshot of all observability counters.
  ///
  /// Use this to feed production telemetry dashboards (e.g., Firebase,
  /// Datadog, or custom `os_log` reporters) without querying each counter
  /// individually:
  ///
  /// ```swift
  /// let snapshot = await store.metrics
  /// analytics.track("aurakit.store", properties: [
  ///     "written": snapshot.totalEventsWritten,
  ///     "dropped": snapshot.droppedEventCount,
  ///     "decryptFailures": snapshot.decryptionFailureCount
  /// ])
  /// ```
  public var metrics: StoreMetrics {
    StoreMetrics(
      totalEventsWritten: _totalEventsWritten,
      droppedEventCount: _droppedEventCount,
      decryptionFailureCount: _decryptionFailureCount,
      retryQueueCount: _retryQueue.count
    )
  }

  /// Increments the decryption failure counter.
  ///
  /// Called by the ``EncryptedMemoryStore+Decryption`` extension when a
  /// node fails to decrypt. Keeping the mutation here ensures the counter
  /// is always modified within the actor's isolation domain.
  func incrementDecryptionFailure() {
    _decryptionFailureCount += 1
  }
}

// MARK: - EncryptedMemoryStore + Safe Full-Table Access

extension EncryptedMemoryStore {

  /// Fetches all stored events **only if** the total node count is at or below
  /// the specified threshold.
  ///
  /// This is a **safe-guard wrapper** around ``allEvents()`` designed for
  /// production code paths where accidentally triggering a full-table decrypt
  /// on a large dataset could cause memory pressure spikes or UI jank.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// // Safe: throws if the store has grown beyond 500 nodes
  /// let events = try await store.allEventsIfSmallDataset(threshold: 500)
  ///
  /// // Or use the default threshold from AuraConfiguration
  /// let events = try await store.allEventsIfSmallDataset()
  /// ```
  ///
  /// ## When to Use
  ///
  /// Use ``allEventsIfSmallDataset(threshold:)`` instead of ``allEvents()`` when:
  /// - The caller cannot guarantee the dataset size (e.g., user-facing features)
  /// - Memory budget is constrained (e.g., widgets, App Intents, extensions)
  /// - You want a compile-time-enforced reminder to handle large datasets
  ///
  /// For known-small datasets or test code, ``allEvents()`` remains appropriate.
  ///
  /// - Parameter threshold: Maximum node count before this method refuses to
  ///   proceed. Defaults to ``AuraConfiguration/defaultLargeDatasetWarningThreshold``.
  /// - Returns: All stored events in chronological order.
  /// - Throws: ``AuraError/persistenceFailed(reason:)`` if the store contains
  ///   more nodes than `threshold`.
  public func allEventsIfSmallDataset(
    threshold: Int = AuraConfiguration.defaultLargeDatasetWarningThreshold
  ) async throws -> [SpatialEvent] {
    let nodeCount = await count
    guard nodeCount <= threshold else {
      throw AuraError.persistenceFailed(
        reason: "allEventsIfSmallDataset() refused: store contains \(nodeCount) nodes "
          + "(threshold: \(threshold)). Use events(limit:offset:) or eventStream() instead."
      )
    }
    return await allEvents()
  }
}

// MARK: - StoreHealth

/// An immutable, `Sendable` diagnostic snapshot of ``EncryptedMemoryStore`` state
/// captured at a single point in time.
///
/// Combines node counts, write/read metrics, and dataset size classification
/// into a single value suitable for production telemetry dashboards.
///
/// ```swift
/// let health = await store.storeHealth
/// if health.isLargeDataset {
///     logger.warning("Store has \(health.totalNodeCount) nodes — consider pruning.")
/// }
/// ```
public struct StoreHealth: Sendable, Equatable {

  /// Total number of encrypted nodes in the store.
  public let totalNodeCount: Int

  /// Number of gaze-type nodes.
  public let gazeNodeCount: Int

  /// Number of interaction-type nodes (touch + move + pinch + drag).
  public let interactionNodeCount: Int

  /// A snapshot of write/read observability counters.
  public let metrics: StoreMetrics

  /// Whether the dataset exceeds the configured warning threshold.
  public let isLargeDataset: Bool

  /// The configured warning threshold for reference.
  public let largeDatasetThreshold: Int
}

// MARK: - EncryptedMemoryStore + Health Diagnostics

extension EncryptedMemoryStore {

  /// Captures a comprehensive diagnostic snapshot of the store's current state.
  ///
  /// This property aggregates node counts, event-type breakdowns, and
  /// write/read metrics into a single ``StoreHealth`` value. All queries
  /// operate on unencrypted metadata — **no decryption occurs**.
  ///
  /// Designed for production telemetry:
  ///
  /// ```swift
  /// let health = await store.storeHealth
  /// analytics.track("aurakit.health", properties: [
  ///     "total_nodes": health.totalNodeCount,
  ///     "gaze_nodes": health.gazeNodeCount,
  ///     "interaction_nodes": health.interactionNodeCount,
  ///     "write_success_rate": health.metrics.writeSuccessRate,
  ///     "is_large": health.isLargeDataset,
  /// ])
  /// ```
  public var storeHealth: StoreHealth {
    get async {
      let total = await count
      let gazeCount = await fetchNodeCount(eventType: .gaze)

      // Interaction count = total - gaze (avoids 4 separate queries)
      let interactionCount = total - gazeCount

      return StoreHealth(
        totalNodeCount: total,
        gazeNodeCount: gazeCount,
        interactionNodeCount: interactionCount,
        metrics: metrics,
        isLargeDataset: largeDatasetWarningThreshold > 0
          && total > largeDatasetWarningThreshold,
        largeDatasetThreshold: largeDatasetWarningThreshold
      )
    }
  }
}

// MARK: - EncryptedMemoryStore + Pruning & Lifecycle

extension EncryptedMemoryStore {

  /// Deletes all nodes with a score below the given threshold.
  ///
  /// Used by Phase 3's Survival Index pruning. Only the metadata score
  /// is evaluated — no decryption occurs.
  ///
  /// ## Performance
  ///
  /// Uses a two-phase approach optimised for large stores:
  /// 1. `fetchCount` — lightweight metadata query (no objects materialised)
  /// 2. `modelContext.delete(model:where:)` — batch delete without
  ///    loading individual objects into memory (O(1) memory usage)
  ///
  /// - Parameter threshold: Nodes with `score < threshold` are deleted.
  /// - Returns: The number of nodes deleted.
  @discardableResult
  public func deleteNodes(belowScore threshold: Double) async -> Int {
    do {
      // Phase 1: Count matching nodes without materialising them.
      let countDescriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.score < threshold }
      )
      let deletedCount = try modelContext.fetchCount(countDescriptor)

      guard deletedCount > 0 else { return 0 }

      // Phase 2: Batch delete — SwiftData handles the deletion at the
      // store level without loading each object into memory.
      try modelContext.delete(
        model: RawMemoryNode.self,
        where: #Predicate<RawMemoryNode> { $0.score < threshold }
      )

      try modelContext.save()

      Self.logger.info(
        "[AuraKit] EncryptedMemoryStore: Pruned \(deletedCount) nodes below threshold \(threshold)."
      )

      return deletedCount
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: deleteNodes failed — \(error.localizedDescription). Context rolled back."
      )
      modelContext.rollback()
      return 0
    }
  }

  /// Persists all pending coalesced inserts immediately.
  ///
  /// When write coalescing is enabled (``saveThreshold`` > 1), `append()` calls
  /// insert nodes into the `ModelContext` but defer the `save()` until the
  /// threshold is reached. Call this method to force an immediate commit of
  /// all pending inserts — for example, before pipeline shutdown, before reads
  /// that must see the latest writes, or at app lifecycle boundaries.
  ///
  /// This method is a no-op if there are no pending inserts.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// // Before reading recently appended events:
  /// await store.flushPendingWrites()
  /// let events = await store.allEvents()
  ///
  /// // In shutdown flow:
  /// await store.flushPendingWrites()
  /// ```
  ///
  /// - Note: ``batchAppend(_:)`` always issues its own `save()` regardless
  ///   of the coalescing threshold — calling `flushPendingWrites()` after
  ///   a batch append is unnecessary.
  public func flushPendingWrites() async {
    guard pendingInsertCount > 0 else { return }

    do {
      try modelContext.save()
      _totalEventsWritten += pendingInsertCount
      Self.logger.debug(
        "[AuraKit] EncryptedMemoryStore: Flushed \(self.pendingInsertCount) pending inserts."
      )
      pendingInsertCount = 0
    } catch {
      modelContext.rollback()
      _droppedEventCount += pendingInsertCount
      _dropContinuation.yield(DroppedEvent(
        reason: "Flush save failed (\(pendingInsertCount) events): \(error.localizedDescription)"
      ))
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: flushPendingWrites() failed — \(error.localizedDescription). Context rolled back."
      )
      pendingInsertCount = 0
    }
  }

  /// Removes all memory nodes from the store.
  ///
  /// Any pending coalesced inserts are discarded (not flushed) before deletion.
  ///
  /// - Warning: This is a destructive, irreversible operation.
  ///   Primarily intended for test teardown and development resets.
  public func clear() async {
    // Discard any pending coalesced inserts — they would be deleted anyway.
    pendingInsertCount = 0

    do {
      try modelContext.delete(model: RawMemoryNode.self)
      try modelContext.delete(model: MemoryArchiveNode.self)
      try modelContext.save()

      Self.logger.info(
        "[AuraKit] EncryptedMemoryStore: All nodes cleared."
      )
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: clear() failed — \(error.localizedDescription). Context rolled back."
      )
      modelContext.rollback()
    }
  }

  /// Removes events with the specified IDs from the SwiftData store.
  ///
  /// - Parameter ids: Set of event UUIDs to remove.
  /// - Returns: Number of nodes removed.
  @discardableResult
  public func removeEvents(withIDs ids: Set<UUID>) async -> Int {
    guard !ids.isEmpty else { return 0 }
    await flushPendingWrites()

    do {
      let targetIDs = ids
      try modelContext.delete(
        model: RawMemoryNode.self,
        where: #Predicate<RawMemoryNode> { targetIDs.contains($0.id) }
      )
      try modelContext.save()
      return ids.count
    } catch {
      modelContext.rollback()
      return 0
    }
  }
}

// MARK: - RawMemoryNodeSnapshot

/// An immutable, `Sendable` snapshot of unencrypted metadata for a single ``RawMemoryNode``.
///
/// Designed for cross-actor metadata inspection without exposing non-`Sendable` `@Model` objects.
public struct RawMemoryNodeSnapshot: Sendable, Equatable, Identifiable {

  /// Unique identifier of the node.
  public let id: UUID

  /// Heuristic importance score.
  public let score: Double

  /// Wall-clock timestamp of creation.
  public let timestamp: Date

  /// Spatial event classification.
  public let eventType: SpatialEventType

  /// Number of times recalled.
  public let recalled: Int

  /// Key version used for encryption.
  public let keyVersion: Int

  /// Creates a node snapshot with explicit property values.
  public init(
    id: UUID,
    score: Double,
    timestamp: Date,
    eventType: SpatialEventType,
    recalled: Int,
    keyVersion: Int
  ) {
    self.id = id
    self.score = score
    self.timestamp = timestamp
    self.eventType = eventType
    self.recalled = recalled
    self.keyVersion = keyVersion
  }

  /// Creates a snapshot from a live ``RawMemoryNode``, or `nil` if `eventType` is invalid.
  public init?(node: RawMemoryNode) {
    guard let type = node.spatialEventType else { return nil }
    self.id = node.id
    self.score = node.score
    self.timestamp = node.timestamp
    self.eventType = type
    self.recalled = node.recalled
    self.keyVersion = node.keyVersion
  }
}

