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
}
