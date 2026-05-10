// PaginatedStoreTests.swift
// AuraKitTests — Paginated API Tests for MemoryStore
//
// Validates the events(limit:offset:) implementation on MemoryStore,
// ensuring protocol conformance parity with EncryptedMemoryStore's
// paginated API.

import Foundation
import Testing

@testable import AuraKit

// MARK: - MemoryStore Pagination

@Suite("MemoryStore — Paginated Query API")
struct MemoryStorePaginationTests {

  @Test("events(limit:) returns only the requested count")
  func limitCount() async {
    let store = MemoryStore(capacity: 64)
    let events = (0..<10).map { _ in SpatialEvent.touchFixture() }
    for event in events { await store.append(event) }

    let page = await store.events(limit: 3)
    #expect(page.count == 3)
  }

  @Test("events(limit:offset:) skips correct events")
  func offsetSkip() async {
    let store = MemoryStore(capacity: 64)
    let events = (0..<10).map { _ in SpatialEvent.touchFixture() }
    for event in events { await store.append(event) }

    let page = await store.events(limit: 3, offset: 5)
    #expect(page.count == 3)
    #expect(page[0].id == events[5].id)
    #expect(page[1].id == events[6].id)
    #expect(page[2].id == events[7].id)
  }

  @Test("Limit larger than store returns all events")
  func limitExceeds() async {
    let store = MemoryStore(capacity: 64)
    await store.append(.touchFixture())
    await store.append(.gazeFixture())

    let page = await store.events(limit: 100)
    #expect(page.count == 2)
  }

  @Test("Offset beyond store returns empty array")
  func offsetBeyond() async {
    let store = MemoryStore(capacity: 64)
    await store.append(.touchFixture())

    let page = await store.events(limit: 10, offset: 100)
    #expect(page.isEmpty)
  }

  @Test("Offset at exactly count returns empty array")
  func offsetAtCount() async {
    let store = MemoryStore(capacity: 64)
    for _ in 0..<5 { await store.append(.touchFixture()) }

    let page = await store.events(limit: 10, offset: 5)
    #expect(page.isEmpty)
  }

  @Test("Paginated query on empty store returns empty array")
  func paginatedEmptyStore() async {
    let store = MemoryStore(capacity: 64)
    let page = await store.events(limit: 10)
    #expect(page.isEmpty)
  }

  @Test("Full pagination walk returns all events in correct order")
  func fullPaginationWalk() async {
    let store = MemoryStore(capacity: 64)
    let events = (0..<7).map { _ in SpatialEvent.touchFixture() }
    for event in events { await store.append(event) }

    var collected: [SpatialEvent] = []
    let pageSize = 3
    var offset = 0

    while true {
      let page = await store.events(limit: pageSize, offset: offset)
      if page.isEmpty { break }
      collected.append(contentsOf: page)
      offset += pageSize
    }

    #expect(collected.count == 7)
    for (original, paged) in zip(events, collected) {
      #expect(original.id == paged.id)
    }
  }

  @Test("Paginated query after FIFO eviction returns correct events")
  func paginatedAfterEviction() async {
    let store = MemoryStore(capacity: 4)

    // Fill to capacity and overflow
    let events = (0..<6).map { _ in SpatialEvent.touchFixture() }
    for event in events { await store.append(event) }

    // Only last 4 events should remain
    let page = await store.events(limit: 2, offset: 1)
    #expect(page.count == 2)
    #expect(page[0].id == events[3].id)
    #expect(page[1].id == events[4].id)
  }
}
