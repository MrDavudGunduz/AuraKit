// EncryptedMemoryStore+Crypto.swift
// AuraKit — Core Infrastructure
//
// Sealing / opening primitives for EncryptedMemoryStore.
//
// Every ciphertext is bound to its row via AES-GCM Additional Authenticated
// Data (AAD). Moving a ciphertext into another row, relabelling its key
// version or event type, or swapping two archives is detected at open time.
//
// Records written by earlier AuraKit versions (no AAD) are still readable via
// a legacy fallback; their decoded identity is then verified against the
// row metadata so a swapped legacy payload is rejected as well.

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedRecord

/// A `Sendable` snapshot of the fields needed to open a ``RawMemoryNode``.
///
/// Reads snapshot `@Model` objects into this value **before** any `await`, so
/// actor reentrancy can never observe a node that was mutated or deleted while
/// the key lookup was suspended.
struct EncryptedRecord: Sendable {

  /// Row identifier (must match the decoded event's `id`).
  let id: UUID

  /// AES-GCM combined ciphertext.
  let payload: Data

  /// Key version recorded at seal time.
  let keyVersion: Int

  /// Raw ``SpatialEventType`` value stored in plaintext metadata.
  let eventType: String

  init(node: RawMemoryNode) {
    self.id = node.id
    self.payload = node.encryptedPayload
    self.keyVersion = node.keyVersion
    self.eventType = node.eventType
  }
}

// MARK: - EncryptedMemoryStore + AAD

extension EncryptedMemoryStore {

  /// AAD for a raw memory node: binds ciphertext to row id, key version and type.
  nonisolated static func rawRecordAAD(id: UUID, keyVersion: Int, eventType: String) -> Data {
    Data("aurakit.raw.v1|\(id.uuidString)|\(keyVersion)|\(eventType)".utf8)
  }

  /// AAD for an archive summary: binds ciphertext to archive id and key version.
  nonisolated static func archiveAAD(id: UUID, keyVersion: Int) -> Data {
    Data("aurakit.archive.v1|\(id.uuidString)|\(keyVersion)".utf8)
  }
}

// MARK: - EncryptedMemoryStore + Raw Node Sealing

extension EncryptedMemoryStore {

  /// Serialises and seals an event into a new (not yet inserted) ``RawMemoryNode``.
  ///
  /// - Parameters:
  ///   - event: The event to seal.
  ///   - key: The current symmetric key.
  ///   - keyVersion: The version of `key`; recorded on the node and bound via AAD.
  /// - Throws: Encoding or ``AuraError/encryptionFailed(reason:)`` errors.
  func sealNode(for event: SpatialEvent, key: SymmetricKey, keyVersion: Int) throws -> RawMemoryNode {
    let eventType = event.kind.eventType
    let plaintext = try encoder.encode(event)
    let aad = Self.rawRecordAAD(id: event.id, keyVersion: keyVersion, eventType: eventType.rawValue)
    let ciphertext = try encryptionService.encrypt(plaintext, using: key, authenticating: aad)

    return RawMemoryNode(
      id: event.id,
      encryptedPayload: ciphertext,
      score: event.score,
      timestamp: event.timestamp,
      eventType: eventType,
      keyVersion: keyVersion
    )
  }

  /// Opens a single record with the matching key from `ring`.
  ///
  /// Tries the AAD-bound format first, then the legacy (pre-AAD) format. In both
  /// cases the decoded event identity must match the row metadata.
  ///
  /// `nonisolated` and pure so it can run inside task-group children.
  nonisolated static func open(
    _ record: EncryptedRecord,
    ring: KeyRing,
    service: EncryptionService,
    decoder: JSONDecoder
  ) throws -> SpatialEvent {
    guard let key = ring.key(for: record.keyVersion) else {
      throw AuraError.decryptionFailed(
        reason: "Key material for version \(record.keyVersion) is unavailable."
      )
    }

    let aad = rawRecordAAD(id: record.id, keyVersion: record.keyVersion, eventType: record.eventType)
    let plaintext: Data
    do {
      plaintext = try service.decrypt(record.payload, using: key, authenticating: aad)
    } catch {
      // Legacy records (written before AAD binding) — identity verified below.
      plaintext = try service.decrypt(record.payload, using: key)
    }

    let event = try decoder.decode(SpatialEvent.self, from: plaintext)
    guard event.id == record.id, event.kind.eventType.rawValue == record.eventType else {
      throw AuraError.decryptionFailed(
        reason: "Decrypted payload does not belong to record \(record.id) (possible row swap)."
      )
    }
    return event
  }

