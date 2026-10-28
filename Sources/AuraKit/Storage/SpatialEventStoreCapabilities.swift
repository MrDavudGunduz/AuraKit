// SpatialEventStoreCapabilities.swift
// AuraKit — Core Infrastructure
//
// Optional capability protocols layered on top of `SpatialEventStore`.
//
// `IntelligenceActor` previously down-cast its store to the concrete
// `EncryptedMemoryStore` to reach recall counts and archive operations, which
// made those features impossible for any third-party store and contradicted
// the protocol's role as the storage abstraction boundary. Features now
// depend on *capabilities*, not on a concrete type.

import Foundation

// MARK: - RecallTrackingSpatialEventStore

/// A store that tracks how often each event has been recalled — the `n` in
/// the Survival Index `SI(t) = S₀·Rⁿ·e^(-λt)`.
public protocol RecallTrackingSpatialEventStore: SpatialEventStore {

  /// Recall counts for the given event IDs. IDs not present in the store are
  /// omitted from the result.
  func recalledCounts(for ids: Set<UUID>) async -> [UUID: Int]
}

// MARK: - ArchivingSpatialEventStore

/// A store that supports cognitive compression: selecting decayed memories,
/// sealing a consolidated summary, and atomically replacing the sources with
/// an archive.
public protocol ArchivingSpatialEventStore: RecallTrackingSpatialEventStore {

  /// Metadata snapshots of every event whose Survival Index is below
  /// `threshold` at `referenceDate`, oldest first.
  func fetchNodesBelowSurvivalIndex(
    threshold: Double,
    decayConstant: Double,
    recallMultiplier: Double,
    referenceDate: Date
  ) async -> [RawMemoryNodeSnapshot]

  /// Decrypts the given events for consolidation, verifying that every
  /// payload still matches its stored metadata. Events that cannot be opened
  /// or fail verification are omitted.
  func eventsForConsolidation(ids: Set<UUID>) async -> [SpatialEvent]

  /// Encrypts a consolidated summary bound to `archiveID`.
  func sealArchiveSummary(_ summary: String, archiveID: UUID) async throws -> Data

  /// Total stored payload bytes for the given event IDs.
  func totalPayloadSize(for ids: Set<UUID>) async -> Int64

  /// Atomically inserts an archive and deletes its source events.
  ///
  /// - Returns: The number of source events deleted.
  @discardableResult
  func archiveAndPruneNodes(
    encryptedSummary: Data,
    sourceNodeIDs: Set<UUID>,
    archiveNodeID: UUID
  ) async throws -> Int
}

// MARK: - EncryptedMemoryStore Conformance

extension EncryptedMemoryStore: ArchivingSpatialEventStore {}

