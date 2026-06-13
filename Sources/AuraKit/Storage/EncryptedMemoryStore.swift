// EncryptedMemoryStore.swift
// AuraKit — Core Infrastructure
//
// Phase 2 drop-in replacement for MemoryStore. Conforms to SpatialEventStore
// and writes every event as AES-GCM ciphertext to SwiftData.
// Zero plaintext touches disk — ever.
//
// Metadata queries → EncryptedMemoryStore+Queries.swift
// Decrypt helpers  → EncryptedMemoryStore+Decryption.swift
// Streaming API    → EncryptedMemoryStore+Streaming.swift

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore

/// An actor-isolated, AES-GCM encrypted persistent store backed by SwiftData.
///
/// Phase 2 implementation of ``SpatialEventStore``. Provides the same
/// `append / allEvents / count` API as ``MemoryStore``, but persists every
/// ``SpatialEvent`` as AES-GCM ciphertext in the on-device SwiftData store.
///
/// **Write:** `SpatialEvent → JSONEncoder → EncryptionService.encrypt → RawMemoryNode → ModelContext`
///
/// **Read:** `ModelContext.fetch → EncryptionService.decrypt → JSONDecoder → SpatialEvent`
///
/// `allEvents()` and `events(limit:offset:)` are **pure reads**. To increment
/// the Survival Index recall counter, use ``recallAndFetchAll()`` or
/// ``recallAndFetch(limit:offset:)`` explicitly.
///
/// All operations are actor-isolated. The `ModelContext` never escapes.
public actor EncryptedMemoryStore: SpatialEventStore {

  // MARK: - Internal Logger

  static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "EncryptedMemoryStore"
  )

  // MARK: - Dependencies

  /// The SwiftData model context, created from the injected container.
  /// Owned exclusively by this actor — never shared across concurrency domains.
  ///
  /// ## Access Level
  ///
  /// Intentionally `internal` (not `private`) because `EncryptedMemoryStore` is
  /// split across multiple extension files (`+Decryption`, `+Queries`, `+Streaming`)
  /// for SwiftLint file-length compliance. All extension files execute within this
  /// actor’s isolation domain, so the `ModelContext` never escapes its thread-safety
  /// boundary. Host applications cannot access this property (`internal` ≠ `public`).
  let modelContext: ModelContext

  /// The key manager providing the Secure Enclave–derived symmetric key.
  let keyManager: KeyManager

  /// Stateless encryption/decryption service.
  let encryptionService: EncryptionService

  /// JSON encoder used to serialise `SpatialEvent` before encryption.
  let encoder = JSONEncoder()

  /// JSON decoder used to deserialise `SpatialEvent` after decryption.
  let decoder = JSONDecoder()

  /// Cumulative count of events that failed to persist due to key, encryption,
  /// or save errors. Monitor this value in production telemetry to detect
  /// silent data loss.
  private var _droppedEventCount: Int = 0

  /// Cumulative count of individual node decryption failures.
  /// A non-zero value indicates corrupted or key-mismatched records.
  private var _decryptionFailureCount: Int = 0

  /// Cumulative count of events successfully written to the store.
  private var _totalEventsWritten: Int = 0

  // MARK: - Init

  /// Creates an `EncryptedMemoryStore` connected to the given SwiftData container.
  ///
  /// - Parameters:
  ///   - container: The `ModelContainer` providing the SwiftData backing store.
  ///     Use ``PersistenceController/makeContainer(cloudKitContainerIdentifier:)``
  ///     for production or ``PersistenceController/makeInMemoryContainer()`` for tests.
  ///   - keyManager: The ``KeyManager`` actor providing encryption keys.
  ///     Defaults to a new instance if not provided.
  ///   - encryptionService: The ``EncryptionService`` for AES-GCM operations.
  ///     Defaults to a new instance.
  public init(
    container: ModelContainer,
    keyManager: KeyManager = KeyManager(),
    encryptionService: EncryptionService = EncryptionService()
  ) {
    self.modelContext = ModelContext(container)
    // Explicit save() calls control write timing — disable autosave
    // to prevent duplicate writes and timing conflicts.
    self.modelContext.autosaveEnabled = false
    self.keyManager = keyManager
    self.encryptionService = encryptionService
  }

  // MARK: - Observability

  /// The cumulative count of events that failed to persist.
  ///
  /// Events are "dropped" when key retrieval fails, encryption fails, or
  /// the `ModelContext.save()` call fails. Monitor this value to detect
  /// silent data loss in production telemetry.
  ///
  /// - Note: This counter is never reset — it accumulates over the actor's
  ///   lifetime. A non-zero value after a batch write indicates partial failure.
  public var droppedEventCount: Int { _droppedEventCount }

  /// The cumulative count of individual node decryption failures.
  ///
  /// Incremented each time a ``RawMemoryNode`` fails to decrypt during
  /// ``allEvents()``, ``events(limit:offset:)``, ``recallAndFetchAll()``,
  /// or ``eventStream()``. A non-zero value may indicate corrupted records
  /// or a key version mismatch requiring re-encryption migration.
  public var decryptionFailureCount: Int { _decryptionFailureCount }

  /// The cumulative count of events successfully written to the store.
  ///
  /// Combined with ``droppedEventCount``, this provides a write success rate:
  /// `successRate = totalEventsWritten / (totalEventsWritten + droppedEventCount)`
  public var totalEventsWritten: Int { _totalEventsWritten }

  // MARK: - SpatialEventStore Conformance

  /// Encrypts and persists a ``SpatialEvent`` as a ``RawMemoryNode``.
  ///
  /// The event is serialised to JSON, encrypted with AES-GCM, and stored
  /// in SwiftData. Only the encrypted ciphertext is written to disk.
  ///
  /// - Parameter event: The spatial event to persist.
  public func append(_ event: SpatialEvent) async {
    let signpostID = SignpostLogger.beginEncrypt()
    defer { SignpostLogger.endEncrypt(signpostID) }

    do {
      let key = try await keyManager.symmetricKey()
      let currentKeyVersion = await keyManager.keyVersion
      let plaintext = try encoder.encode(event)
      let ciphertext = try encryptionService.encrypt(plaintext, using: key)

      let node = RawMemoryNode(
        id: event.id,
        encryptedPayload: ciphertext,
        score: event.score,
        timestamp: event.timestamp,
        eventType: event.kind.eventType,
        keyVersion: currentKeyVersion
      )

      modelContext.insert(node)

      do {
        try modelContext.save()
        _totalEventsWritten += 1
      } catch {
        // Rollback the unsaved insert to prevent dirty state accumulation.
        // Without rollback, the failed node remains in the context and could
        // cause duplicate writes or constraint violations on the next save.
        modelContext.rollback()
        _droppedEventCount += 1
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to save context — \(error.localizedDescription). Context rolled back."
        )
      }
    } catch {
      _droppedEventCount += 1
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Encryption failed for event \(event.id) — \(error.localizedDescription)"
      )
    }
  }

  /// Encrypts and persists multiple events in a single batch operation.
  ///
  /// Inserts all nodes into the `ModelContext` and issues a **single** `save()`,
  /// reducing disk I/O from `N` writes to `1`. Events that fail encryption are
  /// individually skipped; if the final `save()` fails, all inserted nodes are
  /// rolled back by SwiftData.
  ///
  /// - Parameter events: The spatial events to persist.
  public func batchAppend(_ events: [SpatialEvent]) async {
    guard !events.isEmpty else { return }

    let signpostID = SignpostLogger.beginBatchEncrypt(count: events.count)
    defer { SignpostLogger.endBatchEncrypt(signpostID) }

    do {
      let key = try await keyManager.symmetricKey()
      let currentKeyVersion = await keyManager.keyVersion
      var insertedCount = 0

      for event in events {
        do {
          let plaintext = try encoder.encode(event)
          let ciphertext = try encryptionService.encrypt(plaintext, using: key)

          let node = RawMemoryNode(
            id: event.id,
            encryptedPayload: ciphertext,
            score: event.score,
            timestamp: event.timestamp,
            eventType: event.kind.eventType,
            keyVersion: currentKeyVersion
          )

          modelContext.insert(node)
          insertedCount += 1
        } catch {
          _droppedEventCount += 1
          Self.logger.error(
            "[AuraKit] EncryptedMemoryStore: Encryption failed for event \(event.id) — \(error.localizedDescription)"
          )
        }
      }

      guard insertedCount > 0 else { return }

      do {
        try modelContext.save()
        _totalEventsWritten += insertedCount
        Self.logger.debug(
          "[AuraKit] EncryptedMemoryStore: Batch persisted \(insertedCount) events in a single save."
        )
      } catch {
        // Rollback all unsaved inserts to prevent partial dirty state.
        modelContext.rollback()
        _droppedEventCount += insertedCount
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Batch save failed — \(error.localizedDescription). Context rolled back."
        )
      }
    } catch {
      _droppedEventCount += events.count
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed during batch — \(error.localizedDescription)"
      )
    }
  }

  /// Fetches all stored events, decrypting each payload. **Pure read** — no
  /// state is modified. Use ``recallAndFetchAll()`` to also increment recall
  /// counters. Events returned chronologically; failed decryptions are skipped.
  public func allEvents() async -> [SpatialEvent] {
    do {
      let key = try await keyManager.symmetricKey()

      let descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )

      let nodes = try modelContext.fetch(descriptor)
      return decryptNodes(nodes, using: key)
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// Fetches a paginated slice of events, decrypting only `limit` payloads.
  /// **Pure read** — use ``recallAndFetch(limit:offset:)`` to also increment
  /// recall counters.
  public func events(limit: Int, offset: Int = 0) async -> [SpatialEvent] {
    guard limit > 0 else { return [] }
    do {
      let key = try await keyManager.symmetricKey()

      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      descriptor.fetchLimit = limit
      descriptor.fetchOffset = offset

      let nodes = try modelContext.fetch(descriptor)
      return decryptNodes(nodes, using: key)
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Paginated fetch failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// The total number of encrypted memory nodes in the store.
  public var count: Int {
    get async {
      do {
        let descriptor = FetchDescriptor<RawMemoryNode>()
        return try modelContext.fetchCount(descriptor)
      } catch {
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: fetchCount failed — \(error.localizedDescription)"
        )
        return 0
      }
    }
  }

  // MARK: - Recall API (Explicit Side Effect)

  /// Fetches all events **and** increments the recall counter (`n` in
  /// `SI(t) = S₀·Rⁿ·e^(-λt)`) for each. For read-only access, use
  /// ``allEvents()``.
  public func recallAndFetchAll() async -> [SpatialEvent] {
    do {
      let key = try await keyManager.symmetricKey()

      let descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )

      let nodes = try modelContext.fetch(descriptor)
      let events = decryptAndRecall(nodes, using: key)
      persistRecallCounters(eventCount: events.count)
      return events
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// Paginated variant of ``recallAndFetchAll()`` with recall-counter increment.
  /// For read-only access, use ``events(limit:offset:)``.
  public func recallAndFetch(limit: Int, offset: Int = 0) async -> [SpatialEvent] {
    guard limit > 0 else { return [] }
    do {
      let key = try await keyManager.symmetricKey()

      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      descriptor.fetchLimit = limit
      descriptor.fetchOffset = offset

      let nodes = try modelContext.fetch(descriptor)
      let events = decryptAndRecall(nodes, using: key)
      persistRecallCounters(eventCount: events.count)
      return events
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Paginated recall fetch failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  // MARK: - Pruning

  /// Deletes all nodes with a score below the given threshold.
  ///
  /// Used by Phase 3's Survival Index pruning. Only the metadata score
  /// is evaluated — no decryption occurs.
  ///
  /// - Parameter threshold: Nodes with `score < threshold` are deleted.
  /// - Returns: The number of nodes deleted.
  @discardableResult
  public func deleteNodes(belowScore threshold: Double) async -> Int {
    do {
      let descriptor = FetchDescriptor<RawMemoryNode>(
        predicate: #Predicate<RawMemoryNode> { $0.score < threshold }
      )

      let nodes = try modelContext.fetch(descriptor)
      let deletedCount = nodes.count

      for node in nodes {
        modelContext.delete(node)
      }

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

  // MARK: - Metrics

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

// MARK: - StoreMetrics

/// An immutable, `Sendable` snapshot of ``EncryptedMemoryStore`` observability
/// counters captured at a single point in time.
///
/// Designed for production telemetry — pass this across actor boundaries
/// without holding a reference to the store itself.
public struct StoreMetrics: Sendable, Equatable {

  /// Total number of events successfully encrypted and persisted.
  public let totalEventsWritten: Int

  /// Total number of events that failed to persist (key, encryption, or save failure).
  public let droppedEventCount: Int

  /// Total number of individual node decryption failures.
  public let decryptionFailureCount: Int

  /// The write success rate as a percentage `[0.0, 100.0]`.
  ///
  /// Returns `100.0` when no events have been processed (no failures, no writes).
  public var writeSuccessRate: Double {
    let total = totalEventsWritten + droppedEventCount
    guard total > 0 else { return 100.0 }
    return (Double(totalEventsWritten) / Double(total)) * 100.0
  }
}
