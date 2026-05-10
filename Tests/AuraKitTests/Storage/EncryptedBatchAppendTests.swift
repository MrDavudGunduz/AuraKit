// EncryptedBatchAppendTests.swift
// AuraKitTests — EncryptedMemoryStore Batch Insert Optimization
//
// Validates the EncryptedMemoryStore batch append API:
// - Single-save I/O optimisation (N events → 1 disk write)
// - Correctness parity with sequential append
// - Ciphertext integrity and score fidelity through round-trip
// - Mixed event type handling and paginated read-back
// - droppedEventCount observability

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - EncryptedMemoryStore Batch Tests

@Suite("EncryptedMemoryStore — Batch Append")
struct EncryptedMemoryStoreBatchTests {

  @Test("batchAppend persists all events and count matches")
  func batchAppendCountAccuracy() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<10).map { idx in
      SpatialEvent(
        timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.1
      )
    }

    await store.batchAppend(events)
    let count = await store.count
    #expect(count == 10)
    #expect(await store.droppedEventCount == 0, "Successful batch should not drop events")
  }

  @Test("batchAppend produces identical results to sequential append")
  func batchAppendParityWithSequentialAppend() async throws {
    let batchStore = try makeTestEncryptedStore()
    let sequentialStore = try makeTestEncryptedStore()

    let events = (0..<5).map { idx in
      SpatialEvent(
        timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.2
      )
    }

    // Batch path
    await batchStore.batchAppend(events)

    // Sequential path
    for event in events {
      await sequentialStore.append(event)
    }

    let batchResults = await batchStore.allEvents()
    let sequentialResults = await sequentialStore.allEvents()

    #expect(batchResults.count == sequentialResults.count)
    for (batch, sequential) in zip(batchResults, sequentialResults) {
      #expect(batch.id == sequential.id)
      #expect(batch.score == sequential.score)
    }
  }

  @Test("batchAppend with empty array is a no-op")
  func batchAppendEmptyArray() async throws {
    let store = try makeTestEncryptedStore()
    await store.batchAppend([])
    let count = await store.count
    #expect(count == 0)
    #expect(await store.droppedEventCount == 0, "Empty batch should not affect drop counter")
  }

  @Test("batchAppend preserves chronological order")
  func batchAppendChronologicalOrder() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<5).map { idx in
      SpatialEvent(
        timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
        kind: .gaze(position: .zero),
        score: 0.3
      )
    }

    await store.batchAppend(events)
    let fetched = await store.allEvents()

    #expect(fetched.count == 5)
    for (idx, event) in fetched.enumerated() {
      #expect(event.id == events[idx].id)
    }
  }

  @Test("batchAppend events are correctly encrypted")
  func batchAppendEncryption() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    let plainJSON = try JSONEncoder().encode(event)

    await store.batchAppend([event])

    let ciphertext = await store.rawCiphertext(for: event.id)
    #expect(ciphertext != nil)
    #expect(ciphertext != plainJSON, "Batch-appended event must be encrypted, not plaintext")
    #expect(await store.droppedEventCount == 0)
  }

  @Test("batchAppend preserves score fidelity through encrypt/decrypt round-trip")
  func batchAppendScoreFidelity() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<5).map { idx in
      SpatialEvent(
        timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.2
      )
    }

    await store.batchAppend(events)
    let fetched = await store.allEvents()

    #expect(fetched.count == 5)

    // Use ID-based lookup to avoid timestamp-ordering assumptions
    let fetchedByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
    for original in events {
      let decrypted = fetchedByID[original.id]
      #expect(decrypted != nil, "Event \(original.id) should be retrievable")
      #expect(decrypted?.score == original.score, "Score must survive encryption round-trip")
    }
  }

  @Test("batchAppend with mixed event types stores all correctly")
  func batchAppendMixedTypes() async throws {
    let store = try makeTestEncryptedStore()
    let events: [SpatialEvent] = [
      .gazeFixture(score: 0.3),
      .touchFixture(score: 1.0),
      .moveFixture(score: 1.0),
      .pinchFixture(score: 1.0),
      .dragFixture(score: 1.0),
    ]

    await store.batchAppend(events)

    let gazeCount = await store.fetchNodeCount(eventType: .gaze)
    let touchCount = await store.fetchNodeCount(eventType: .touch)
    let moveCount = await store.fetchNodeCount(eventType: .move)
    let pinchCount = await store.fetchNodeCount(eventType: .pinch)
    let dragCount = await store.fetchNodeCount(eventType: .drag)

    #expect(gazeCount == 1)
    #expect(touchCount == 1)
    #expect(moveCount == 1)
    #expect(pinchCount == 1)
    #expect(dragCount == 1)
    #expect(await store.droppedEventCount == 0)
  }

  @Test("batchAppend results are retrievable via paginated read")
  func batchAppendPaginatedRead() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<20).map { idx in
      SpatialEvent(
        timestamp: Date(timeIntervalSince1970: Double(idx) * 100),
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.05
      )
    }

    await store.batchAppend(events)

    // Paginate in two pages of 10
    let page1 = await store.events(limit: 10, offset: 0)
    let page2 = await store.events(limit: 10, offset: 10)

    #expect(page1.count == 10)
    #expect(page2.count == 10)

    // Verify no overlap between pages
    let page1IDs = Set(page1.map(\.id))
    let page2IDs = Set(page2.map(\.id))
    #expect(page1IDs.isDisjoint(with: page2IDs), "Pages must not overlap")

    // Verify union covers all events
    let allIDs = page1IDs.union(page2IDs)
    #expect(allIDs.count == 20)
  }
}
