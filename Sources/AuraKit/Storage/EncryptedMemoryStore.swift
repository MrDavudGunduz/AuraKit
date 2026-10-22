// EncryptedMemoryStore.swift
// AuraKit — Core Infrastructure
//
// Phase 2 drop-in replacement for MemoryStore. Conforms to SpatialEventStore
// and writes every event as AES-GCM ciphertext to SwiftData.
// Zero plaintext touches disk — ever.
//
// Sealing / opening   → EncryptedMemoryStore+Crypto.swift
// Commit & capacity   → EncryptedMemoryStore+RetryQueue.swift
// Metadata queries    → EncryptedMemoryStore+Queries.swift
// Streaming API       → EncryptedMemoryStore+Streaming.swift
// Key rotation        → EncryptedMemoryStore+KeyMigration.swift

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
/// **Write:** `SpatialEvent → JSONEncoder → AES-GCM(key_v, AAD = id‖v‖type) → RawMemoryNode`
///
/// **Read:** `RawMemoryNode → key ring[v] → AES-GCM open (AAD verified) → JSONDecoder → SpatialEvent`
///
/// `allEvents()` and `events(limit:offset:)` are **pure reads**. To increment
/// the Survival Index recall counter, use ``recallAndFetchAll()`` or
/// ``recallAndFetch(limit:offset:)`` explicitly.
///
/// ## Concurrency & Reentrancy
///
/// All operations are actor-isolated and the `ModelContext` never escapes.
/// Because actors are **reentrant**, every method performs at most one key
/// lookup `await` and treats `@Model` objects fetched *before* that suspension
/// as stale: payloads are snapshotted into `Sendable` values first, and nodes
/// are re-fetched before mutation.
///
/// ## Durability Accounting
///
/// Every insert is tracked in ``pendingInsertCount`` until a save commits it.
/// All saves go through a single commit path, so a failed save — wherever it
/// happens — reports **every** rolled-back event via ``droppedEventCount`` and
/// ``droppedEventStream``. No write is ever lost silently.
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
  /// Intentionally `internal` (not `private`) because `EncryptedMemoryStore` is
  /// split across multiple extension files. All extension files execute within
  /// this actor's isolation domain, so the `ModelContext` never escapes.
  let modelContext: ModelContext

  /// The key manager providing versioned Secure Enclave–derived symmetric keys.
  let keyManager: KeyManager

  /// Stateless encryption/decryption service.
  let encryptionService: EncryptionService

  /// Node count threshold at which ``allEvents()`` and ``recallAndFetchAll()``
  /// emit a runtime `Logger.warning`. Set to `0` to disable.
  nonisolated let largeDatasetWarningThreshold: Int

  /// Number of `append()` calls before a `ModelContext.save()` is issued.
  ///
  /// Write coalescing reduces SQLite I/O by batching inserts. Set to `1` to
  /// disable coalescing.
  nonisolated let saveThreshold: Int

  /// Maximum number of raw memory nodes kept on disk. `0` means unbounded.
  ///
  /// When exceeded after a commit, the **oldest** nodes (by timestamp) are
  /// evicted — the same FIFO semantics as ``MemoryStore``.
  nonisolated let capacity: Int

  /// Count of inserts pending commit. Reset to `0` after each commit or rollback.
  var pendingInsertCount: Int = 0

  /// JSON encoder used to serialise `SpatialEvent` before encryption.
  let encoder = JSONEncoder()

  /// JSON decoder used to deserialise `SpatialEvent` after decryption.
  let decoder = JSONDecoder()

  /// Cumulative count of events that failed to persist.
  var _droppedEventCount: Int = 0

  /// Cumulative count of individual node decryption failures.
  var _decryptionFailureCount: Int = 0

  /// Cumulative count of events successfully written to the store.
  var _totalEventsWritten: Int = 0

  /// Cumulative count of nodes evicted by the ``capacity`` limit.
  var _evictedEventCount: Int = 0

  /// Bounded queue for events that failed to persist on the first attempt.
  ///
  /// Events are retried on the next `append()` or scheduled drain. When full,
  /// the oldest queued event is permanently dropped to make room.
  var _retryQueue: [SpatialEvent] = []

  /// Maximum number of events that can be held in the retry queue.
  /// `0` disables retry entirely.
  nonisolated let retryQueueCapacity: Int

  /// Interval in seconds between scheduled retry queue drain attempts.
  /// `0` disables scheduled draining (retry only occurs on next `append()`).
  nonisolated let retryDrainInterval: TimeInterval

  /// Background task that periodically drains the retry queue.
  ///
  /// The task holds only a **weak** reference to the store, so it never keeps
  /// the store alive; it is cancelled in `deinit`.
  internal var retryDrainTask: Task<Void, Never>?

  /// Continuation for the dropped event notification stream.
  let _dropContinuation: AsyncStream<DroppedEvent>.Continuation

  /// An `AsyncStream` that emits a ``DroppedEvent`` each time an event fails
  /// to persist due to key retrieval, encryption, or save failure.
  ///
  /// ```swift
  /// Task {
  ///     for await drop in store.droppedEventStream {
  ///         logger.error("Event \(drop.eventID?.uuidString ?? "batch") dropped: \(drop.reason)")
  ///     }
  /// }
  /// ```
  ///
  /// The stream finishes when the store is deallocated. It uses a buffer
  /// policy of `.bufferingNewest(64)` to bound memory if the consumer lags.
  public let droppedEventStream: AsyncStream<DroppedEvent>

  // MARK: - Init

  /// Creates an `EncryptedMemoryStore` connected to the given SwiftData container.
  ///
  /// - Parameters:
  ///   - container: The `ModelContainer` providing the SwiftData backing store.
  ///     Use ``PersistenceController/makeContainer(cloudKitContainerIdentifier:)``
  ///     for production or ``PersistenceController/makeInMemoryContainer()`` for tests.
  ///   - keyManager: The ``KeyManager`` actor providing encryption keys.
  ///   - encryptionService: The ``EncryptionService`` for AES-GCM operations.
  ///   - largeDatasetWarningThreshold: Node count at which ``allEvents()``
  ///     emits a runtime warning. Pass `0` to disable.
  ///   - saveThreshold: Number of `append()` calls before persisting to disk.
  ///   - retryQueueCapacity: Maximum events held for retry. `0` disables retry.
  ///   - retryDrainInterval: Seconds between scheduled retry drains. `0` disables.
  ///   - capacity: Maximum raw nodes kept on disk; oldest are evicted first.
  ///     Defaults to `0` (unbounded) for source compatibility — production apps
  ///     should prefer ``init(container:configuration:keyManager:encryptionService:)``.
  public init(
    container: ModelContainer,
    keyManager: KeyManager = KeyManager(),
    encryptionService: EncryptionService = EncryptionService(),
    largeDatasetWarningThreshold: Int = AuraConfiguration.defaultLargeDatasetWarningThreshold,
    saveThreshold: Int = AuraConfiguration.defaultSaveThreshold,
    retryQueueCapacity: Int = AuraConfiguration.defaultRetryQueueCapacity,
    retryDrainInterval: TimeInterval = AuraConfiguration.defaultRetryDrainInterval,
    capacity: Int = 0
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
    self.capacity = max(capacity, 0)

    let (stream, continuation) = AsyncStream<DroppedEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
    self.droppedEventStream = stream
    self._dropContinuation = continuation

    // Start scheduled retry drain if enabled and retry queue is active.
    if self.retryDrainInterval > 0, self.retryQueueCapacity > 0 {
      Task { [weak self] in
        await self?.startScheduledRetryDrain()
      }
    }
  }

  /// Creates an `EncryptedMemoryStore` whose tuning parameters (capacity, save
  /// threshold, retry policy, warning threshold) come from a validated
  /// ``StorageConfiguration`` — the single source of truth also used by
  /// ``AuraConfiguration``.
  ///
  /// ```swift
  /// let config = try AuraConfiguration(...)
  /// let store = EncryptedMemoryStore(
  ///     container: try PersistenceController.makeContainer(),
  ///     configuration: config.storage
  /// )
  /// try AuraKit.shared.configure(with: config, store: store)
  /// ```
  public init(
    container: ModelContainer,
    configuration: StorageConfiguration,
    keyManager: KeyManager = KeyManager(),
    encryptionService: EncryptionService = EncryptionService()
  ) {
    self.init(
      container: container,
      keyManager: keyManager,
      encryptionService: encryptionService,
      largeDatasetWarningThreshold: configuration.largeDatasetWarningThreshold,
      saveThreshold: configuration.saveThreshold,
      retryQueueCapacity: configuration.retryQueueCapacity,
      retryDrainInterval: configuration.retryDrainInterval,
      capacity: configuration.capacity
    )
  }

  deinit {
    retryDrainTask?.cancel()
    _dropContinuation.finish()
  }

  // MARK: - Observability

  /// The cumulative count of events that failed to persist.
  ///
  /// - Note: This counter is never reset — it accumulates over the actor's lifetime.
  public var droppedEventCount: Int { _droppedEventCount }

  /// The cumulative count of individual node decryption failures.
  ///
  /// A non-zero value may indicate corrupted or tampered records, or records
  /// whose key material was purged before they were re-encrypted.
  public var decryptionFailureCount: Int { _decryptionFailureCount }

  /// The cumulative count of events successfully written to the store.
  ///
  /// `successRate = totalEventsWritten / (totalEventsWritten + droppedEventCount)`
  public var totalEventsWritten: Int { _totalEventsWritten }

  /// The cumulative count of nodes evicted because ``capacity`` was exceeded.
  public var evictedEventCount: Int { _evictedEventCount }

  /// The number of events currently held in the retry queue awaiting re-attempt.
  public var retryQueueCount: Int { _retryQueue.count }

  // MARK: - SpatialEventStore Conformance

  /// Encrypts and persists a ``SpatialEvent`` as a ``RawMemoryNode``.
  ///
  /// - Parameter event: The spatial event to persist.
  public func append(_ event: SpatialEvent) async {
    // Drain retry queue before processing the new event so previously failed
    // events get a second chance whenever the pipeline is healthy again.
    await drainRetryQueue()

    await appendInternal(event)
  }

  /// Encrypts and persists multiple events in a single batch operation.
  ///
  /// Inserts all nodes and commits **once**, reducing disk I/O from `N` writes
  /// to `1`. The commit also persists any coalesced inserts from earlier
  /// `append()` calls; if it fails, *all* rolled-back events (batch + coalesced)
  /// are reported as dropped.
  ///
  /// - Parameter events: The spatial events to persist.
  public func batchAppend(_ events: [SpatialEvent]) async {
    guard !events.isEmpty else { return }

    let signpostID = SignpostLogger.beginBatchEncrypt(count: events.count)
    defer { SignpostLogger.endBatchEncrypt(signpostID) }

    // Single suspension point: key and version are resolved atomically.
    let current: (key: SymmetricKey, version: Int)
    do {
      current = try await keyManager.currentKeyAndVersion()
    } catch {
      _droppedEventCount += events.count
      _dropContinuation.yield(DroppedEvent(
        reason: "Key retrieval failed during batch (\(events.count) events): \(error.localizedDescription)"
      ))
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Key retrieval failed during batch — \(error.localizedDescription)"
      )
      return
    }

    var insertedCount = 0
    for event in events {
      do {
        let node = try sealNode(for: event, key: current.key, keyVersion: current.version)
        modelContext.insert(node)
        pendingInsertCount += 1
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

    if commitPendingChanges(context: "Batch save") {
      Self.logger.debug(
        "[AuraKit] EncryptedMemoryStore: Batch persisted \(insertedCount) events in a single save."
      )
    }
  }

  /// Fetches all stored events, decrypting each payload. **Pure read** — no
  /// state is modified. Events returned chronologically; failed decryptions are skipped.
  ///
  /// - Warning: This method performs a **full-table decrypt**. For stores with
  ///   1,000+ events, prefer ``events(limit:offset:)`` or ``eventStream(limit:offset:batchSize:)``.
  public func allEvents() async -> [SpatialEvent] {
    do {
      let descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      let records = try modelContext.fetch(descriptor).map(EncryptedRecord.init(node:))
      warnIfLargeDataset(records.count, operation: "allEvents()")
      return await decryptRecords(records)
    } catch {
      Self.logger.error("[AuraKit] EncryptedMemoryStore: Fetch failed — \(error.localizedDescription)")
      return []
    }
  }

  /// Fetches a paginated slice of events, decrypting only `limit` payloads.
  /// **Pure read** — use ``recallAndFetch(limit:offset:)`` to also increment
  /// recall counters.
  public func events(limit: Int, offset: Int = 0) async -> [SpatialEvent] {
    guard limit > 0 else { return [] }
    do {
      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      descriptor.fetchLimit = limit
      descriptor.fetchOffset = max(offset, 0)

      let records = try modelContext.fetch(descriptor).map(EncryptedRecord.init(node:))
      return await decryptRecords(records)
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
        return try modelContext.fetchCount(FetchDescriptor<RawMemoryNode>())
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
  /// `SI(t) = S₀·Rⁿ·e^(-λt)`) for each. For read-only access, use ``allEvents()``.
  public func recallAndFetchAll() async -> [SpatialEvent] {
    do {
      let descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      let records = try modelContext.fetch(descriptor).map(EncryptedRecord.init(node:))
      warnIfLargeDataset(records.count, operation: "recallAndFetchAll()")

      let events = await decryptRecords(records)
      incrementRecallCounters(for: Set(events.map(\.id)))
      return events
    } catch {
      Self.logger.error("[AuraKit] EncryptedMemoryStore: Recall fetch failed — \(error.localizedDescription)")
      return []
    }
  }

  /// Paginated variant of ``recallAndFetchAll()`` with recall-counter increment.
  /// For read-only access, use ``events(limit:offset:)``.
  public func recallAndFetch(limit: Int, offset: Int = 0) async -> [SpatialEvent] {
    guard limit > 0 else { return [] }
    do {
      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      descriptor.fetchLimit = limit
      descriptor.fetchOffset = max(offset, 0)

      let records = try modelContext.fetch(descriptor).map(EncryptedRecord.init(node:))
      let events = await decryptRecords(records)
      incrementRecallCounters(for: Set(events.map(\.id)))
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

  // MARK: - Helpers

  /// Emits the large-dataset warning for full-table operations.
  func warnIfLargeDataset(_ nodeCount: Int, operation: StaticString) {
    guard largeDatasetWarningThreshold > 0, nodeCount > largeDatasetWarningThreshold else { return }
    Self.logger.warning(
      """
      [AuraKit] EncryptedMemoryStore: \(operation) is decrypting \
      \(nodeCount) nodes (threshold: \(self.largeDatasetWarningThreshold)). \
      Consider using events(limit:offset:) or eventStream() to avoid \
      memory pressure spikes from full-table decryption.
      """
    )
  }
}
