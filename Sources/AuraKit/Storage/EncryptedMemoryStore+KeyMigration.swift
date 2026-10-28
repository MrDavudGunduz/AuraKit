// EncryptedMemoryStore+KeyMigration.swift
// AuraKit — Core Infrastructure
//
// Post-rotation re-encryption for EncryptedMemoryStore.
//
// `KeyManager.rotateKey()` only creates a new key version; existing records
// stay readable through the versioned key ring. These APIs migrate records to
// the current key and — once nothing references older versions — allow the
// retired key material to be purged (crypto-shredding the old key).
//
//   try await keyManager.rotateKey()
//   try await store.completeKeyRotationMigration()   // re-encrypt + purge

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Key Migration

extension EncryptedMemoryStore {

  /// Number of raw nodes encrypted with a key version other than the current one.
  ///
  /// Metadata-only query — no decryption occurs.
  ///
  /// - Throws: The underlying fetch error. A failed count must never be read
  ///   as "no stale nodes": ``completeKeyRotationMigration()`` uses this value
  ///   to decide whether retired keys may be crypto-shredded.
  public func staleNodeCount() async throws -> Int {
    let currentVersion = await keyManager.keyVersion
    return try staleNodeCount(relativeTo: currentVersion)
  }

  /// Number of raw nodes whose key version differs from `version`.
  func staleNodeCount(relativeTo version: Int) throws -> Int {
    let descriptor = FetchDescriptor<RawMemoryNode>(
      predicate: #Predicate<RawMemoryNode> { $0.keyVersion != version }
    )
    return try modelContext.fetchCount(descriptor)
  }

  /// Re-encrypts every raw node sealed with an older key version using the
  /// current key, in batches.
  ///
  /// ## Safety
  ///
  /// - Nodes are snapshotted before each key-ring `await` and **re-fetched**
  ///   before mutation; a node deleted or changed concurrently is skipped.
  /// - Records that cannot be opened (tampered, or key material missing) are
  ///   counted in ``decryptionFailureCount``, excluded from later batches, and
  ///   left untouched — they keep their old version, so
  ///   ``completeKeyRotationMigration()`` will refuse to purge.
  /// - Each batch is committed through the shared commit path.
  ///
  /// - Parameter batchSize: Nodes per batch (bounded memory). Defaults to `100`.
  /// - Returns: Number of nodes migrated to the current key version.
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if the current key is
  ///   unavailable or a batch cannot be saved; `CancellationError` if cancelled.
  @discardableResult
  public func reencryptStaleNodes(batchSize: Int = 100) async throws -> Int {
    await flushPendingWrites()

    let size = max(batchSize, 1)
    var migrated = 0
    var excludedIDs = Set<UUID>()

    while true {
      try Task.checkCancellation()

      let currentVersion = await keyManager.keyVersion
      let records = try fetchStaleRecords(
        notMatching: currentVersion,
        excluding: excludedIDs,
        limit: size
      )
      guard !records.isEmpty else { break }

      let ring = try await resolveMigrationKeyRing(for: records)
      let targetVersion = ring.currentVersion
      guard let targetKey = ring.key(for: targetVersion) else {
        throw AuraError.keyRotationFailed(reason: "Current key missing from key ring.")
      }

      let resealed = resealBatch(
        records,
        ring: ring,
        targetKey: targetKey,
        targetVersion: targetVersion,
        excludedIDs: &excludedIDs
      )
      guard !resealed.isEmpty else { continue }

      migrated += try applyResealedBatch(resealed, targetVersion: targetVersion)
    }

    if !excludedIDs.isEmpty {
      Self.logger.warning(
        "[AuraKit] EncryptedMemoryStore: \(excludedIDs.count) node(s) could not be migrated."
      )
    }
    Self.logger.info(
      "[AuraKit] EncryptedMemoryStore: Re-encrypted \(migrated) node(s) to the current key."
    )
    return migrated
  }

