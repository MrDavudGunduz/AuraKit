// EncryptedMemoryStore+RetryQueue.swift
// AuraKit — Core Infrastructure
//
// Retry queue mechanism for EncryptedMemoryStore.
// Extracted from EncryptedMemoryStore.swift for SwiftLint file_length compliance
// while maintaining logical cohesion within the actor's isolation domain.
//
// When append() encounters a transient failure (key retrieval, encryption,
// or save error), the event is placed in a bounded retry queue instead of
// being permanently dropped. Queued events are retried on the next append().

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Shared Encrypt-Insert Pipeline

extension EncryptedMemoryStore {

  // MARK: - Shared Encrypt + Insert

  /// Encrypts a single ``SpatialEvent`` and inserts the resulting
  /// ``RawMemoryNode`` into the `ModelContext`, applying write coalescing.
  ///
  /// This is the **single source of truth** for the encrypt → insert →
  /// coalesce → save pipeline. Both ``appendInternal(_:)`` and
  /// ``drainRetryQueue()`` delegate to this method.
  ///
  /// The key and its version are resolved in **one** actor hop, so a
  /// concurrent rotation can never pair a new key with an old version label.
  ///
  /// ## Write Coalescing
  ///
  /// The method increments ``pendingInsertCount`` after each insert and
  /// commits via ``commitPendingChanges(context:eventID:)`` when the count
  /// reaches ``saveThreshold``. Save failures are accounted there.
  ///
  /// - Parameter event: The spatial event to encrypt and insert.
  /// - Throws: Errors from key retrieval, JSON encoding or AES-GCM encryption.
  ///   Callers decide the recovery strategy (retry-queue vs permanent-drop).
  func encryptAndInsert(_ event: SpatialEvent) async throws {
    let current = try await keyManager.currentKeyAndVersion()
    let node = try sealNode(for: event, key: current.key, keyVersion: current.version)

    modelContext.insert(node)
    pendingInsertCount += 1

    // Write coalescing: only persist to disk when the pending insert
    // count reaches the configured threshold.
    if pendingInsertCount >= saveThreshold {
      commitPendingChanges(context: "Context save", eventID: event.id)
    }
  }
}

// MARK: - EncryptedMemoryStore + Commit Path

extension EncryptedMemoryStore {

  /// Saves the `ModelContext` — the **only** place pending inserts are committed.
  ///
  /// - On success: every pending insert is counted in ``totalEventsWritten``
  ///   and the ``capacity`` limit is enforced.
  /// - On failure: the context is rolled back and **every** pending insert
  ///   (including coalesced inserts from earlier `append()` calls) is counted
  ///   in ``droppedEventCount`` and reported on ``droppedEventStream``.
  ///
  /// - Parameters:
  ///   - context: Short description of the caller, used in logs and drop reasons.
  ///   - eventID: The triggering event, reported when it is the only pending insert.
  /// - Returns: `true` if the save succeeded (or there was nothing to save).
  @discardableResult
  func commitPendingChanges(context: String, eventID: UUID? = nil) -> Bool {
    guard modelContext.hasChanges || pendingInsertCount > 0 else { return true }

    let pending = pendingInsertCount
    do {
      try modelContext.save()
      _totalEventsWritten += pending
      pendingInsertCount = 0
      if pending > 0 {
        enforceCapacity()
      }
      return true
    } catch {
      modelContext.rollback()
      pendingInsertCount = 0
      if pending > 0 {
        _droppedEventCount += pending
        _dropContinuation.yield(DroppedEvent(
          eventID: pending == 1 ? eventID : nil,
          reason: "\(context) failed (\(pending) events rolled back): \(error.localizedDescription)"
        ))
      }
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: \(context) failed — \(error.localizedDescription). Context rolled back, \(pending) events dropped."
      )
      return false
    }
  }

  /// Evicts the oldest raw nodes (by timestamp) until the store is within ``capacity``.
  ///
  /// Called only after a successful commit, so a rollback here can only undo
  /// the evictions themselves — never user writes.
  func enforceCapacity() {
    guard capacity > 0 else { return }
    do {
      let total = try modelContext.fetchCount(FetchDescriptor<RawMemoryNode>())
      let overflow = total - capacity
      guard overflow > 0 else { return }

      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      descriptor.fetchLimit = overflow
      let victims = try modelContext.fetch(descriptor)
      for node in victims {
        modelContext.delete(node)
      }
      try modelContext.save()
      _evictedEventCount += victims.count
      Self.logger.debug(
        "[AuraKit] EncryptedMemoryStore: Evicted \(victims.count) oldest nodes (capacity \(self.capacity))."
      )
    } catch {
      modelContext.rollback()
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Capacity eviction failed — \(error.localizedDescription)."
      )
    }
  }
}

// MARK: - EncryptedMemoryStore + Core Append Logic

extension EncryptedMemoryStore {

  // MARK: - Core Append Logic

  /// Core append logic that delegates to ``encryptAndInsert(_:)``.
  ///
  /// On failure, the event is either queued for retry (if capacity allows)
  /// or permanently dropped with telemetry notification.
  func appendInternal(_ event: SpatialEvent) async {
    let signpostID = SignpostLogger.beginEncrypt()
    defer { SignpostLogger.endEncrypt(signpostID) }

    do {
      try await encryptAndInsert(event)
    } catch {
      enqueueForRetry(event, reason: error.localizedDescription)
    }
  }
}

