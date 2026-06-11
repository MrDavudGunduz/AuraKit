// StressTests.swift
// AuraKitTests — High-Volume Event Processing
//
// Validates AuraKit's data pipeline under sustained high-frequency loads.
// These tests verify that the capture engine, memory store, and encrypted
// persistence layer maintain correctness and stability across 10K+ events.

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - MemoryStore Stress Tests

@Suite("Stress Tests — MemoryStore High-Volume")
struct MemoryStoreStressTests {

  @Test("MemoryStore handles 10K event burst in bounded mode")
  func memoryStore10KBurstBounded() async throws {
    let capacity = 5_000
    let store = MemoryStore(capacity: capacity)
    let eventCount = 10_000

    for idx in 0..<eventCount {
      let event = SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.0001
      )
      await store.append(event)
    }

    // Bounded mode should retain only the most recent `capacity` events
    let count = await store.count
    #expect(count == capacity, "Bounded store should cap at capacity")

    let events = await store.allEvents()
    #expect(events.count == capacity)

    // Verify the retained events are the most recent ones (FIFO eviction)
    let lastEvent = events.last
    #expect(lastEvent != nil)
    #expect(lastEvent?.score == Double(eventCount - 1) * 0.0001)
  }

  @Test("MemoryStore pagination consistency across 10K events")
  func paginationConsistencyUnder10K() async throws {
    let capacity = 10_000
    let store = MemoryStore(capacity: capacity)

    for idx in 0..<capacity {
      let event = SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.0001
      )
      await store.append(event)
    }

    // Verify paginated reads cover the full dataset without gaps
    let pageSize = 500
    var allPaginated: [SpatialEvent] = []

    for offset in stride(from: 0, to: capacity, by: pageSize) {
      let page = await store.events(limit: pageSize, offset: offset)
      allPaginated.append(contentsOf: page)
    }

    #expect(allPaginated.count == capacity)

    // Verify chronological order across pages
    let allDirect = await store.allEvents()
    for idx in 0..<capacity {
      #expect(allPaginated[idx].id == allDirect[idx].id)
    }
  }

  @Test("MemoryStore maintains O(1) append under sustained load")
  func appendPerformanceUnderLoad() async throws {
    let store = MemoryStore(capacity: 15_000)

    let start = ContinuousClock.now

    for _ in 0..<10_000 {
      let event = SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: 1.0
      )
      await store.append(event)
    }

    let elapsed = ContinuousClock.now - start

    // 10K events should complete well under 1 second even on CI
    #expect(elapsed < .seconds(1), "10K appends should complete under 1 second")

    let count = await store.count
    #expect(count == 10_000)
  }
}

// MARK: - RingBuffer Stress Tests

@Suite("Stress Tests — RingBuffer High-Volume")
struct RingBufferStressTests {

  @Test("RingBuffer survives 50K enqueue/dequeue cycles without memory growth")
  func ringBuffer50KCycles() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 512)

    for _ in 0..<50_000 {
      let event = SpatialEvent(kind: .gaze(position: .zero), score: 0.3)
      buffer.enqueue(event)
    }

    // Buffer should be full at capacity, not 50K
    let count = buffer.count
    #expect(count == 512)

    // Drain and verify all elements are valid
    let drained = buffer.drainAll()
    #expect(drained.count == 512)
    #expect(buffer.isEmpty)
  }

  @Test("RingBuffer drainAll after overflow returns correct count")
  func drainAfterOverflowCorrectness() {
    let capacity = 128
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    // Overflow the buffer 3x
    let totalEvents = capacity * 3
    for idx in 0..<totalEvents {
      let event = SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: 0.3
      )
      buffer.enqueue(event)
    }

    let drained = buffer.drainAll()
    #expect(drained.count == capacity)

    // Verify oldest surviving event is from the last `capacity` writes
    let expectedFirstX = Float(totalEvents - capacity)
    #expect(drained.first != nil)
    if case .gaze(let position) = drained.first?.kind {
      #expect(position.x == expectedFirstX)
    }
  }
}

// MARK: - EncryptedMemoryStore Stress Tests

@Suite("Stress Tests — EncryptedMemoryStore Batch")
struct EncryptedMemoryStoreStressTests {

  @Test("batchAppend 1K events succeeds with single save")
  func batchAppend1K() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<1_000).map { idx in
      SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.001
      )
    }

    await store.batchAppend(events)

    let count = await store.count
    #expect(count == 1_000)
    #expect(await store.droppedEventCount == 0)
  }

  @Test("Round-trip integrity after 500 encrypted events")
  func roundTripIntegrity500() async throws {
    let store = try makeTestEncryptedStore()
    var originalIDs: [UUID] = []

    let events = (0..<500).map { idx -> SpatialEvent in
      let event = SpatialEvent(
        kind: .interaction(type: .touch, position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: Double(idx) * 0.002
      )
      originalIDs.append(event.id)
      return event
    }

    await store.batchAppend(events)

    // Verify all events are retrievable and correctly decrypted
    let retrieved = await store.allEvents()
    #expect(retrieved.count == 500)

    let retrievedIDs = Set(retrieved.map(\.id))
    for id in originalIDs {
      #expect(retrievedIDs.contains(id), "Event \(id) should survive encrypt/decrypt round-trip")
    }
  }
}
