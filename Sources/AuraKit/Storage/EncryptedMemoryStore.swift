// EncryptedMemoryStore.swift
// AuraKit — Core Infrastructure
//
// Phase 2 drop-in replacement for MemoryStore. Conforms to SpatialEventStore
// and writes every event as AES-GCM ciphertext to SwiftData.
// Zero plaintext touches disk — ever.

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore

/// An actor-isolated, AES-GCM encrypted persistent store backed by SwiftData.
///
/// `EncryptedMemoryStore` is the Phase 2 implementation of ``SpatialEventStore``.
/// It provides the same `append / allEvents / count` API as ``MemoryStore``,
/// but persists every ``SpatialEvent`` as encrypted ciphertext in the on-device
/// SwiftData store.
///
/// ## Write Path
///
/// ```
/// SpatialEvent
///   → JSONEncoder.encode()
///   → EncryptionService.encrypt(_, using: symmetricKey)
///   → RawMemoryNode(encryptedPayload: ciphertext, ...)
///   → ModelContext.insert()
/// ```
///
/// ## Read Path
///
/// ```
/// ModelContext.fetch(FetchDescriptor<RawMemoryNode>)
///   → EncryptionService.decrypt(encryptedPayload, using: symmetricKey)
///   → JSONDecoder.decode(SpatialEvent.self, from: plaintext)
/// ```
///
/// ## Read vs Recall Semantics
///
/// `allEvents()` and `events(limit:offset:)` are **pure reads** — they do not
/// modify any stored state. To increment the Survival Index recall counter, use
/// ``recallAndFetchAll()`` or ``recallAndFetch(limit:offset:)`` explicitly.
/// This separation follows the **Principle of Least Surprise**: read methods
/// must not have write side effects.
///
/// ## Dependency Injection
///
/// `CaptureActor` depends on the ``SpatialEventStore`` protocol — not on this
/// concrete type. Swap `MemoryStore` for `EncryptedMemoryStore` at init:
///
/// ```swift
/// let store = try await EncryptedMemoryStore(container: container, keyManager: keyManager)
/// let actor = CaptureActor(config: config, store: store)
/// ```
///
/// ## Thread Safety
///
/// All operations are actor-isolated. The `ModelContext` is created on the
/// actor's executor and never escapes to other concurrency domains.
public actor EncryptedMemoryStore: SpatialEventStore {

  // MARK: - Internal Logger

  private static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "EncryptedMemoryStore"
  )

  // MARK: - Dependencies

  /// The SwiftData model context, created from the injected container.
  /// Owned exclusively by this actor — never shared across concurrency domains.
  private let modelContext: ModelContext

  /// The key manager providing the Secure Enclave–derived symmetric key.
  private let keyManager: KeyManager

  /// Stateless encryption/decryption service.
  private let encryptionService: EncryptionService

  /// JSON encoder used to serialise `SpatialEvent` before encryption.
  private let encoder = JSONEncoder()

  /// JSON decoder used to deserialise `SpatialEvent` after decryption.
  private let decoder = JSONDecoder()

  /// Cumulative count of events that failed to persist due to key, encryption,
  /// or save errors. Monitor this value in production telemetry to detect
  /// silent data loss.
  private var _droppedEventCount: Int = 0

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

  // MARK: - SpatialEventStore Conformance

  /// Encrypts and persists a ``SpatialEvent`` as a ``RawMemoryNode``.
  ///
  /// The event is serialised to JSON, encrypted with AES-GCM, and stored
  /// in SwiftData. Only the encrypted ciphertext is written to disk.
  ///
  /// - Parameter event: The spatial event to persist.
  public func append(_ event: SpatialEvent) async {
    do {
      let key = try await keyManager.symmetricKey()
      let plaintext = try encoder.encode(event)
      let ciphertext = try encryptionService.encrypt(plaintext, using: key)

      let node = RawMemoryNode(
        id: event.id,
        encryptedPayload: ciphertext,
        score: event.score,
        timestamp: event.timestamp,
        eventType: event.kind.eventType
      )

      modelContext.insert(node)

      do {
        try modelContext.save()
      } catch {
        _droppedEventCount += 1
        EncryptedMemoryStore.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to save context — \(error.localizedDescription)"
        )
      }
    } catch {
      _droppedEventCount += 1
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: Encryption failed for event \(event.id) — \(error.localizedDescription)"
      )
    }
  }

  /// Encrypts and persists multiple events in a single batch operation.
  ///
  /// Unlike sequential ``append(_:)`` calls — which issue a `save()` per event
  /// — `batchAppend` inserts all nodes into the `ModelContext` and issues a
  /// **single** `save()` at the end. For `N` events this reduces disk I/O
  /// from `N` writes to `1`.
  ///
  /// ## Performance
  ///
  /// | Events | `append()` I/O | `batchAppend()` I/O | Reduction |
  /// |--------|----------------|---------------------|-----------|
  /// | 10     | 10 saves       | 1 save              | 90%       |
  /// | 100    | 100 saves      | 1 save              | 99%       |
  /// | 1000   | 1000 saves     | 1 save              | 99.9%     |
  ///
  /// ## Error Handling
  ///
  /// Events that fail encryption are individually skipped with an error-level
  /// log — successfully encrypted events in the same batch are still persisted.
  /// If the final `save()` fails, all inserted nodes in the batch are lost
  /// (SwiftData rolls back uncommitted changes).
  ///
  /// - Parameter events: The spatial events to persist.
  public func batchAppend(_ events: [SpatialEvent]) async {
    guard !events.isEmpty else { return }

    do {
      let key = try await keyManager.symmetricKey()
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
            eventType: event.kind.eventType
          )

          modelContext.insert(node)
          insertedCount += 1
        } catch {
          _droppedEventCount += 1
          EncryptedMemoryStore.logger.error(
            "[AuraKit] EncryptedMemoryStore: Encryption failed for event \(event.id) — \(error.localizedDescription)"
          )
        }
      }

      guard insertedCount > 0 else { return }

      do {
        try modelContext.save()
        EncryptedMemoryStore.logger.debug(
          "[AuraKit] EncryptedMemoryStore: Batch persisted \(insertedCount) events in a single save."
        )
      } catch {
        _droppedEventCount += insertedCount
        EncryptedMemoryStore.logger.error(
          "[AuraKit] EncryptedMemoryStore: Batch save failed — \(error.localizedDescription)"
        )
      }
    } catch {
      _droppedEventCount += events.count
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed during batch — \(error.localizedDescription)"
      )
    }
  }

  /// Fetches all stored events, decrypting each payload before returning.
  ///
  /// This is a **pure read** operation — no stored state is modified.
  /// To also increment the Survival Index recall counter, use
  /// ``recallAndFetchAll()`` instead.
  ///
  /// Events are returned in chronological order (oldest first).
  /// Any node that fails decryption is silently skipped and an error-level
  /// log is emitted — partial results are returned rather than throwing.
  ///
  /// - Returns: All successfully decrypted ``SpatialEvent`` values.
  public func allEvents() async -> [SpatialEvent] {
    do {
      let key = try await keyManager.symmetricKey()

      let descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )

      let nodes = try modelContext.fetch(descriptor)
      return decryptNodes(nodes, using: key)
    } catch {
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// Fetches a paginated slice of stored events, decrypting each payload.
  ///
  /// This is a **pure read** operation — no stored state is modified.
  /// To also increment the Survival Index recall counter, use
  /// ``recallAndFetch(limit:offset:)`` instead.
  ///
  /// Use this instead of ``allEvents()`` when the store is expected to contain
  /// thousands of nodes. Each call decrypts only `limit` payloads, preventing
  /// memory pressure spikes from full-table decryption.
  ///
  /// - Parameters:
  ///   - limit: Maximum number of events to return.
  ///   - offset: Number of events to skip from the beginning.
  /// - Returns: Successfully decrypted events in chronological order.
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
      EncryptedMemoryStore.logger.error(
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
        EncryptedMemoryStore.logger.error(
          "[AuraKit] EncryptedMemoryStore: fetchCount failed — \(error.localizedDescription)"
        )
        return 0
      }
    }
  }

  // MARK: - Recall API (Explicit Side Effect)

  /// Fetches all stored events **and** increments the recall counter for
  /// each successfully decrypted node.
  ///
  /// Use this when the read is a genuine user-initiated "recall" — e.g.,
  /// feeding events to the Survival Index pipeline. For read-only operations
  /// (debugging, test assertions), prefer ``allEvents()`` which has no
  /// write side effects.
  ///
  /// ## Survival Index
  ///
  /// The recall counter `n` is used in the Survival Index formula:
  /// ```
  /// SI(t) = S₀ · Rⁿ · e^(-λt)
  /// ```
  ///
  /// - Returns: All successfully decrypted ``SpatialEvent`` values.
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
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  /// Fetches a paginated slice of events **and** increments the recall counter
  /// for each successfully decrypted node.
  ///
  /// For read-only operations, prefer ``events(limit:offset:)`` instead.
  ///
  /// - Parameters:
  ///   - limit: Maximum number of events to return.
  ///   - offset: Number of events to skip from the beginning.
  /// - Returns: Successfully decrypted events in chronological order.
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
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: Paginated recall fetch failed — \(error.localizedDescription)"
      )
      return []
    }
  }

  // MARK: - Metadata Queries

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
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: fetchNodeCount failed — \(error.localizedDescription)"
      )
      return 0
    }
  }

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
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: fetchNodes failed — \(error.localizedDescription)"
      )
      return []
    }
  }

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

      EncryptedMemoryStore.logger.info(
        "[AuraKit] EncryptedMemoryStore: Pruned \(deletedCount) nodes below threshold \(threshold)."
      )

      return deletedCount
    } catch {
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: deleteNodes failed — \(error.localizedDescription)"
      )
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

      EncryptedMemoryStore.logger.info(
        "[AuraKit] EncryptedMemoryStore: All nodes cleared."
      )
    } catch {
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: clear() failed — \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Private Decrypt Helpers

  /// Decrypts an array of ``RawMemoryNode`` records into ``SpatialEvent`` values.
  ///
  /// This is a **pure read** helper — it does not modify any node state.
  /// Nodes that fail decryption are silently skipped with an error log.
  ///
  /// - Parameters:
  ///   - nodes: The fetched nodes to decrypt.
  ///   - key: The symmetric key for AES-GCM decryption.
  /// - Returns: Successfully decrypted events in input order.
  private func decryptNodes(
    _ nodes: [RawMemoryNode],
    using key: SymmetricKey
  ) -> [SpatialEvent] {
    var events: [SpatialEvent] = []
    events.reserveCapacity(nodes.count)

    for node in nodes {
      do {
        let plaintext = try encryptionService.decrypt(node.encryptedPayload, using: key)
        let event = try decoder.decode(SpatialEvent.self, from: plaintext)
        events.append(event)
      } catch {
        EncryptedMemoryStore.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to decrypt node \(node.id) — \(error.localizedDescription)"
        )
      }
    }

    return events
  }

  /// Decrypts nodes **and** increments the recall counter on each success.
  ///
  /// - Parameters:
  ///   - nodes: The fetched nodes to decrypt and recall-mark.
  ///   - key: The symmetric key for AES-GCM decryption.
  /// - Returns: Successfully decrypted events in input order.
  private func decryptAndRecall(
    _ nodes: [RawMemoryNode],
    using key: SymmetricKey
  ) -> [SpatialEvent] {
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
        EncryptedMemoryStore.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to decrypt node \(node.id) — \(error.localizedDescription)"
        )
      }
    }

    return events
  }

  /// Persists recall counter increments to the backing store.
  ///
  /// - Parameter eventCount: Number of events that were successfully
  ///   decrypted and recall-incremented. If zero, no save is attempted.
  private func persistRecallCounters(eventCount: Int) {
    guard eventCount > 0 else { return }
    do {
      try modelContext.save()
    } catch {
      EncryptedMemoryStore.logger.error(
        "[AuraKit] EncryptedMemoryStore: Failed to persist recall counters — \(error.localizedDescription)"
      )
    }
  }
}
