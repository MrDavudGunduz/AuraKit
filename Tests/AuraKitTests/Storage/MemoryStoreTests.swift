// MemoryStoreTests.swift
// AuraKitTests — Phase 1: Core Infrastructure Tests
//
// Dedicated tests for MemoryStore: capacity enforcement, FIFO eviction,
// unbounded mode, clear(), and chronological ordering.

import Foundation
import Testing

@testable import AuraKit

// MARK: - MemoryStoreTests

@Suite("MemoryStore")
struct MemoryStoreTests {

  // MARK: - Basic Append & Read

  @Test("append + allEvents returns events in chronological order")
  func testAppendAndAllEvents() async {
    let store = MemoryStore(capacity: 16)
    let events = (0..<5).map { _ in SpatialEvent.touchFixture() }

    for event in events {
      await store.append(event)
    }

    let all = await store.allEvents()
    #expect(all.count == 5)
    for (original, stored) in zip(events, all) {
      #expect(original.id == stored.id)
    }
  }

  @Test("count reflects appended items accurately")
  func testCountAccuracy() async {
    let store = MemoryStore(capacity: 64)
    #expect(await store.count == 0)

    await store.append(.touchFixture())
    await store.append(.touchFixture())
    #expect(await store.count == 2)
  }

  @Test("Empty store returns empty array")
  func testEmptyStoreReturnsEmpty() async {
    let store = MemoryStore(capacity: 8)
    let all = await store.allEvents()
    #expect(all.isEmpty)
    #expect(await store.count == 0)
  }

  // MARK: - Capacity & FIFO Eviction

  @Test("FIFO eviction at capacity: oldest event is evicted")
  func testFIFOEvictionAtCapacity() async {
    let capacity = 4
    let store = MemoryStore(capacity: capacity)

    // Fill to capacity
    let firstBatch = (0..<capacity).map { _ in SpatialEvent.touchFixture() }
    for event in firstBatch {
      await store.append(event)
    }
    #expect(await store.count == capacity)

    // Overflow — oldest (firstBatch[0]) should be evicted
    let overflow = SpatialEvent.touchFixture()
    await store.append(overflow)
    #expect(await store.count == capacity)

    let all = await store.allEvents()
    // firstBatch[0] should be gone; firstBatch[1] is now the oldest
    #expect(all.first?.id == firstBatch[1].id)
    #expect(all.last?.id == overflow.id)
  }

  @Test("Multiple overflows maintain correct FIFO order")
  func testMultipleOverflows() async {
    let capacity = 3
    let store = MemoryStore(capacity: capacity)

    // Fill to capacity
    let initial = (0..<capacity).map { _ in SpatialEvent.touchFixture() }
    for event in initial { await store.append(event) }

    // Add 2 more events — evicts initial[0] and initial[1]
    let extra1 = SpatialEvent.touchFixture()
    let extra2 = SpatialEvent.touchFixture()
    await store.append(extra1)
    await store.append(extra2)

    let all = await store.allEvents()
    #expect(all.count == capacity)
    #expect(all[0].id == initial[2].id)
    #expect(all[1].id == extra1.id)
    #expect(all[2].id == extra2.id)
  }

  @Test("Count never exceeds capacity across 1000 appends")
  func testCountNeverExceedsCapacity() async {
    let capacity = 64
    let store = MemoryStore(capacity: capacity)

    for _ in 0..<1_000 {
      await store.append(.touchFixture())
    }

    #expect(await store.count == capacity)
  }

  // MARK: - Unbounded Mode

  @Test("Unbounded mode (capacity: 0) allows unlimited growth")
  func testUnboundedModeGrows() async {
    let store = MemoryStore(capacity: 0)

    for _ in 0..<500 {
      await store.append(.touchFixture())
    }

    #expect(await store.count == 500)
  }

  @Test("Unbounded mode preserves FIFO order")
  func testUnboundedModeFIFOOrder() async {
    let store = MemoryStore(capacity: 0)
    let events = (0..<10).map { _ in SpatialEvent.touchFixture() }
    for event in events { await store.append(event) }

    let all = await store.allEvents()
    for (original, stored) in zip(events, all) {
      #expect(original.id == stored.id)
    }
  }

  // MARK: - clear()

  @Test("clear() empties the store — count becomes 0")
  func testClearEmptiesStore() async {
    let store = MemoryStore(capacity: 16)
    for _ in 0..<8 { await store.append(.touchFixture()) }
    #expect(await store.count == 8)

    await store.clear()
    #expect(await store.count == 0)
    #expect(await store.allEvents().isEmpty)
  }

  @Test("clear() + re-append works correctly")
  func testClearThenReappend() async {
    let store = MemoryStore(capacity: 4)
    for _ in 0..<4 { await store.append(.touchFixture()) }
    await store.clear()

    let newEvent = SpatialEvent.touchFixture()
    await store.append(newEvent)
    #expect(await store.count == 1)

    let all = await store.allEvents()
    #expect(all.first?.id == newEvent.id)
  }

  @Test("clear() on unbounded store works correctly")
  func testClearUnbounded() async {
    let store = MemoryStore(capacity: 0)
    for _ in 0..<100 { await store.append(.touchFixture()) }
    await store.clear()

    #expect(await store.count == 0)
    #expect(await store.allEvents().isEmpty)
  }

  @Test("Unbounded mode supports pagination via events(limit:offset:)")
  func testUnboundedModePagination() async {
    let store = MemoryStore(capacity: 0)
    let events = (0..<20).map { idx in
      SpatialEvent(
        kind: .interaction(type: .touch, position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: Double(idx) * 0.05
      )
    }
    for event in events { await store.append(event) }

    // Page 1: first 5 events
    let page1 = await store.events(limit: 5, offset: 0)
    #expect(page1.count == 5)
    #expect(page1.first?.id == events[0].id)
    #expect(page1.last?.id == events[4].id)

    // Page 2: next 5 events
    let page2 = await store.events(limit: 5, offset: 5)
    #expect(page2.count == 5)
    #expect(page2.first?.id == events[5].id)

    // Last page: partial
    let lastPage = await store.events(limit: 10, offset: 15)
    #expect(lastPage.count == 5, "Last page should contain remaining 5 events")

    // Out of range: offset beyond count
    let empty = await store.events(limit: 5, offset: 100)
    #expect(empty.isEmpty, "Offset beyond count should return empty")
  }

  @Test("Unbounded mode batchAppend works correctly")
  func testUnboundedModeBatchAppend() async {
    let store = MemoryStore(capacity: 0)
    let events = (0..<100).map { _ in SpatialEvent.touchFixture() }

    await store.batchAppend(events)

    #expect(await store.count == 100)
    let all = await store.allEvents()
    for (original, stored) in zip(events, all) {
      #expect(original.id == stored.id)
    }
  }
}

