// Phase2HardeningTests.swift
// AuraKitTests — Phase 2: Pagination, Recall Tracking & Hardening
//
// Tests for the Phase 2 production hardening deliverables:
// - Paginated query API (events(limit:offset:))
// - Explicit recall API (recallAndFetchAll / recallAndFetch)
// - Pure read semantics (allEvents / events do NOT increment recall)

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Pagination

@Suite("Paginated Query API")
struct PaginationTests {

  @Test("events(limit:) returns only the requested count")
  func limitCount() async throws {
    let store = try makeTestEncryptedStore()
    for idx in 0..<10 {
      await store.append(
        SpatialEvent(
          timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
          kind: .interaction(type: .touch, position: .zero),
          score: Double(idx) * 0.1
        )
      )
    }
    let page = await store.events(limit: 3)
    #expect(page.count == 3)
  }

  @Test("events(limit:offset:) skips correct events")
  func offsetSkip() async throws {
    let store = try makeTestEncryptedStore()
    var allIDs: [UUID] = []
    for idx in 0..<5 {
      let event = SpatialEvent(
        timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.2
      )
      allIDs.append(event.id)
      await store.append(event)
    }
    _ = await store.events(limit: 2, offset: 0)
    let page2 = await store.events(limit: 2, offset: 2)
    #expect(page2.count == 2)
    #expect(page2[0].id == allIDs[2])
    #expect(page2[1].id == allIDs[3])
  }

  @Test("Limit larger than store returns all events")
  func limitExceeds() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.touchFixture())
    await store.append(SpatialEvent.gazeFixture())
    let page = await store.events(limit: 100)
    #expect(page.count == 2)
  }

  @Test("Offset beyond store returns empty array")
  func offsetBeyond() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.touchFixture())
    let page = await store.events(limit: 10, offset: 100)
    #expect(page.isEmpty)
  }

  @Test("events(limit:offset:) is a pure read — does not increment recalled")
  func paginatedReadDoesNotRecall() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    await store.append(event)

    _ = await store.events(limit: 10)
    _ = await store.events(limit: 10)

    let recalled = await store.recalledCount(for: event.id)
    #expect(recalled == 0, "Paginated read must not increment recalled counter")
  }
}

// MARK: - Recalled Tracking (Explicit Recall API)

@Suite("Survival Index Recall")
struct RecallTests {

  @Test("recallAndFetchAll() increments recalled counter per call")
  func recallIncrement() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    await store.append(event)

    // Two explicit recalls → recalled should be 2
    _ = await store.recallAndFetchAll()
    _ = await store.recallAndFetchAll()

    let recalled = await store.recalledCount(for: event.id)
    #expect(recalled == 2)
  }

  @Test("recallAndFetch(limit:offset:) increments recalled")
  func paginatedRecall() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.gazeFixture()
    await store.append(event)

    _ = await store.recallAndFetch(limit: 10)

    let recalled = await store.recalledCount(for: event.id)
    #expect(recalled == 1)
  }

  @Test("Mixing read and recall — only recall increments counter")
  func mixedReadAndRecall() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    await store.append(event)

    // Pure reads — should NOT increment
    _ = await store.allEvents()
    _ = await store.events(limit: 10)

    // Explicit recall — should increment by 1
    _ = await store.recallAndFetchAll()

    let recalled = await store.recalledCount(for: event.id)
    #expect(recalled == 1, "Only recallAndFetchAll should increment the counter")
  }
}
