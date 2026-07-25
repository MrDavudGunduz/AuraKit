// EncryptedMemoryStoreTests.swift
// AuraKitTests — Phase 2: Encrypted Persistence

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Core Operations

@Suite("EncryptedMemoryStore — Core Operations", .serialized)
struct EncryptedMemoryStoreCoreTests {

  @Test("append() persists an event and count increments")
  func appendIncrementsCount() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.touchFixture())
    let count = await store.count
    #expect(count == 1)
  }

  @Test("allEvents() returns the appended event with correct properties")
  func allEventsReturnsAppendedEvent() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.gazeFixture(score: 0.5)
    await store.append(event)
    let events = await store.allEvents()
    #expect(events.count == 1)
    #expect(events.first?.id == event.id)
    #expect(events.first?.score == event.score)
  }

  @Test("Multiple events are returned in chronological order")
  func eventsInChronologicalOrder() async throws {
    let store = try makeTestEncryptedStore()
    let e1 = SpatialEvent(timestamp: Date(timeIntervalSince1970: 100), kind: .gaze(position: .zero), score: 0.3)
    let e2 = SpatialEvent(timestamp: Date(timeIntervalSince1970: 200), kind: .interaction(type: .touch, position: .zero), score: 1.0)
    let e3 = SpatialEvent(timestamp: Date(timeIntervalSince1970: 300), kind: .interaction(type: .move, position: .zero), score: 1.0)
    await store.append(e2)
    await store.append(e1)
    await store.append(e3)
    let events = await store.allEvents()
    #expect(events.count == 3)
    #expect(events[0].id == e1.id)
    #expect(events[2].id == e3.id)
  }

  @Test("count returns accurate count after multiple appends")
  func countAccuracy() async throws {
    let store = try makeTestEncryptedStore()
    for idx in 0..<5 {
      await store.append(SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: Double(idx) * 0.2))
    }
    let count = await store.count
    #expect(count == 5)
  }

  @Test("allEvents() is a pure read — does not increment recalled counter")
  func allEventsDoesNotIncrementRecall() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    await store.append(event)

    // Two reads via allEvents() — recall should stay at 0
    _ = await store.allEvents()
    _ = await store.allEvents()

    let recalled = await store.recalledCount(for: event.id)
    #expect(recalled == 0, "allEvents() must not increment recalled counter")
  }
}

// MARK: - Ciphertext Verification

@Suite("EncryptedMemoryStore — Ciphertext Verification", .serialized)
struct EncryptedMemoryStoreCiphertextTests {

  @Test("Stored payload is ciphertext, not plaintext")
  func storedPayloadIsCiphertext() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    let plainJSON = try JSONEncoder().encode(event)
    await store.append(event)
    let ciphertext = await store.rawCiphertext(for: event.id)
    #expect(ciphertext != nil)
    #expect(ciphertext != plainJSON)
    if let ct = ciphertext {
      #expect(ct.count == 12 + plainJSON.count + 16)
    }
  }
}

// MARK: - Extended API & Integration

@Suite("EncryptedMemoryStore — Extended API", .serialized)
struct EncryptedMemoryStoreExtendedTests {

  @Test("fetchNodeCount(eventType:) filters by event type")
  func fetchNodeCountByEventType() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.gazeFixture())
    await store.append(SpatialEvent.touchFixture())
    await store.append(SpatialEvent.moveFixture())
    await store.append(SpatialEvent.gazeFixture())
    let gazeCount = await store.fetchNodeCount(eventType: .gaze)
    let touchCount = await store.fetchNodeCount(eventType: .touch)
    #expect(gazeCount == 2)
    #expect(touchCount == 1)
  }

  @Test("deleteNodes(belowScore:) removes low-score nodes")
  func deleteNodesBelowScore() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.gazeFixture(score: 0.3))
    await store.append(SpatialEvent.gazeFixture(score: 0.3))
    await store.append(SpatialEvent.touchFixture(score: 1.0))
    let deleted = await store.deleteNodes(belowScore: 0.5)
    #expect(deleted == 2)
    let remaining = await store.count
    #expect(remaining == 1)
  }

  @Test("deleteNodes(belowScore:) on empty store returns zero")
  func deleteNodesEmptyStore() async throws {
    let store = try makeTestEncryptedStore()
    let deleted = await store.deleteNodes(belowScore: 0.5)
    #expect(deleted == 0)
  }

  @Test("clear() removes all nodes")
  func clearRemovesAllNodes() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.touchFixture())
    await store.append(SpatialEvent.gazeFixture())
    await store.clear()
    let count = await store.count
    #expect(count == 0)
  }

  @Test("CaptureActor integration via protocol injection")
  func captureActorIntegration() async throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let store = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: sharedTestKey)
    )
    let config = try AuraConfiguration(bufferCapacity: 64, storeCapacity: 100)
    let capture = CaptureActor(config: config, store: store)
    let event = SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: 0)
    await capture.record(event: event)
    let persisted = await capture.persistedEvents()
    #expect(persisted.count == 1)
    #expect(persisted.first?.id == event.id)
  }
}
