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

  /// Fetches memory nodes filtered by event type and sorted by score.
  ///
  /// This query operates on unencrypted metadata only — no decryption occurs.
  ///
  /// - Note: `RawMemoryNode` is a `@Model` class and is **not** `Sendable`.
  ///   This method should be called from within the actor's isolation domain
  ///   or from methods that project results to `Sendable` types (e.g., counts).
  ///
  /// - Parameters:
  ///   - eventType: The ``SpatialEventType`` to filter by.
  ///   - limit: Maximum number of results. Pass `nil` for all matching nodes.
  /// - Returns: Matching ``RawMemoryNode`` records, highest score first.
  public func fetchNodes(
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
        "[AuraKit] EncryptedMemoryStore: fetchNodes failed — \(error.localizedDescription)"
      )
      return []
    }
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
      decryptionFailureCount: _decryptionFailureCount
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

  /// Removes all memory nodes from the store.
  ///
  /// - Warning: This is a destructive, irreversible operation.
  ///   Primarily intended for test teardown and development resets.
  public func clear() async {
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
}