  /// Decrypts records using a key ring resolved in a **single** actor hop.
  ///
  /// Per-record failures (tampering, purged key material, corruption) are
  /// counted in ``decryptionFailureCount`` and skipped. If the current key is
  /// unavailable (e.g. after ``KeyManager/clearCachedKey()`` in static mode)
  /// an empty array is returned.
  ///
  /// - Parameter records: Snapshots taken before this call's suspension point.
  /// - Returns: Successfully decrypted events, in input order.
  func decryptRecords(_ records: [EncryptedRecord]) async -> [SpatialEvent] {
    guard !records.isEmpty else { return [] }

    let signpostID = SignpostLogger.beginDecrypt(count: records.count)
    defer { SignpostLogger.endDecrypt(signpostID) }

    let ring: KeyRing
    do {
      ring = try await keyManager.keyRing(for: Set(records.map(\.keyVersion)))
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed — \(error.localizedDescription)"
      )
      return []
    }

    var events: [SpatialEvent] = []
    events.reserveCapacity(records.count)
    for record in records {
      do {
        events.append(try Self.open(record, ring: ring, service: encryptionService, decoder: decoder))
      } catch {
        incrementDecryptionFailure()
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to decrypt node \(record.id) — \(error.localizedDescription)"
        )
      }
    }
    return events
  }

  /// Increments the Survival Index recall counter (`n` in `SI = S₀·Rⁿ·e^(-λt)`)
  /// for the given node IDs.
  ///
  /// Nodes are **re-fetched** here (after any suspension) so a node deleted in
  /// the meantime is simply skipped. The save goes through the shared commit
  /// path, so coalesced inserts flushed alongside are accounted correctly.
  func incrementRecallCounters(for ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    do {
      let targetIDs = ids
      let descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { targetIDs.contains($0.id) }
      )
      let nodes = try modelContext.fetch(descriptor)
      guard !nodes.isEmpty else { return }
      for node in nodes {
        node.recalled += 1
      }
      commitPendingChanges(context: "Recall counter update")
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Recall counter fetch failed — \(error.localizedDescription)"
      )
    }
  }
}

// MARK: - EncryptedMemoryStore + Archive Sealing

extension EncryptedMemoryStore {

  /// Seals a consolidated summary for the archive with the given ID.
  ///
  /// The archive ID must be generated **before** sealing because it is bound
  /// into the ciphertext via AAD; pass the same ID to
  /// ``archiveAndPruneNodes(encryptedSummary:sourceNodeIDs:archiveNodeID:)``.
  ///
  /// - Parameters:
  ///   - summary: Plaintext summary produced by the language model.
  ///   - archiveID: The ID of the archive node that will hold the ciphertext.
  /// - Returns: AES-GCM combined ciphertext.
  public func sealArchiveSummary(_ summary: String, archiveID: UUID) async throws -> Data {
    let current = try await keyManager.currentKeyAndVersion()
    let aad = Self.archiveAAD(id: archiveID, keyVersion: current.version)
    return try encryptionService.encrypt(Data(summary.utf8), using: current.key, authenticating: aad)
  }

  /// Decrypts the summary of an archive node.
  ///
  /// Archives carry no key-version column, so every available key version is
  /// tried from newest to oldest (AAD-bound format first, then legacy).
  ///
  /// - Parameter id: The archive node ID.
  /// - Returns: The plaintext summary.
  /// - Throws: ``AuraError/decryptionFailed(reason:)`` if the archive does not
  ///   exist or cannot be opened with any available key.
  public func decryptArchiveSummary(id: UUID) async throws -> String {
    guard let payload = archivePayload(for: id) else {
      throw AuraError.decryptionFailed(reason: "Archive \(id) not found.")
    }
    let ring = try await archiveKeyRing()
    let opened = try Self.openArchive(payload, id: id, ring: ring, service: encryptionService)
    return opened.summary
  }

  /// Resolves a key ring containing every non-purged key version.
  func archiveKeyRing() async throws -> KeyRing {
    let currentVersion = await keyManager.keyVersion
    return try await keyManager.keyRing(for: Set(0...max(currentVersion, 0)))
  }

  /// Snapshot of an archive's ciphertext (actor-isolated fetch).
  func archivePayload(for id: UUID) -> Data? {
    var descriptor = FetchDescriptor<MemoryArchiveNode>(
      predicate: #Predicate<MemoryArchiveNode> { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return (try? modelContext.fetch(descriptor))?.first?.encryptedSummary
  }

  /// Opens an archive summary by trying every key in `ring`, newest first.
  ///
  /// - Returns: The plaintext summary and the key version that opened it.
  nonisolated static func openArchive(
    _ payload: Data,
    id: UUID,
    ring: KeyRing,
    service: EncryptionService
  ) throws -> (summary: String, keyVersion: Int) {
    for version in ring.keys.keys.sorted(by: >) {
      guard let key = ring.key(for: version) else { continue }
      let aad = archiveAAD(id: id, keyVersion: version)
      if let plaintext = try? service.decrypt(payload, using: key, authenticating: aad) {
        return (String(decoding: plaintext, as: UTF8.self), version)
      }
      if let plaintext = try? service.decrypt(payload, using: key) {
        return (String(decoding: plaintext, as: UTF8.self), version)
      }
    }
    throw AuraError.decryptionFailed(reason: "Archive \(id) could not be opened with any available key.")
  }
}
