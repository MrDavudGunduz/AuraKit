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
  /// ``drainRetryQueue()`` delegate to this method, eliminating the
  /// ~40-line duplication that previously existed between them.
  ///
  /// ## Write Coalescing
  ///
  /// The method increments ``pendingInsertCount`` after each insert and
  /// triggers a `ModelContext.save()` when the count reaches ``saveThreshold``.
  /// If the save fails, the context is rolled back and all pending inserts
  /// are counted as dropped events.
  ///
  /// - Parameter event: The spatial event to encrypt and insert.
  /// - Throws: Any error from key retrieval, JSON encoding, AES-GCM encryption,
  ///   or `ModelContext.save()`. Callers decide the recovery strategy
  ///   (retry-queue vs permanent-drop) based on their context.
  func encryptAndInsert(_ event: SpatialEvent) async throws {
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
    pendingInsertCount += 1

    // Write coalescing: only persist to disk when the pending insert
    // count reaches the configured threshold.
    if pendingInsertCount >= saveThreshold {
      do {
        try modelContext.save()
        _totalEventsWritten += pendingInsertCount
        pendingInsertCount = 0
      } catch {
        modelContext.rollback()
        _droppedEventCount += pendingInsertCount
        pendingInsertCount = 0
        _dropContinuation.yield(DroppedEvent(
          eventID: event.id,
          reason: "Context save failed: \(error.localizedDescription)"
        ))
        Self.logger.error(
          "[AuraKit] EncryptedMemoryStore: Failed to save context — \(error.localizedDescription). Context rolled back."
        )
      }
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

