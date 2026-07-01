// TransientImprovementTests.swift
// AuraKitTests — @Transient and Lifecycle Improvements
//
// Validates that the @Transient attribute on MemoryArchiveNode prevents
// unnecessary persistence of cache fields, and that the shutdown flush
// integration correctly preserves coalesced writes.

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - @Transient Cache Tests

@Suite("Persistence — @Transient Cache Validation")
struct TransientCacheTests {

  // MARK: - MemoryArchiveNode Cache Behaviour

  @Test("decodedSourceNodeIDs returns correct IDs after creation")
  func decodedSourceNodeIDsAfterCreation() throws {
    let sourceIDs = [UUID(), UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("test-summary".utf8),
      sourceNodeIDs: sourceIDs
    )

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded == sourceIDs, "Decoded source IDs should match the originals")
  }

  @Test("Cache is populated on first access and reused on subsequent access")
  func cacheLazyPopulation() throws {
    let sourceIDs = [UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("test".utf8),
      sourceNodeIDs: sourceIDs
    )

    // First access — populates cache
    let first = node.decodedSourceNodeIDs
    // Second access — should return cached value
    let second = node.decodedSourceNodeIDs

    #expect(first == second, "Cached and fresh results should be identical")
    #expect(first == sourceIDs)
  }

  @Test("updateSourceNodeIDs invalidates and replaces cache")
  func updateInvalidatesCache() throws {
    let originalIDs = [UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("test".utf8),
      sourceNodeIDs: originalIDs
    )

    // Populate cache
    _ = node.decodedSourceNodeIDs

    // Update with new IDs
    let newIDs = [UUID(), UUID(), UUID(), UUID()]
    node.updateSourceNodeIDs(newIDs)

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded == newIDs, "Cache should reflect updated IDs")
    #expect(decoded != originalIDs, "Cache should not return stale data")
  }

  @Test("MemoryArchiveNode persists and restores without cache field")
  func persistenceWithoutCacheField() throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let context = ModelContext(container)

    let sourceIDs = [UUID(), UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("encrypted-test".utf8),
      sourceNodeIDs: sourceIDs
    )

    // Force cache population
    _ = node.decodedSourceNodeIDs

    // Persist
    context.insert(node)
    try context.save()

    // Fetch from store (new object instance — cache should be nil)
    let descriptor = FetchDescriptor<MemoryArchiveNode>()
    let fetched = try context.fetch(descriptor)

    #expect(fetched.count == 1)

    let fetchedNode = try #require(fetched.first)

    // The @Transient cache should NOT be persisted — it starts as nil
    // on the fetched instance and is lazily repopulated from sourceNodeIDsData.
    let decodedFromFetch = fetchedNode.decodedSourceNodeIDs
    #expect(decodedFromFetch == sourceIDs, "Fetched node should decode IDs from persisted data")
  }

  @Test("Empty source node IDs handled gracefully")
  func emptySourceNodeIDs() throws {
    let node = MemoryArchiveNode(
      encryptedSummary: Data("test".utf8),
      sourceNodeIDs: []
    )

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.isEmpty, "Empty source IDs should decode to empty array")
  }
}

// MARK: - Shutdown Flush Integration Tests

@Suite("Lifecycle — Shutdown Flush Integration")
struct ShutdownFlushIntegrationTests {

  @Test("flushToStore drains buffer AND flushes pending writes")
  func flushToStoreDrainsBothSources() async throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let key = SymmetricKey(size: .bits256)
    let store = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: key),
      saveThreshold: 100  // High threshold — never auto-saves
    )

    let config = try AuraConfiguration(bufferCapacity: 64)
    let capture = CaptureActor(config: config, store: store)

    // Record individual interaction events (routed to store via directStore)
    for _ in 0..<3 {
      await capture.record(
        event: SpatialEvent(kind: .interaction(type: .touch, position: .zero))
      )
    }

    // Record gaze events (routed to buffer via enqueueBuffer)
    for _ in 0..<5 {
      await capture.record(
        event: SpatialEvent(kind: .gaze(position: .zero))
      )
    }

    // Verify: interaction events are in store but pending (not saved)
    let pendingBefore = await store.pendingInsertCount
    #expect(pendingBefore == 3, "3 interaction events should be pending")

    // Verify: gaze events are in buffer
    let buffered = await capture.bufferedEventCount
    #expect(buffered == 5, "5 gaze events should be buffered")

    // Flush everything — this should drain buffer AND flush pending writes
    let flushedCount = await capture.flushToStore()
    #expect(flushedCount == 5, "5 buffered gaze events should be flushed")

    // After flush: all events should be persisted
    let pendingAfter = await store.pendingInsertCount
    #expect(pendingAfter == 0, "No pending inserts after flushToStore")

    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 8, "All 8 events (3 interaction + 5 gaze) should be written")

    // Verify all events are readable
    let allEvents = await store.allEvents()
    #expect(allEvents.count == 8, "All 8 events should be readable after flush")
  }

  @Test("flushToStore with empty buffer still flushes pending writes")
  func flushToStoreEmptyBufferFlushesWrites() async throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let key = SymmetricKey(size: .bits256)
    let store = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: key),
      saveThreshold: 100
    )

    let config = try AuraConfiguration(bufferCapacity: 64)
    let capture = CaptureActor(config: config, store: store)

    // Record only interaction events (no gaze — buffer stays empty)
    for _ in 0..<4 {
      await capture.record(
        event: SpatialEvent(kind: .interaction(type: .touch, position: .zero))
      )
    }

    // Buffer should be empty — only store has pending writes
    let buffered = await capture.bufferedEventCount
    #expect(buffered == 0, "No gaze events — buffer should be empty")

    let pendingBefore = await store.pendingInsertCount
    #expect(pendingBefore == 4, "4 interaction events should be pending")

    // flushToStore should still flush pending writes even with empty buffer
    let flushedCount = await capture.flushToStore()
    #expect(flushedCount == 0, "No buffer events flushed")

    let pendingAfter = await store.pendingInsertCount
    #expect(pendingAfter == 0, "Pending writes should be flushed")

    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 4, "All 4 events should be written")
  }

  @Test("flushToStore() preserves all in-flight events (interaction + gaze)")
  func flushToStorePreservesAllEvents() async throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let key = SymmetricKey(size: .bits256)
    let store = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: key),
      saveThreshold: 100
    )

    let config = try AuraConfiguration(bufferCapacity: 64)
    let capture = CaptureActor(config: config, store: store)

    // Record mixed events
    await capture.record(
      event: SpatialEvent(kind: .interaction(type: .touch, position: .zero))
    )
    await capture.record(
      event: SpatialEvent(kind: .gaze(position: .zero))
    )

    // flushToStore — should drain buffer AND flush pending writes
    let flushed = await capture.flushToStore()

    // Verify gaze event was flushed from buffer
    #expect(flushed == 1, "1 buffered gaze event should be flushed")

    // Verify all events are persisted
    let totalWritten = await store.totalEventsWritten
    #expect(totalWritten == 2, "Both events should be persisted after flush")
  }
}
