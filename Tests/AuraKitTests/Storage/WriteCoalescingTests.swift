// WriteCoalescingTests.swift
// AuraKitTests — Write Coalescing Mechanism
//
// Validates that EncryptedMemoryStore's write coalescing correctly
// batches inserts and defers save() calls until the configured
// threshold is reached or flushPendingWrites() is called explicitly.

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Write Coalescing Tests

@Suite("Storage — Write Coalescing")
struct WriteCoalescingTests {

  // MARK: - Helpers

  /// Creates an EncryptedMemoryStore with a specific save threshold for testing.
  private func makeStore(
    saveThreshold: Int,
    key: SymmetricKey = SymmetricKey(size: .bits256)
  ) throws -> EncryptedMemoryStore {
    let container = try PersistenceController.makeInMemoryContainer()
    return EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: key),
      saveThreshold: saveThreshold
    )
  }

  // MARK: - Threshold Behaviour

  @Test("Events below threshold are not yet persisted to disk")
  func eventsBelowThresholdNotPersisted() async throws {
    let threshold = 5
    let store = try makeStore(saveThreshold: threshold)

    // Append fewer events than the threshold
    for idx in 0..<(threshold - 1) {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.1
      ))
    }

    // Pending inserts exist but haven't been saved yet
    let pendingCount = await store.pendingInsertCount
    #expect(pendingCount == threshold - 1, "Events should be pending, not yet saved")

    // After flush, they should be committed
    await store.flushPendingWrites()

    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == threshold - 1, "All events should be written after flush")

    let pendingAfterFlush = await store.pendingInsertCount
    #expect(pendingAfterFlush == 0, "No pending inserts after flush")
  }

  @Test("Events at threshold trigger automatic save")
  func eventsAtThresholdTriggerSave() async throws {
    let threshold = 3
    let store = try makeStore(saveThreshold: threshold)

    // Append exactly threshold events
    for idx in 0..<threshold {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.1
      ))
    }

    // Threshold reached — should have auto-saved
    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == threshold, "Events should be auto-saved at threshold")

    let pendingCount = await store.pendingInsertCount
    #expect(pendingCount == 0, "No pending inserts after threshold save")
  }

  @Test("Multiple threshold cycles accumulate totalEventsWritten correctly")
  func multipleThresholdCycles() async throws {
    let threshold = 4
    let store = try makeStore(saveThreshold: threshold)

    // Append 2.5x threshold events
    let totalEvents = threshold * 2 + 2
    for idx in 0..<totalEvents {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.01
      ))
    }

    // Two full threshold cycles should have auto-saved (2 * 4 = 8)
    let autoSaved = await store.totalEventsWritten
    #expect(autoSaved == threshold * 2, "Two full threshold cycles should auto-save")

    // Remaining 2 events should be pending
    let pending = await store.pendingInsertCount
    #expect(pending == 2, "Remaining events should be pending")

    // Flush the rest
    await store.flushPendingWrites()
    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == totalEvents, "All events should be written after flush")
  }

  // MARK: - flushPendingWrites

  @Test("flushPendingWrites is a no-op when no pending inserts")
  func flushNoOpWhenNoPending() async throws {
    let store = try makeStore(saveThreshold: 10)

    // No events appended — flush should be a no-op
    await store.flushPendingWrites()

    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 0)
    #expect(await store.droppedEventCount == 0)
  }

  @Test("flushPendingWrites commits all pending inserts")
  func flushCommitsPendingInserts() async throws {
    let store = try makeStore(saveThreshold: 100)  // High threshold — never auto-saves

    // Append 15 events — well below threshold
    for idx in 0..<15 {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.05
      ))
    }

    #expect(await store.pendingInsertCount == 15)
    #expect(await store.totalEventsWritten == 0)

    // Flush
    await store.flushPendingWrites()

    #expect(await store.pendingInsertCount == 0)
    #expect(await store.totalEventsWritten == 15)

    // Verify events are actually readable
    let events = await store.allEvents()
    #expect(events.count == 15)
  }

  // MARK: - batchAppend Bypass

  @Test("batchAppend always saves immediately regardless of threshold")
  func batchAppendBypassesCoalescing() async throws {
    let store = try makeStore(saveThreshold: 100)  // High threshold

    let events = (0..<7).map { idx in
      SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.1
      )
    }

    await store.batchAppend(events)

    // batchAppend should save immediately
    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 7, "batchAppend should save immediately regardless of threshold")

    let count = await store.count
    #expect(count == 7)
  }

  // MARK: - Threshold of 1 (Legacy Mode)

  @Test("saveThreshold of 1 saves on every append (legacy behaviour)")
  func thresholdOneSavesEveryAppend() async throws {
    let store = try makeStore(saveThreshold: 1)

    for idx in 0..<5 {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.1
      ))

      // Each append should save immediately
      let written = await store.totalEventsWritten
      #expect(written == idx + 1, "With threshold 1, each append should trigger save")
    }

    #expect(await store.pendingInsertCount == 0)
  }

  // MARK: - Read After Write Consistency

  @Test("Flushed events are immediately visible to allEvents()")
  func readAfterWriteConsistency() async throws {
    let store = try makeStore(saveThreshold: 10)

    // Append 3 events (below threshold)
    for _ in 0..<3 {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: 0.5
      ))
    }

    // Flush to make them visible
    await store.flushPendingWrites()

    // Events should be immediately readable
    let events = await store.allEvents()
    #expect(events.count == 3, "Flushed events should be immediately visible")
  }

  // MARK: - Metrics Consistency

  @Test("Metrics correctly reflect coalesced writes")
  func metricsReflectCoalescedWrites() async throws {
    let store = try makeStore(saveThreshold: 5)

    // Append 12 events (2 full cycles + 2 pending)
    for idx in 0..<12 {
      await store.append(SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.01
      ))
    }

    let metrics = await store.metrics
    #expect(metrics.totalEventsWritten == 10, "Two full cycles of 5 = 10 written")
    #expect(metrics.droppedEventCount == 0)

    // Flush remaining
    await store.flushPendingWrites()

    let finalMetrics = await store.metrics
    #expect(finalMetrics.totalEventsWritten == 12)
    #expect(finalMetrics.writeSuccessRate == 100.0)
  }
}
