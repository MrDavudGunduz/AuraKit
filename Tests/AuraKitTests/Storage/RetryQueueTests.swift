// RetryQueueTests.swift
// AuraKitTests — Retry Queue Mechanism
//
// Validates that EncryptedMemoryStore's retry queue correctly
// re-attempts failed events and handles queue capacity limits.

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Retry Queue Tests

@Suite("Storage — Retry Queue")
struct RetryQueueTests {

  // MARK: - Helpers

  /// Creates an EncryptedMemoryStore with a specific retry queue capacity.
  private func makeStore(
    retryQueueCapacity: Int,
    saveThreshold: Int = 1,
    key: SymmetricKey = SymmetricKey(size: .bits256)
  ) throws -> EncryptedMemoryStore {
    let container = try PersistenceController.makeInMemoryContainer()
    return EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: key),
      saveThreshold: saveThreshold,
      retryQueueCapacity: retryQueueCapacity
    )
  }

  // MARK: - Default Behaviour

  @Test("Retry queue is empty when all appends succeed")
  func retryQueueEmptyOnSuccess() async throws {
    let store = try makeStore(retryQueueCapacity: 10)

    await store.append(.touchFixture())
    await store.append(.gazeFixture())

    let queueCount = await store.retryQueueCount
    #expect(queueCount == 0, "Retry queue should be empty when all appends succeed")

    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 2)
  }

  @Test("Retry queue capacity of 0 disables retry (legacy behaviour)")
  func retryDisabledWithZeroCapacity() async throws {
    let store = try makeStore(retryQueueCapacity: 0)

    // Append with a valid key — should succeed
    await store.append(.touchFixture())

    let dropped = await store.droppedEventCount
    #expect(dropped == 0, "Valid events should not be dropped")

    let queueCount = await store.retryQueueCount
    #expect(queueCount == 0, "Queue should always be empty when retry is disabled")
  }

  // MARK: - Retry Queue Metrics

  @Test("retryQueueCount reflects current queue size")
  func retryQueueCountAccurate() async throws {
    let store = try makeStore(retryQueueCapacity: 5)

    // Successful appends should not affect queue count
    for _ in 0..<3 {
      await store.append(.touchFixture())
    }

    let queueCount = await store.retryQueueCount
    #expect(queueCount == 0, "Queue should be empty after successful appends")
  }

  @Test("flushRetryQueue is a no-op when queue is empty")
  func flushRetryQueueNoOpWhenEmpty() async throws {
    let store = try makeStore(retryQueueCapacity: 10)

    // Queue is empty — flush should be harmless
    await store.flushRetryQueue()

    let dropped = await store.droppedEventCount
    #expect(dropped == 0)

    let written = await store.totalEventsWritten
    #expect(written == 0)
  }

  // MARK: - Metrics Snapshot

  @Test("StoreMetrics includes retry-aware totals after successful writes")
  func metricsAfterSuccessfulWrites() async throws {
    let store = try makeStore(retryQueueCapacity: 5)

    for _ in 0..<10 {
      await store.append(.touchFixture())
    }

    let metrics = await store.metrics
    #expect(metrics.totalEventsWritten == 10)
    #expect(metrics.droppedEventCount == 0)
    #expect(metrics.writeSuccessRate == 100.0)
  }

  // MARK: - Integration with Flush

  @Test("flushPendingWrites works correctly with retry queue enabled")
  func flushPendingWritesWithRetryQueue() async throws {
    let store = try makeStore(retryQueueCapacity: 5, saveThreshold: 100)

    // Append 5 events (below threshold — pending writes)
    for _ in 0..<5 {
      await store.append(.touchFixture())
    }

    let pendingBefore = await store.pendingInsertCount
    #expect(pendingBefore == 5, "Events should be pending before flush")

    // Flush pending writes
    await store.flushPendingWrites()

    let pendingAfter = await store.pendingInsertCount
    #expect(pendingAfter == 0, "No pending inserts after flush")

    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 5, "All events should be written after flush")

    // Events should be readable
    let events = await store.allEvents()
    #expect(events.count == 5)
  }

  // MARK: - Configuration Validation

  @Test("AuraConfiguration validates retryQueueCapacity >= 0")
  func configurationValidation() throws {
    // Valid: retryQueueCapacity = 0 (retry disabled)
    let config0 = try AuraConfiguration(retryQueueCapacity: 0)
    #expect(config0.retryQueueCapacity == 0)

    // Valid: retryQueueCapacity > 0
    let config10 = try AuraConfiguration(retryQueueCapacity: 10)
    #expect(config10.retryQueueCapacity == 10)

    // Invalid: retryQueueCapacity < 0
    #expect(throws: AuraError.self) {
      _ = try AuraConfiguration(retryQueueCapacity: -1)
    }
  }

  @Test("Default configuration includes retryQueueCapacity")
  func defaultConfigurationHasRetryCapacity() {
    let config = AuraConfiguration.default
    #expect(
      config.retryQueueCapacity == AuraConfiguration.defaultRetryQueueCapacity,
      "Default config should include retry queue capacity"
    )
  }
}
