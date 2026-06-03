// MemoryArchiveNode.swift
// AuraKit — Persistence Layer
//
// SwiftData model for compressed semantic memory archives.
// Each archive node represents a consolidated summary of multiple pruned
// RawMemoryNode records — the result of Phase 4's cognitive compression.

import Foundation
import os.log
import SwiftData

// MARK: - MemoryArchiveNode Logger

/// Dedicated logger for `MemoryArchiveNode` operations.
///
/// Extracted outside the `@Model` class to prevent the SwiftData macro from
/// inspecting static stored properties. `@Model` synthesises persistence
/// metadata for all stored properties — while `static let` properties are
/// safe today, keeping the logger external is a defensive best practice
/// that also aligns with `RawMemoryNode`'s pattern (no embedded logger).
private enum MemoryArchiveNodeLog {
  static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "MemoryArchiveNode"
  )
}

// MARK: - MemoryArchiveNode

/// A compressed semantic archive of multiple pruned ``RawMemoryNode`` records.
///
/// `MemoryArchiveNode` is created by Phase 4's cognitive compression engine
/// (`IntelligenceActor.compressIdleMemories()`). When the Survival Index drops
/// below the configured threshold for a cluster of `RawMemoryNode` records,
/// the LLM generates a natural-language summary, which is then:
///
/// 1. Embedded as a vector (for Metal cosine similarity search)
/// 2. Encrypted with AES-GCM
/// 3. Persisted as a `MemoryArchiveNode`
/// 4. Source `RawMemoryNode` records are deleted
///
/// ## Example Summary
///
/// > "User inspected the southeast exhibit case twice then moved toward the exit."
///
/// ## Security
///
/// The ``encryptedSummary`` field uses the same AES-GCM encryption and
/// Secure Enclave–derived key as ``RawMemoryNode/encryptedPayload``.
///
/// ## Audit Trail
///
/// ``sourceNodeIDs`` preserves the UUIDs of the pruned `RawMemoryNode` records.
/// These IDs can be used for forensic analysis and compression ratio tracking.
/// The actual nodes are deleted after archive creation.
@Model
public final class MemoryArchiveNode {

  // MARK: - Properties

  /// Unique identifier for this archive node.
  @Attribute(.unique)
  public var id: UUID

  /// AES-GCM encrypted summary containing the LLM-generated semantic text
  /// and optional embedding vector.
  ///
  /// Format: `nonce (12 bytes) || ciphertext || auth tag (16 bytes)`.
  public var encryptedSummary: Data

  /// Timestamp of archive creation (not the timestamp of the original events).
  public var createdAt: Date

  /// JSON-encoded array of UUIDs referencing the pruned ``RawMemoryNode`` records
  /// that were consolidated into this archive.
  ///
  /// Stored as `Data` because SwiftData does not natively support `[UUID]`
  /// in a way that is compatible with CloudKit sync. The convenience accessors
  /// ``decodedSourceNodeIDs`` and ``init(..., sourceNodeIDs:)`` handle the
  /// encoding/decoding transparently.
  public var sourceNodeIDsData: Data

  // MARK: - Init

  /// Creates a new `MemoryArchiveNode` from an encrypted summary and source references.
  ///
  /// - Parameters:
  ///   - id: Unique identifier. Defaults to a new `UUID()`.
  ///   - encryptedSummary: AES-GCM combined ciphertext of the semantic summary.
  ///   - createdAt: Archive creation timestamp. Defaults to `Date()`.
  ///   - sourceNodeIDs: UUIDs of the pruned `RawMemoryNode` records.
  public init(
    id: UUID = UUID(),
    encryptedSummary: Data,
    createdAt: Date = Date(),
    sourceNodeIDs: [UUID]
  ) {
    self.id = id
    self.encryptedSummary = encryptedSummary
    self.createdAt = createdAt

    // Encode [UUID] as JSON Data for SwiftData/CloudKit compatibility.
    // Defensive encoding: if this ever fails (extreme memory pressure),
    // the node is still created with empty source data rather than crashing.
    do {
      self.sourceNodeIDsData = try JSONEncoder().encode(sourceNodeIDs)
    } catch {
      MemoryArchiveNodeLog.logger.error(
        "[AuraKit] MemoryArchiveNode: Failed to encode sourceNodeIDs — \(error.localizedDescription). Defaulting to empty."
      )
      self.sourceNodeIDsData = Data()
    }
  }
}

// MARK: - Source Node ID Accessors

extension MemoryArchiveNode {

  /// Decodes and returns the array of source ``RawMemoryNode`` UUIDs.
  ///
  /// Returns an empty array if decoding fails (should not occur under normal
  /// operation — indicates data corruption).
  public var decodedSourceNodeIDs: [UUID] {
    (try? JSONDecoder().decode([UUID].self, from: sourceNodeIDsData)) ?? []
  }

  /// Updates the stored source node IDs.
  ///
  /// - Parameter ids: The new array of source `RawMemoryNode` UUIDs.
  public func updateSourceNodeIDs(_ ids: [UUID]) {
    do {
      self.sourceNodeIDsData = try JSONEncoder().encode(ids)
    } catch {
      MemoryArchiveNodeLog.logger.error(
        "[AuraKit] MemoryArchiveNode: Failed to encode updated sourceNodeIDs — \(error.localizedDescription)."
      )
    }
  }
}
