// EncryptedMemoryStore+Compression.swift
// AuraKit — Core Infrastructure
//
// Atomic archive-and-prune operations for Phase 4 cognitive compression.
// Extracted into its own file following the extension split pattern used
// by +Queries, +Decryption, +Streaming, and +RetryQueue.

import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Compression Queries

extension EncryptedMemoryStore {

  /// Fetches all ``RawMemoryNodeSnapshot`` records with a score below the given threshold.
  ///
  /// Used by Phase 4's cognitive compression engine to identify nodes
  /// that qualify for consolidation into a ``MemoryArchiveNode``.
  ///
  /// This query operates on unencrypted metadata only — no decryption occurs.
  ///
  /// - Parameter threshold: The Survival Index threshold. Nodes with
  ///   `score < threshold` are returned.
  /// - Returns: Matching snapshots sorted by timestamp (oldest first).
  public func fetchNodesBelowThreshold(
    _ threshold: Double
  ) -> [RawMemoryNodeSnapshot] {
    do {
      let descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.score < threshold },
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      let nodes = try modelContext.fetch(descriptor)
      return nodes.compactMap { RawMemoryNodeSnapshot(node: $0) }
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: fetchNodesBelowThreshold failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// Calculates the total `encryptedPayload` byte size for nodes matching
  /// the given UUIDs.
  ///
  /// Used by cognitive compression to estimate bytes recovered after pruning.
  /// Operates on unencrypted metadata — no decryption occurs.
  ///
  /// - Parameter ids: The set of node UUIDs to measure.
  /// - Returns: Total payload bytes across all matching nodes.
  public func totalPayloadSize(for ids: Set<UUID>) -> Int64 {
    do {
      let targetIDs = ids
      let descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { targetIDs.contains($0.id) }
      )
      let nodes = try modelContext.fetch(descriptor)
      return nodes.reduce(Int64(0)) { $0 + Int64($1.encryptedPayload.count) }
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: totalPayloadSize failed — \(error.localizedDescription)"
      )
      return 0
    }
  }
}

// MARK: - EncryptedMemoryStore + Compression Operations

extension EncryptedMemoryStore {

  /// Atomically creates a ``MemoryArchiveNode`` and deletes the corresponding
  /// source ``RawMemoryNode`` records in a single `ModelContext` transaction.
  ///
  /// - Parameters:
  ///   - encryptedSummary: AES-GCM encrypted summary data.
  ///   - sourceNodeIDs: The set of ``RawMemoryNode`` UUIDs to delete.
  ///   - archiveNodeID: The unique ID for the new archive node. Defaults to a new UUID.
  /// - Returns: The number of source nodes deleted.
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if the transaction cannot be committed.
  @discardableResult
  public func archiveAndPruneNodes(
    encryptedSummary: Data,
    sourceNodeIDs: Set<UUID>,
    archiveNodeID: UUID = UUID()
  ) async throws -> Int {
    let archiveNode = MemoryArchiveNode(
      id: archiveNodeID,
      encryptedSummary: encryptedSummary,
      sourceNodeIDs: Array(sourceNodeIDs)
    )
    return try await archiveAndPruneNodes(archiveNode: archiveNode, sourceNodeIDs: sourceNodeIDs)
  }

  /// Atomically inserts a ``MemoryArchiveNode`` and deletes source records.
  ///
  /// - Parameters:
  ///   - archiveNode: The ``MemoryArchiveNode`` to persist.
  ///   - sourceNodeIDs: The set of ``RawMemoryNode`` UUIDs to delete.
  /// - Returns: The number of source nodes deleted.
  /// - Throws: ``AuraError/compressionFailed(reason:)`` if the transaction cannot be committed.
  @discardableResult
  public func archiveAndPruneNodes(
    archiveNode: MemoryArchiveNode,
    sourceNodeIDs: Set<UUID>
  ) async throws -> Int {
    // Flush any pending coalesced inserts before the compression transaction
    // to ensure a clean ModelContext state.
    await flushPendingWrites()

    // Phase 1: Insert the archive node.
    modelContext.insert(archiveNode)

    // Phase 2: Delete source nodes.
    let targetIDs = sourceNodeIDs
    do {
      try modelContext.delete(
        model: RawMemoryNode.self,
        where: #Predicate<RawMemoryNode> { targetIDs.contains($0.id) }
      )
    } catch {
      modelContext.rollback()
      throw AuraError.compressionFailed(
        reason: "Failed to delete source nodes: \(error.localizedDescription)"
      )
    }

    // Phase 3: Atomic commit — archive insert + source deletion in one save.
    do {
      try modelContext.save()

      let deletedCount = sourceNodeIDs.count
      Self.logger.info(
        "[AuraKit] EncryptedMemoryStore: Compression committed — 1 archive created, \(deletedCount) source nodes deleted."
      )

      return sourceNodeIDs.count
    } catch {
      // Rollback ensures no partial state: the archive is removed and
      // source nodes are restored to their pre-transaction state.
      modelContext.rollback()

      let errorDesc = error.localizedDescription
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Compression transaction failed — \(errorDesc). Context rolled back."
      )

      throw AuraError.compressionFailed(
        reason: "Transaction save failed: \(error.localizedDescription)"
      )
    }
  }

  /// Returns the count of ``MemoryArchiveNode`` records in the store.
  ///
  /// Used by compression tests and telemetry to verify archive creation.
  public var archiveNodeCount: Int {
    do {
      let descriptor = FetchDescriptor<MemoryArchiveNode>()
      return try modelContext.fetchCount(descriptor)
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: archiveNodeCount failed — \(error.localizedDescription)"
      )
      return 0
    }
  }

  /// Fetches all archive node snapshots in chronological order.
  ///
  /// - Returns: All archive snapshots sorted by `createdAt` (oldest first).
  public func fetchArchiveSnapshots() -> [MemoryArchiveNodeSnapshot] {
    do {
      let descriptor = FetchDescriptor<MemoryArchiveNode>(
        sortBy: [SortDescriptor(\.createdAt, order: .forward)]
      )
      let nodes = try modelContext.fetch(descriptor)
      return nodes.map { MemoryArchiveNodeSnapshot(archive: $0) }
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: fetchArchiveSnapshots failed — \(error.localizedDescription)"
      )
      return []
    }
  }
}
