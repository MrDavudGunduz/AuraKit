// ShutdownTests.swift
// AuraKitTests — Pipeline Shutdown Integration
//
// Validates that CaptureActor.flushToStore() correctly flushes buffered
// events before pipeline teardown. These tests ensure zero data loss
// during application lifecycle transitions.
//
// Note: Tests use CaptureActor directly (not AuraKit.shared) to avoid
// inter-suite race conditions when multiple test suites access the
// singleton in parallel. AuraKit.shutdown() delegates to flushToStore(),
// so testing the underlying mechanism validates the same contract.

import Foundation
import Testing

@testable import AuraKit

// MARK: - Shutdown Tests

@Suite("Integration — Shutdown Flush", .serialized)
struct ShutdownTests {

  // MARK: - Basic Flush

  @Test("flushToStore() flushes buffered gaze events to store")
  func flushToStoreFlushesBufferedEvents() async throws {
    let store = MemoryStore(capacity: 10_000)
    let config = try AuraConfiguration(bufferCapacity: 512, storeCapacity: 10_000)
    let capture = CaptureActor(config: config, store: store)

    // Record gaze events — these go to the RingBuffer, not the store
    let gazeCount = 20
    for idx in 0..<gazeCount {
      let event = SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0))
      )
      await capture.record(event: event)
    }

    // Before flush, gaze events are in the buffer, not the store
    let preFlushStoreCount = await store.count
    let preFlushBufferCount = await capture.bufferedEventCount
    #expect(preFlushBufferCount == gazeCount, "Gaze events should be in the buffer before flush")

    // flushToStore should flush buffer contents to store
    let flushedCount = await capture.flushToStore()

    #expect(flushedCount == gazeCount, "flushToStore() should report all buffered events were flushed")

    // After flush, events should be in the store
    let postFlushStoreCount = await store.count
    #expect(
      postFlushStoreCount == preFlushStoreCount + gazeCount,
      "All buffered events should be in the store after flush"
    )
  }

  // MARK: - Flush Without Events

  @Test("flushToStore() returns 0 when no events are buffered")
  func flushToStoreWithNoBufferedEvents() async throws {
    let config = try AuraConfiguration()
    let capture = CaptureActor(config: config)

    let flushedCount = await capture.flushToStore()
    #expect(flushedCount == 0, "No events buffered — flushed count should be 0")
  }

  // MARK: - Double Flush Safety

  @Test("Double flushToStore() is safe — second call returns 0")
  func doubleFlushToStoreIsSafe() async throws {
    let store = MemoryStore(capacity: 10_000)
    let config = try AuraConfiguration(bufferCapacity: 256)
    let capture = CaptureActor(config: config, store: store)

    // Record some gaze events
    for idx in 0..<5 {
      await capture.record(event: SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0))
      ))
    }

    let firstFlush = await capture.flushToStore()
    #expect(firstFlush == 5, "First flush should flush all buffered events")

    // Second flush should return 0 — buffer is empty
    let secondFlush = await capture.flushToStore()
    #expect(secondFlush == 0, "Second flush should return 0 — buffer already drained")
  }

  // MARK: - Mixed Event Flush

  @Test("flushToStore() flushes only gaze events — interactions are already persisted")
  func flushToStoreFlushesOnlyGazeEvents() async throws {
    let store = MemoryStore(capacity: 10_000)
    let config = try AuraConfiguration(bufferCapacity: 512, storeCapacity: 10_000)
    let capture = CaptureActor(config: config, store: store)

    // Record interaction events (go directly to store)
    let interactionCount = 10
    for idx in 0..<interactionCount {
      await capture.record(event: SpatialEvent(
        kind: .interaction(type: .touch, position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: 1.0
      ))
    }

    // Record gaze events (go to buffer)
    let gazeCount = 8
    for idx in 0..<gazeCount {
      await capture.record(event: SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 1, z: 0))
      ))
    }

    let preFlushCount = await store.count
    #expect(preFlushCount == interactionCount, "Only interactions should be in store before flush")

    let flushedCount = await capture.flushToStore()
    #expect(flushedCount == gazeCount, "Only gaze events should be flushed")

    let postFlushCount = await store.count
    #expect(
      postFlushCount == interactionCount + gazeCount,
      "Store should contain interactions + flushed gaze events"
    )
  }


  // MARK: - Reconfiguration After Shutdown

  @Test("configure(with:) succeeds after shutdown()")
  @MainActor
  func reconfigureAfterShutdown() async throws {
    let instance = AuraKit.shared
    instance.reset()

    // First configuration
    let config1 = try AuraConfiguration(bufferCapacity: 64)
    try instance.configure(with: config1)
    _ = await instance.shutdown()

    // Re-configuration should succeed
    let config2 = try AuraConfiguration(bufferCapacity: 128)
    try instance.configure(with: config2)
    #expect(instance.isConfigured)

    let capture = try instance.capture()
    #expect(type(of: capture) == CaptureActor.self)

    instance.reset()
  }
}
