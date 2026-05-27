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
