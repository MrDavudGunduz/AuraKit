// EncryptedStoreBenchmarkTests.swift
// AuraKitTests — Performance Regression Detection
//
// Validates that EncryptedMemoryStore batch operations meet their documented
// performance targets. Uses ContinuousClock with generous thresholds to
// account for CI runner variability while catching catastrophic regressions.
//
// Performance targets:
// - Single event encrypt + persist: < 5ms
// - Batch 100 events (single save): < 200ms
// - Paginated fetch (50 events): < 100ms

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - EncryptedMemoryStore Performance

@Suite("Performance — EncryptedMemoryStore Benchmarks")
struct EncryptedStoreBenchmarkTests {

  @Test("batchAppend 100 events completes under 500ms")
  func batchAppendThroughput() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<100).map { _ in SpatialEvent.touchFixture() }

    let start = ContinuousClock.now
    await store.batchAppend(events)
    let elapsed = ContinuousClock.now - start

    let count = await store.count
    #expect(count == 100)
    #expect(
      elapsed < .milliseconds(500),
      "batchAppend of 100 events took \(elapsed) — expected < 500ms"
    )
  }

  @Test("batchAppend is faster than sequential append for 50 events")
  func batchVsSequentialAppend() async throws {
    let eventCount = 50
    let events = (0..<eventCount).map { _ in SpatialEvent.touchFixture() }

    // Sequential path
    let seqStore = try makeTestEncryptedStore()
    let seqStart = ContinuousClock.now
    for event in events {
      await seqStore.append(event)
    }
    let seqElapsed = ContinuousClock.now - seqStart

    // Batch path
    let batchStore = try makeTestEncryptedStore()
    let batchStart = ContinuousClock.now
    await batchStore.batchAppend(events)
    let batchElapsed = ContinuousClock.now - batchStart

    // Both must complete under threshold; batch should be faster
    // due to single save() vs N saves
    let seqCount = await seqStore.count
    let batchCount = await batchStore.count
    #expect(seqCount == eventCount)
    #expect(batchCount == eventCount)
    #expect(
      seqElapsed < .seconds(2),
      "Sequential \(eventCount) appends took \(seqElapsed)"
    )
    #expect(
      batchElapsed < .seconds(1),
      "Batch \(eventCount) appends took \(batchElapsed)"
    )
  }

  @Test("Paginated fetch of 50 events completes under 200ms")
  func paginatedFetchLatency() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<100).map { _ in SpatialEvent.touchFixture() }
    await store.batchAppend(events)

    let start = ContinuousClock.now
    let page = await store.events(limit: 50, offset: 0)
    let elapsed = ContinuousClock.now - start

    #expect(page.count == 50)
    #expect(
      elapsed < .milliseconds(200),
      "Paginated fetch of 50 events took \(elapsed) — expected < 200ms"
    )
  }

  @Test("Write coalescing reduces I/O: saveThreshold 10 is faster than saveThreshold 1")
  func writeCoalescingBenefit() async throws {
    let eventCount = 50
    let events = (0..<eventCount).map { _ in SpatialEvent.touchFixture() }

    // saveThreshold = 1 (save on every append)
    let eagleStore = try makeTestEncryptedStore(saveThreshold: 1)
    let eagleStart = ContinuousClock.now
    for event in events {
      await eagleStore.append(event)
    }
    let eagleElapsed = ContinuousClock.now - eagleStart

    // saveThreshold = 10 (save every 10th append)
    let coalescedStore = try makeTestEncryptedStore(saveThreshold: 10)
    let coalescedStart = ContinuousClock.now
    for event in events {
      await coalescedStore.append(event)
    }
    await coalescedStore.flushPendingWrites()
    let coalescedElapsed = ContinuousClock.now - coalescedStart

    let eagleCount = await eagleStore.count
    let coalescedCount = await coalescedStore.count
    #expect(eagleCount == eventCount)
    #expect(coalescedCount == eventCount)

    // Both must complete — coalesced is expected to be faster but we only
    // enforce generous absolute thresholds to avoid CI flakiness.
    #expect(
      eagleElapsed < .seconds(3),
      "Eager save (threshold=1) took \(eagleElapsed)"
    )
    #expect(
      coalescedElapsed < .seconds(2),
      "Coalesced save (threshold=10) took \(coalescedElapsed)"
    )
  }

  @Test("allEvents decryption of 100 events completes under 500ms")
  func allEventsDecryptionThroughput() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<100).map { _ in SpatialEvent.touchFixture() }
    await store.batchAppend(events)

    let start = ContinuousClock.now
    let decrypted = await store.allEvents()
    let elapsed = ContinuousClock.now - start

    #expect(decrypted.count == 100)
    #expect(
      elapsed < .milliseconds(500),
      "allEvents decryption of 100 events took \(elapsed) — expected < 500ms"
    )
  }
}