  private func fetchStaleRecords(
    notMatching currentVersion: Int,
    excluding excluded: Set<UUID>,
    limit: Int
  ) throws -> [EncryptedRecord] {
    var descriptor = FetchDescriptor<RawMemoryNode>(
      predicate: #Predicate<RawMemoryNode> {
        $0.keyVersion != currentVersion && !excluded.contains($0.id)
      },
      sortBy: [SortDescriptor(\.timestamp, order: .forward)]
    )
    descriptor.fetchLimit = limit

    do {
      return try modelContext.fetch(descriptor).map(EncryptedRecord.init(node:))
    } catch {
      throw AuraError.keyRotationFailed(
        reason: "Failed to fetch stale nodes: \(error.localizedDescription)"
      )
    }
  }

  private func resolveMigrationKeyRing(for records: [EncryptedRecord]) async throws -> KeyRing {
    do {
      return try await keyManager.keyRing(for: Set(records.map(\.keyVersion)))
    } catch {
      throw AuraError.keyRotationFailed(
        reason: "Current key unavailable during migration: \(error.localizedDescription)"
      )
    }
  }

  private func resealBatch(
    _ records: [EncryptedRecord],
    ring: KeyRing,
    targetKey: SymmetricKey,
    targetVersion: Int,
    excludedIDs: inout Set<UUID>
  ) -> [UUID: (sourceVersion: Int, payload: Data)] {
    var resealed: [UUID: (sourceVersion: Int, payload: Data)] = [:]
    for record in records {
      do {
        let event = try Self.open(record, ring: ring, service: encryptionService, decoder: decoder)
        let aad = Self.rawRecordAAD(
          id: event.id,
          keyVersion: targetVersion,
          eventType: event.kind.eventType.rawValue
        )
        let payload = try encryptionService.encrypt(
          try encoder.encode(event),
          using: targetKey,
          authenticating: aad
        )
        resealed[record.id] = (record.keyVersion, payload)
      } catch {
        excludedIDs.insert(record.id)
        incrementDecryptionFailure()
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Cannot migrate node \(record.id) — \(error.localizedDescription)"
        )
      }
    }
    return resealed
  }

  private func applyResealedBatch(
    _ resealed: [UUID: (sourceVersion: Int, payload: Data)],
    targetVersion: Int
  ) throws -> Int {
    let ids = Set(resealed.keys)
    let nodes: [RawMemoryNode]
    do {
      nodes = try modelContext.fetch(FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { ids.contains($0.id) }
      ))
    } catch {
      throw AuraError.keyRotationFailed(
        reason: "Failed to re-fetch nodes for migration: \(error.localizedDescription)"
      )
    }

    var batchMigrated = 0
    for node in nodes {
      guard let entry = resealed[node.id], node.keyVersion == entry.sourceVersion else { continue }
      node.encryptedPayload = entry.payload
      node.keyVersion = targetVersion
      batchMigrated += 1
    }

    guard commitPendingChanges(context: "Key migration batch") else {
      throw AuraError.keyRotationFailed(
        reason: "Failed to save re-encrypted batch; context rolled back."
      )
    }
    return batchMigrated
  }

  /// Re-encrypts every archive summary with the current key (AAD-bound).
  ///
  /// - Returns: Number of archives re-encrypted.
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if the current key is
  ///   unavailable or the batch cannot be saved.
  @discardableResult
  public func reencryptArchives() async throws -> Int {
    try await reencryptArchivesReportingFailures().migrated
  }

  /// Re-encrypts archives and reports how many could not be opened.
  func reencryptArchivesReportingFailures() async throws -> (migrated: Int, failed: Int) {
    await flushPendingWrites()

    let snapshots: [(id: UUID, payload: Data)]
    do {
      snapshots = try modelContext.fetch(FetchDescriptor<MemoryArchiveNode>())
        .map { ($0.id, $0.encryptedSummary) }
    } catch {
      throw AuraError.keyRotationFailed(reason: "Failed to fetch archives: \(error.localizedDescription)")
    }
    guard !snapshots.isEmpty else { return (0, 0) }

    let ring: KeyRing
    do {
      ring = try await archiveKeyRing()
    } catch {
      throw AuraError.keyRotationFailed(
        reason: "Current key unavailable during archive migration: \(error.localizedDescription)"
      )
    }
    let targetVersion = ring.currentVersion
    guard let targetKey = ring.key(for: targetVersion) else {
      throw AuraError.keyRotationFailed(reason: "Current key missing from key ring.")
    }

    var resealed: [UUID: (original: Data, payload: Data)] = [:]
    var failed = 0
    for snapshot in snapshots {
      do {
        let opened = try Self.openArchive(snapshot.payload, id: snapshot.id, ring: ring, service: encryptionService)
        let payload = try encryptionService.encrypt(
          Data(opened.summary.utf8),
          using: targetKey,
          authenticating: Self.archiveAAD(id: snapshot.id, keyVersion: targetVersion)
        )
        resealed[snapshot.id] = (snapshot.payload, payload)
      } catch {
        failed += 1
        incrementDecryptionFailure()
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Cannot migrate archive \(snapshot.id) — \(error.localizedDescription)"
        )
      }
    }
    guard !resealed.isEmpty else { return (0, failed) }

    let ids = Set(resealed.keys)
    let archives: [MemoryArchiveNode]
    do {
      archives = try modelContext.fetch(FetchDescriptor<MemoryArchiveNode>(
        predicate: #Predicate<MemoryArchiveNode> { ids.contains($0.id) }
      ))
    } catch {
      throw AuraError.keyRotationFailed(reason: "Failed to re-fetch archives: \(error.localizedDescription)")
    }

    var migrated = 0
    for archive in archives {
      guard let entry = resealed[archive.id], archive.encryptedSummary == entry.original else { continue }
      archive.encryptedSummary = entry.payload
      migrated += 1
    }

    guard commitPendingChanges(context: "Archive key migration") else {
      throw AuraError.keyRotationFailed(reason: "Failed to save re-encrypted archives; context rolled back.")
    }
    return (migrated, failed)
  }

  /// Finishes a key rotation: re-encrypts all nodes and archives with the
  /// current key, verifies nothing references older versions, then purges the
  /// retired key material (crypto-shredding data sealed with old keys).
  ///
  /// ```swift
  /// try await keyManager.rotateKey()
  /// try await store.completeKeyRotationMigration()
  /// ```
  ///
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if any node or archive
  ///   could not be migrated. In that case **no key material is purged**, so
  ///   the data stays readable and the call can be retried.
  public func completeKeyRotationMigration() async throws {
    try await reencryptStaleNodes()
    let archiveResult = try await reencryptArchivesReportingFailures()

    let targetVersion = await keyManager.keyVersion
    let remaining: Int
    do {
      remaining = try staleNodeCount(relativeTo: targetVersion)
    } catch {
      throw AuraError.keyRotationFailed(
        reason: "Could not verify that no records reference retired keys (\(error.localizedDescription)); "
          + "retired key material was retained."
      )
    }
    guard remaining == 0, archiveResult.failed == 0 else {
      throw AuraError.keyRotationFailed(
        reason: "\(remaining) node(s) and \(archiveResult.failed) archive(s) still reference retired keys; "
          + "retired key material was retained."
      )
    }

    // Only versions strictly older than `targetVersion` are purged, so a
    // rotation racing with this call can never invalidate live records.
    try await keyManager.purgeRetiredKeyMaterial(olderThan: targetVersion)
    Self.logger.info(
      "[AuraKit] EncryptedMemoryStore: Key rotation migration complete — retired keys below v\(targetVersion) purged."
    )
  }
}
