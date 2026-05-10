// MemoryStoreBatchTests.swift
// AuraKitTests — MemoryStore Batch Insert Verification
//
// Validates the in-memory store's batch append behaviour:
// - Default protocol implementation (sequential fallback)
// - FIFO capacity enforcement under batch load

import Foundation
import Testing

@testable import AuraKit

// MARK: - MemoryStore Batch Tests

@Suite("MemoryStore — Batch Append")
struct MemoryStoreBatchTests {

  @Test("batchAppend uses default sequential implementation")
  func batchAppendDefault() async {
    let store = MemoryStore(capacity: 64)
    let events = (0..<5).map { _ in SpatialEvent.touchFixture() }

    await store.batchAppend(events)

    #expect(await store.count == 5)
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
}
