// EncryptedMemoryStore+Decryption.swift
// AuraKit — Core Infrastructure
//
// Private decrypt helpers for EncryptedMemoryStore.
// Extracted from EncryptedMemoryStore.swift for SwiftLint file_length compliance
// while maintaining logical cohesion within the actor's isolation domain.

import CryptoKit
import Foundation
import os.log

// MARK: - EncryptedMemoryStore + Decryption Helpers

extension EncryptedMemoryStore {

  // MARK: - Decrypt (Pure Read)

  /// Decrypts nodes into events. Pure read — failed nodes are skipped.
  ///
  /// This method never modifies node state (no recall counter increment).
  /// Failed decryptions are logged at error level and silently skipped,
  /// ensuring a single corrupted node never crashes the entire pipeline.
  ///
  /// - Parameters:
  ///   - nodes: The ``RawMemoryNode`` records to decrypt.
  ///   - key: The AES-GCM symmetric key for decryption.
  /// - Returns: Successfully decrypted ``SpatialEvent`` values in input order.
  func decryptNodes(
    _ nodes: [RawMemoryNode],
    using key: SymmetricKey
  ) -> [SpatialEvent] {
    let signpostID = SignpostLogger.beginDecrypt(count: nodes.count)
    defer { SignpostLogger.endDecrypt(signpostID) }

    var events: [SpatialEvent] = []
    events.reserveCapacity(nodes.count)

    for node in nodes {
      do {
        let plaintext = try encryptionService.decrypt(node.encryptedPayload, using: key)
        let event = try decoder.decode(SpatialEvent.self, from: plaintext)
        events.append(event)
      } catch {
        incrementDecryptionFailure()
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to decrypt node \(node.id) — \(error.localizedDescription)"
        )
      }
    }

    return events
  }

  // MARK: - Decrypt + Recall (Side Effect)

  /// Decrypts nodes and increments the recall counter on each successful decryption.
  ///
  /// The recall counter (`node.recalled`) feeds the Survival Index formula:
  /// `SI(t) = S₀ · Rⁿ · e^(-λt)` where `n` = recalled count.
  ///
  /// - Important: This method **modifies** node state. The caller must follow up
  ///   with ``persistRecallCounters(eventCount:)`` to commit the changes.
  ///
  /// - Parameters:
  ///   - nodes: The ``RawMemoryNode`` records to decrypt and recall.
  ///   - key: The AES-GCM symmetric key for decryption.
  /// - Returns: Successfully decrypted ``SpatialEvent`` values in input order.
  func decryptAndRecall(
    _ nodes: [RawMemoryNode],
    using key: SymmetricKey
  ) -> [SpatialEvent] {
    let signpostID = SignpostLogger.beginDecrypt(count: nodes.count)
    defer { SignpostLogger.endDecrypt(signpostID) }

    var events: [SpatialEvent] = []
    events.reserveCapacity(nodes.count)

    for node in nodes {
      do {
        let plaintext = try encryptionService.decrypt(node.encryptedPayload, using: key)
        let event = try decoder.decode(SpatialEvent.self, from: plaintext)
        events.append(event)

        // Increment recall counter for Survival Index: SI(t) = S₀ · Rⁿ · e^(-λt)
        node.recalled += 1
      } catch {
        incrementDecryptionFailure()
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to decrypt node \(node.id) — \(error.localizedDescription)"
        )
      }
    }

    return events
  }

  // MARK: - Persist Recall Counters

  /// Persists recall counter increments to the backing store.
  ///
  /// - Parameter eventCount: Number of events that were successfully
  ///   decrypted and recall-incremented. If zero, no save is attempted.
  func persistRecallCounters(eventCount: Int) {
    guard eventCount > 0 else { return }
    do {
      try modelContext.save()
    } catch {
      // Rollback unsaved recall counter increments to prevent dirty state.
      // The in-memory node objects will revert to their pre-recall values,
      // ensuring consistency between the persisted store and runtime state.
      modelContext.rollback()
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Failed to persist recall counters — \(error.localizedDescription). Context rolled back."
      )
    }
  }
}
