// MemoryStoreBatchTests.swift
// AuraKitTests — MemoryStore Batch Insert Verification
//
// Validates the in-memory store's dedicated batch append implementation:
// - Single-pass batch append (no sequential actor hops)
// - FIFO capacity enforcement under batch load
// - Parity with sequential append path
// - Empty batch handling
// - Unbounded mode batch append

import Foundation
import Testing

@testable import AuraKit

// MARK: - MemoryStore Batch Tests

@Suite("MemoryStore — Batch Append")
struct MemoryStoreBatchTests {

  @Test("batchAppend persists all events and count matches")
  func batchAppendCountAccuracy() async {
    let store = MemoryStore(capacity: 64)
    let events = (0..<10).map { _ in SpatialEvent.touchFixture() }

    await store.batchAppend(events)

    #expect(await store.count == 10)
    let all = await store.allEvents()
    for (original, stored) in zip(events, all) {
      #expect(original.id == stored.id)
    }
  }

  @Test("batchAppend respects capacity — excess events evict oldest")
  func batchAppendCapacity() async {
    let store = MemoryStore(capacity: 3)
    let events = (0..<5).map { _ in SpatialEvent.touchFixture() }

    await store.batchAppend(events)

    #expect(await store.count == 3)
    let all = await store.allEvents()
    // Only the last 3 events should remain
    #expect(all[0].id == events[2].id)
    #expect(all[1].id == events[3].id)
    #expect(all[2].id == events[4].id)
  }

  @Test("batchAppend with empty array is a no-op")
  func batchAppendEmpty() async {
    let store = MemoryStore(capacity: 64)
    await store.batchAppend([])
    #expect(await store.count == 0)
  }

  @Test("batchAppend produces identical results to sequential append")
  func batchAppendParityWithSequentialAppend() async {
    let batchStore = MemoryStore(capacity: 100)
    let seqStore = MemoryStore(capacity: 100)

    let events = (0..<20).map { _ in SpatialEvent.touchFixture() }

    // Batch path
    await batchStore.batchAppend(events)

    // Sequential path
    for event in events {
      await seqStore.append(event)
    }

    let batchResults = await batchStore.allEvents()
    let seqResults = await seqStore.allEvents()

    #expect(batchResults.count == seqResults.count)
    for (batch, seq) in zip(batchResults, seqResults) {
      #expect(batch.id == seq.id)
    }
  }

  @Test("batchAppend in unbounded mode appends all events")
  func batchAppendUnboundedMode() async {
    let store = MemoryStore(capacity: 0)
    let events = (0..<50).map { _ in SpatialEvent.gazeFixture() }

    await store.batchAppend(events)

    #expect(await store.count == 50)
    let all = await store.allEvents()
    for (original, stored) in zip(events, all) {
      #expect(original.id == stored.id)
    }
  }

  @Test("batchAppend preserves event order in bounded mode with overflow")
  func batchAppendOrderWithOverflow() async {
    let store = MemoryStore(capacity: 5)

    // Pre-fill with 3 events
    let initial = (0..<3).map { _ in SpatialEvent.touchFixture() }
    for event in initial { await store.append(event) }

    // Batch append 4 more — triggers overflow (total 7, capacity 5)
    let batch = (0..<4).map { _ in SpatialEvent.moveFixture() }
    await store.batchAppend(batch)

    #expect(await store.count == 5)
    let all = await store.allEvents()

    // The oldest 2 initial events should be evicted
    // Remaining: initial[2], batch[0..3]
    #expect(all[0].id == initial[2].id)
    #expect(all[1].id == batch[0].id)
    #expect(all[2].id == batch[1].id)
    #expect(all[3].id == batch[2].id)
    #expect(all[4].id == batch[3].id)
  }
}
