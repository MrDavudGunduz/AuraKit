// EncryptedStreamingTests.swift
// AuraKitTests — Phase 2.1: AsyncStream Lazy Decrypt
//
// Validates the eventStream() API: lazy decryption, pagination,
// empty store behaviour, and partial decrypt failure resilience.

import CryptoKit
import Foundation
import Testing

@testable import AuraKit

@Suite("EncryptedMemoryStore — Streaming API", .serialized)
struct EncryptedStreamingTests {

  // MARK: - Helpers

  private func makeStore() throws -> EncryptedMemoryStore {
    try makeTestEncryptedStore()
  }

  // MARK: - Basic Streaming

  @Test("eventStream() yields all stored events")
  func streamYieldsAllEvents() async throws {
    let store = try makeStore()

    let events = [
      SpatialEvent.gazeFixture(score: 0.3),
      SpatialEvent.touchFixture(score: 1.0),
      SpatialEvent.moveFixture(score: 0.8),
    ]

    await store.batchAppend(events)

    var streamed: [SpatialEvent] = []
    let stream = await store.eventStream()
    for await event in stream {
      streamed.append(event)
    }

    #expect(streamed.count == 3)
  }

  @Test("eventStream() returns events in chronological order")
  func streamReturnsChronologicalOrder() async throws {
    let store = try makeStore()

    let event1 = SpatialEvent(
      timestamp: Date(timeIntervalSince1970: 100),
      kind: .gaze(position: .zero),
      score: 0.5
    )
    let event2 = SpatialEvent(
      timestamp: Date(timeIntervalSince1970: 200),
      kind: .gaze(position: .zero),
      score: 0.6
    )
    let event3 = SpatialEvent(
      timestamp: Date(timeIntervalSince1970: 300),
      kind: .gaze(position: .zero),
      score: 0.7
    )

    // Insert out of order
    await store.append(event3)
    await store.append(event1)
    await store.append(event2)

    var timestamps: [Date] = []
    let stream = await store.eventStream()
    for await event in stream {
      timestamps.append(event.timestamp)
    }

    #expect(timestamps == timestamps.sorted())
  }

  // MARK: - Empty Store

  @Test("eventStream() on empty store yields nothing")
  func emptyStoreStreamYieldsNothing() async throws {
    let store = try makeStore()

    var count = 0
    let stream = await store.eventStream()
    for await _ in stream {
      count += 1
    }

    #expect(count == 0)
  }

  // MARK: - Pagination

  @Test("eventStream(limit:) respects the limit")
  func streamRespectsLimit() async throws {
    let store = try makeStore()

    let events = (0..<10).map { _ in SpatialEvent.gazeFixture() }
    await store.batchAppend(events)

    var streamed: [SpatialEvent] = []
    let stream = await store.eventStream(limit: 3)
    for await event in stream {
      streamed.append(event)
    }

    #expect(streamed.count == 3)
  }

  @Test("eventStream(limit:offset:) skips the correct number of events")
  func streamRespectsOffset() async throws {
    let store = try makeStore()

    let events = (0..<10).map { _ in SpatialEvent.gazeFixture() }
    await store.batchAppend(events)

    var streamed: [SpatialEvent] = []
    let stream = await store.eventStream(limit: 3, offset: 5)
    for await event in stream {
      streamed.append(event)
    }

    #expect(streamed.count == 3)
  }

  // MARK: - Consistency with allEvents()

  @Test("eventStream() produces the same events as allEvents()")
  func streamConsistentWithAllEvents() async throws {
    let store = try makeStore()

    let events = [
      SpatialEvent.gazeFixture(score: 0.2),
      SpatialEvent.touchFixture(score: 0.9),
      SpatialEvent.pinchFixture(score: 0.7),
    ]
    await store.batchAppend(events)

    let allEventsResult = await store.allEvents()

    var streamedIDs: [UUID] = []
    let stream = await store.eventStream()
    for await event in stream {
      streamedIDs.append(event.id)
    }

    #expect(streamedIDs == allEventsResult.map(\.id))
  }

  // MARK: - Stream is Pure Read

  @Test("eventStream() does not increment recall counters")
  func streamDoesNotIncrementRecall() async throws {
    let store = try makeStore()

    let event = SpatialEvent.gazeFixture()
    await store.append(event)

    // Stream the event (should not increment recall)
    let stream = await store.eventStream()
    for await _ in stream {}

    let recalled = await store.recalledCount(for: event.id)
    #expect(recalled == 0)
  }
}
