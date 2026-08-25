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
    subsystem: AuraKitConstants.subsystem,
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

  /// Node count threshold at which ``allEvents()`` and ``recallAndFetchAll()``
  /// emit a runtime `Logger.warning`. Set to `0` to disable.
  nonisolated let largeDatasetWarningThreshold: Int

  /// Number of `append()` calls before a `ModelContext.save()` is issued.
  ///
  /// Write coalescing reduces SQLite I/O by batching inserts. When
  /// `pendingInsertCount` reaches this threshold, all pending inserts are
  /// persisted in a single save. Set to `1` to disable coalescing.
  nonisolated let saveThreshold: Int

  /// Count of inserts pending commit. Reset to `0` after each `save()`.
  var pendingInsertCount: Int = 0

  /// JSON encoder used to serialise `SpatialEvent` before encryption.
  let encoder = JSONEncoder()

  /// JSON decoder used to deserialise `SpatialEvent` after decryption.
  let decoder = JSONDecoder()

  /// Cumulative count of events that failed to persist due to key, encryption,
  /// or save errors. Monitor this value in production telemetry to detect
  /// silent data loss.
  ///
  /// - Note: Access level is `internal` (not `private`) to enable the
  ///   `EncryptedMemoryStore+Queries` extension to expose these via
  ///   ``StoreMetrics`` without requiring all metrics code in the main file.
  ///   Actor isolation guarantees exclusive access — no data races are possible.
  var _droppedEventCount: Int = 0

  /// Cumulative count of individual node decryption failures.
  /// A non-zero value indicates corrupted or key-mismatched records.
  var _decryptionFailureCount: Int = 0

  /// Cumulative count of events successfully written to the store.
  var _totalEventsWritten: Int = 0

  /// Bounded queue for events that failed to persist on the first attempt.
  ///
  /// Events are added to this queue when `append()` encounters a transient
  /// failure (key retrieval, encryption, or save). They are retried on the
  /// next successful `append()` call or when `flushRetryQueue()` is called.
  ///
  /// The queue capacity is configured by ``retryQueueCapacity``. When full,
  /// the oldest queued event is permanently dropped to make room.
  var _retryQueue: [SpatialEvent] = []

  /// Maximum number of events that can be held in the retry queue.
  /// Configured at init time. `0` disables retry entirely.
  nonisolated let retryQueueCapacity: Int

  /// Interval in seconds between scheduled retry queue drain attempts.
  /// `0` disables scheduled draining (retry only occurs on next `append()`).
  nonisolated let retryDrainInterval: TimeInterval

  /// Background task that periodically drains the retry queue.
  /// `nil` when scheduled draining is disabled (`retryDrainInterval == 0`).
  internal var retryDrainTask: Task<Void, Never>?

  /// Continuation for the dropped event notification stream.
  /// Retained for the lifetime of the actor; yields a ``DroppedEvent``
  /// each time an event fails to persist.
  let _dropContinuation: AsyncStream<DroppedEvent>.Continuation

  /// An `AsyncStream` that emits a ``DroppedEvent`` each time an event fails
  /// to persist due to key retrieval, encryption, or save failure.
  ///
  /// Subscribe to this stream in production to feed telemetry dashboards
  /// with real-time drop diagnostics:
  ///
  /// ```swift
  /// Task {
  ///     for await drop in store.droppedEventStream {
  ///         logger.error("Event \(drop.eventID?.uuidString ?? "batch") dropped: \(drop.reason)")
  ///     }
  /// }
  /// ```
  ///
  /// The stream is infinite — it never finishes on its own. It yields events
  /// only when drops occur; idle periods produce no output.
  ///
  /// - Note: The stream uses a buffer policy of `.bufferingNewest(64)` to prevent
  ///   unbounded memory growth if the consumer falls behind.
  public let droppedEventStream: AsyncStream<DroppedEvent>

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
  ///   - largeDatasetWarningThreshold: Node count at which ``allEvents()``
  ///     emits a runtime warning. Pass `0` to disable. Defaults to `1_000`.
  ///   - saveThreshold: Number of `append()` calls before persisting to disk.
  ///     Defaults to ``AuraConfiguration/defaultSaveThreshold`` (`10`).
  ///     Set to `1` to save on every append (legacy behaviour).
  public init(
    container: ModelContainer,
    keyManager: KeyManager = KeyManager(),
    encryptionService: EncryptionService = EncryptionService(),
    largeDatasetWarningThreshold: Int = AuraConfiguration.defaultLargeDatasetWarningThreshold,
    saveThreshold: Int = AuraConfiguration.defaultSaveThreshold,
    retryQueueCapacity: Int = AuraConfiguration.defaultRetryQueueCapacity,
    retryDrainInterval: TimeInterval = AuraConfiguration.defaultRetryDrainInterval
  ) {
    self.modelContext = ModelContext(container)
    // Explicit save() calls control write timing — disable autosave
    // to prevent duplicate writes and timing conflicts.
    self.modelContext.autosaveEnabled = false
    self.keyManager = keyManager
    self.encryptionService = encryptionService
    self.largeDatasetWarningThreshold = largeDatasetWarningThreshold
    self.saveThreshold = max(saveThreshold, 1)
    self.retryQueueCapacity = max(retryQueueCapacity, 0)
    self.retryDrainInterval = max(retryDrainInterval, 0)

    // Set up the dropped event notification stream.
    var continuation: AsyncStream<DroppedEvent>.Continuation!
    self.droppedEventStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
      continuation = $0
    }
    self._dropContinuation = continuation

    // Start scheduled retry drain if enabled and retry queue is active.
    if retryDrainInterval > 0, retryQueueCapacity > 0 {
      Task { [weak self] in
        await self?.startScheduledRetryDrain()
      }
    }
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

  /// The number of events currently held in the retry queue awaiting re-attempt.
  ///
  /// A persistently non-zero value indicates ongoing transient failures
  /// (e.g., Secure Enclave unavailability, disk I/O contention).
  public var retryQueueCount: Int { _retryQueue.count }

  // MARK: - SpatialEventStore Conformance

  /// Encrypts and persists a ``SpatialEvent`` as a ``RawMemoryNode``.
  ///
  /// The event is serialised to JSON, encrypted with AES-GCM, and stored
  /// in SwiftData. Only the encrypted ciphertext is written to disk.
  ///
  /// - Parameter event: The spatial event to persist.
  public func append(_ event: SpatialEvent) async {
    // Drain retry queue before processing the new event.
    // This ensures previously failed events get a second chance
    // whenever the pipeline is healthy enough to accept new events.
    await drainRetryQueue()

    await appendInternal(event)
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
          _dropContinuation.yield(DroppedEvent(
            eventID: event.id,
            reason: "Batch encryption failed: \(error.localizedDescription)"
          ))
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
        _dropContinuation.yield(DroppedEvent(
          reason: "Batch save failed (\(insertedCount) events): \(error.localizedDescription)"
        ))
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Batch save failed — \(error.localizedDescription). Context rolled back."
        )
      }
    } catch {
      _droppedEventCount += events.count
      _dropContinuation.yield(DroppedEvent(
        reason: "Key retrieval failed during batch (\(events.count) events): \(error.localizedDescription)"
      ))
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed during batch — \(error.localizedDescription)"
      )
    }
  }

  /// Fetches all stored events, decrypting each payload. **Pure read** — no
  /// state is modified. Use ``recallAndFetchAll()`` to also increment recall
  /// counters. Events returned chronologically; failed decryptions are skipped.
  ///
  /// - Warning: This method performs a **full-table decrypt**. For stores with
  ///   1,000+ events, prefer ``events(limit:offset:)`` or ``eventStream()``
  ///   to avoid memory pressure spikes.
  public func allEvents() async -> [SpatialEvent] {
    do {
      let key = try await keyManager.symmetricKey()
      let descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      let nodes = try modelContext.fetch(descriptor)

      // Runtime OOM protection: warn developers when full-table decrypt
      // is called on a large dataset. The warning recommends paginated or
      // streaming alternatives that maintain constant peak memory.
      if largeDatasetWarningThreshold > 0, nodes.count > largeDatasetWarningThreshold {
        Self.logger.warning(
          """
          [AuraKit] EncryptedMemoryStore: allEvents() is decrypting \
          \(nodes.count) nodes (threshold: \(self.largeDatasetWarningThreshold)). \
          Consider using events(limit:offset:) or eventStream() to avoid \
          memory pressure spikes from full-table decryption.
          """
        )
      }

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

      // Same large-dataset warning as allEvents().
      if largeDatasetWarningThreshold > 0, nodes.count > largeDatasetWarningThreshold {
        Self.logger.warning(
          """
          [AuraKit] EncryptedMemoryStore: recallAndFetchAll() is decrypting \
          \(nodes.count) nodes (threshold: \(self.largeDatasetWarningThreshold)). \
          Consider using recallAndFetch(limit:offset:) for large datasets.
          """
        )
      }

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

  // MARK: - Lifecycle & Security

  /// Clears sensitive cached symmetric keys from process memory when transitioning
  /// to the background, enforcing AuraKit's Zero-Trust design.
  public func clearSensitiveDataForBackground() async {
    await keyManager.clearCachedKeyForBackground()
    Self.logger.info("[AuraKit] EncryptedMemoryStore: Cleared sensitive key material for background transition.")
  }
}

