// ShutdownTests.swift
// AuraKitTests — Pipeline Shutdown Integration
//
// Validates that AuraKit.shutdown() correctly flushes buffered events
// before tearing down the pipeline. These tests ensure zero data loss
// during application lifecycle transitions.

import Foundation
import Testing

@testable import AuraKit

// MARK: - Shutdown Tests

@Suite("Integration — Shutdown Flush", .serialized)
@MainActor
struct ShutdownTests {

  // MARK: - Basic Shutdown

  @Test("shutdown() flushes buffered gaze events to store")
  func shutdownFlushesBufferedEvents() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration(bufferCapacity: 512, storeCapacity: 10_000)
    let store = MemoryStore(capacity: 10_000)
    try instance.configure(with: config, store: store)

    let capture = try instance.capture()

    // Record gaze events — these go to the RingBuffer, not the store
    let gazeCount = 20
    for idx in 0..<gazeCount {
      let event = SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0))
      )
      await capture.record(event: event)
    }

    // Before shutdown, gaze events are in the buffer, not the store
    let preShutdownStoreCount = await store.count
    let preShutdownBufferCount = await capture.bufferedEventCount
    #expect(preShutdownBufferCount == gazeCount, "Gaze events should be in the buffer before shutdown")

    // Shutdown should flush buffer contents to store
    let flushedCount = await instance.shutdown()

    #expect(flushedCount == gazeCount, "shutdown() should report all buffered events were flushed")

    // After shutdown, events should be in the store
    let postShutdownStoreCount = await store.count
    #expect(
      postShutdownStoreCount == preShutdownStoreCount + gazeCount,
      "All buffered events should be in the store after shutdown"
    )

    // Pipeline should be torn down
    #expect(!instance.isConfigured, "Pipeline should be torn down after shutdown")
  }

  // MARK: - Shutdown Without Events

  @Test("shutdown() returns 0 when no events are buffered")
  func shutdownWithNoBufferedEvents() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration()
    try instance.configure(with: config)

    let flushedCount = await instance.shutdown()
    #expect(flushedCount == 0, "No events buffered — flushed count should be 0")
    #expect(!instance.isConfigured)
  }

  // MARK: - Shutdown Without Configuration

  @Test("shutdown() is a no-op when pipeline is not configured")
  func shutdownWithoutConfiguration() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let flushedCount = await instance.shutdown()
    #expect(flushedCount == 0, "shutdown() on unconfigured pipeline should return 0")
    #expect(!instance.isConfigured)
  }

  // MARK: - Double Shutdown Safety

  @Test("Double shutdown() is safe — second call returns 0")
  func doubleShutdownIsSafe() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration(bufferCapacity: 256)
    let store = MemoryStore(capacity: 10_000)
    try instance.configure(with: config, store: store)

    let capture = try instance.capture()

    // Record some gaze events
    for idx in 0..<5 {
      await capture.record(event: SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0))
      ))
    }

    let firstFlush = await instance.shutdown()
    #expect(firstFlush == 5, "First shutdown should flush all buffered events")

    // Second shutdown should be a no-op
    let secondFlush = await instance.shutdown()
    #expect(secondFlush == 0, "Second shutdown should return 0 — pipeline already torn down")
  }

  // MARK: - Mixed Event Shutdown

  @Test("shutdown() flushes only gaze events — interactions are already persisted")
  func shutdownFlushesOnlyGazeEvents() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration(bufferCapacity: 512, storeCapacity: 10_000)
    let store = MemoryStore(capacity: 10_000)
    try instance.configure(with: config, store: store)

    let capture = try instance.capture()

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

    let preShutdownCount = await store.count
    #expect(preShutdownCount == interactionCount, "Only interactions should be in store before shutdown")

    let flushedCount = await instance.shutdown()
    #expect(flushedCount == gazeCount, "Only gaze events should be flushed")

    let postShutdownCount = await store.count
    #expect(
      postShutdownCount == interactionCount + gazeCount,
      "Store should contain interactions + flushed gaze events"
    )
  }

  // MARK: - Reconfiguration After Shutdown

  @Test("configure(with:) succeeds after shutdown()")
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