// MARK: - EncryptedMemoryStore + Retry Queue Management

extension EncryptedMemoryStore {

  /// Attempts to re-persist all events currently in the retry queue.
  ///
  /// Each event is processed independently — a single event's failure does not
  /// prevent others from being retried. Events that fail again are permanently
  /// dropped (no recursive retry to prevent infinite loops).
  ///
  /// Called automatically at the start of each `append()`. Can also be called
  /// explicitly for manual retry control.
  public func flushRetryQueue() async {
    await drainRetryQueue()
  }

  /// Internal drain implementation. Removes all events from the retry queue
  /// and attempts to persist each one via ``encryptAndInsert(_:)``.
  ///
  /// Events that fail on this second attempt are permanently dropped — no
  /// re-queuing to prevent infinite retry loops.
  func drainRetryQueue() async {
    guard !_retryQueue.isEmpty else { return }

    let eventsToRetry = _retryQueue
    _retryQueue.removeAll(keepingCapacity: true)

    for event in eventsToRetry {
      let signpostID = SignpostLogger.beginEncrypt()
      defer { SignpostLogger.endEncrypt(signpostID) }

      do {
        try await encryptAndInsert(event)
      } catch {
        // Permanent drop on second failure — no recursive retry.
        _droppedEventCount += 1
        _dropContinuation.yield(DroppedEvent(
          eventID: event.id,
          reason: "Retry failed (permanent drop): \(error.localizedDescription)"
        ))
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Retry failed for event \(event.id) — permanently dropped."
        )
      }
    }
  }

  /// Enqueues an event for retry, or permanently drops it if the queue is at capacity.
  func enqueueForRetry(_ event: SpatialEvent, reason: String) {
    guard retryQueueCapacity > 0 else {
      // Retry disabled — drop immediately (legacy behaviour).
      _droppedEventCount += 1
      _dropContinuation.yield(DroppedEvent(
        eventID: event.id,
        reason: "Encryption failed (retry disabled): \(reason)"
      ))
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Encryption failed for event \(event.id) — \(reason)"
      )
      return
    }

    // Evict oldest queued event if at capacity.
    if _retryQueue.count >= retryQueueCapacity {
      let evicted = _retryQueue.removeFirst()
      _droppedEventCount += 1
      _dropContinuation.yield(DroppedEvent(
        eventID: evicted.id,
        reason: "Evicted from retry queue (capacity \(retryQueueCapacity) reached)"
      ))
      Self.logger.warning(
        "[AuraKit] EncryptedMemoryStore: Retry queue full — evicted oldest event \(evicted.id)."
      )
    }

    _retryQueue.append(event)
    Self.logger.info(
      "[AuraKit] EncryptedMemoryStore: Event \(event.id) queued for retry."
    )
  }
}

// MARK: - EncryptedMemoryStore + Scheduled Retry Drain

extension EncryptedMemoryStore {

  /// Drains the retry queue if it has entries. One iteration of the scheduled loop.
  func drainRetryQueueIfNeeded() async {
    guard !_retryQueue.isEmpty else { return }

    Self.logger.debug(
      "[AuraKit] EncryptedMemoryStore: Scheduled retry drain — \(self._retryQueue.count) events queued."
    )
    await drainRetryQueue()
  }

  /// Starts the scheduled retry drain loop if not already running.
  ///
  /// The loop sleeps for ``retryDrainInterval``, then drains any queued events —
  /// ensuring stale retry events are re-attempted even when no new `append()`
  /// calls arrive.
  ///
  /// ## Lifetime
  ///
  /// The task captures the store **weakly** and only upgrades to a strong
  /// reference for the duration of a single drain. A previous implementation
  /// held `self` strongly across the infinite loop, creating a store ↔ task
  /// retain cycle that kept every store (and its `ModelContext`) alive forever.
  /// The loop exits when the task is cancelled (``cancelScheduledRetryDrain()``
  /// or `deinit`) or when the store has been deallocated.
  internal func startScheduledRetryDrain() {
    guard retryDrainTask == nil, retryDrainInterval > 0, retryQueueCapacity > 0 else { return }
    let intervalNanoseconds = UInt64(retryDrainInterval * 1_000_000_000)

    retryDrainTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: intervalNanoseconds)
        } catch {
          // Task.sleep throws CancellationError when the task is cancelled.
          return
        }
        guard let store = self else { return }
        await store.drainRetryQueueIfNeeded()
      }
    }
  }

  /// Cancels the scheduled retry drain task.
  ///
  /// Call this during store teardown or when reconfiguring the retry interval.
  /// After cancellation, retry events are only drained on the next `append()` call
  /// or explicit ``flushRetryQueue()`` invocation.
  public func cancelScheduledRetryDrain() {
    retryDrainTask?.cancel()
    retryDrainTask = nil
    Self.logger.debug(
      "[AuraKit] EncryptedMemoryStore: Scheduled retry drain cancelled."
    )
  }
}
