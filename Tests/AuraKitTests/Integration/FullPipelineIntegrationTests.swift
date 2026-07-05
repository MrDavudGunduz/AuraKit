// FullPipelineIntegrationTests.swift
// AuraKitTests — Integration: Full Pipeline
//
// End-to-end integration tests validating the complete data flow:
// CaptureActor → HeuristicRouter → EncryptedMemoryStore → Decrypt round-trip.
//
// These tests exercise the full pipeline rather than individual components,
// catching integration failures that unit tests cannot detect (e.g., actor
// boundary issues, write coalescing timing, shutdown data loss).

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

@Suite("Full Pipeline Integration Tests")
struct FullPipelineIntegrationTests {

  // MARK: - Helpers

  /// Creates a CaptureActor backed by an EncryptedMemoryStore for integration testing.
  private func makePipeline(
    saveThreshold: Int = 1
  ) throws -> (capture: CaptureActor, store: EncryptedMemoryStore) {
    let store = try makeTestEncryptedStore(saveThreshold: saveThreshold)
    let config = try AuraConfiguration()
    let capture = CaptureActor(config: config, store: store)
    return (capture, store)
  }

  // MARK: - Touch Event → Direct Store → Decrypt Round-Trip

  @Test("Touch event flows through pipeline and is retrievable after decryption")
  func touchEventRoundTrip() async throws {
    let (capture, store) = try makePipeline()

    let event = SpatialEvent.touchFixture(score: 0.95)
    await capture.record(event: event)

    let events = await store.events(limit: 10)
    #expect(events.count == 1)
    #expect(events.first?.id == event.id)
    #expect(events.first?.kind.eventType == .touch)
  }

  // MARK: - Gaze Event → RingBuffer → FlushToStore → Decrypt Round-Trip

  @Test("Gaze event is buffered, then flushed to encrypted store and retrievable")
  func gazeEventBufferFlushRoundTrip() async throws {
    let (capture, store) = try makePipeline()

    let event = SpatialEvent.gazeFixture(score: 0.2)
    await capture.record(event: event)

    // Gaze goes to RingBuffer, not directly to store
    let storeCount = await store.count
    #expect(storeCount == 0)
    #expect(await capture.bufferedEventCount == 1)

    // Flush buffer → store
    let flushedCount = await capture.flushToStore()
    #expect(flushedCount == 1)

    // Now the event should be in the encrypted store
    let events = await store.events(limit: 10)
    #expect(events.count == 1)
    #expect(events.first?.id == event.id)
    #expect(events.first?.kind.eventType == .gaze)
  }

  // MARK: - Mixed Event Routing

  @Test("Mixed events are correctly routed: interactions to store, gaze to buffer")
  func mixedEventRouting() async throws {
    let (capture, store) = try makePipeline()

    let touchEvent = SpatialEvent.touchFixture()
    let gazeEvent = SpatialEvent.gazeFixture()
    let pinchEvent = SpatialEvent.pinchFixture()

    await capture.record(event: touchEvent)
    await capture.record(event: gazeEvent)
    await capture.record(event: pinchEvent)

    // Touch and pinch → store, gaze → buffer
    let storeCount = await store.count
    #expect(storeCount == 2)
    #expect(await capture.bufferedEventCount == 1)
  }

  // MARK: - Batch Record

  @Test("Batch record routes events correctly and persists in a single operation")
  func batchRecordRouting() async throws {
    let (capture, store) = try makePipeline()

    let events: [SpatialEvent] = [
      .touchFixture(score: 1.0),
      .gazeFixture(score: 0.3),
      .pinchFixture(score: 0.9),
      .gazeFixture(score: 0.2),
      .dragFixture(score: 0.8),
    ]

    await capture.recordBatch(events: events)

    // 3 interactions → store, 2 gaze → buffer
    let storeCount = await store.count
    #expect(storeCount == 3)
    #expect(await capture.bufferedEventCount == 2)
  }

  // MARK: - Shutdown Data Loss Prevention

  @Test("flushToStore ensures zero data loss during shutdown")
  func shutdownFlushPreventsDataLoss() async throws {
    let (capture, store) = try makePipeline()

    // Record a mix of events
    await capture.record(event: .touchFixture())
    await capture.record(event: .gazeFixture())
    await capture.record(event: .gazeFixture())
    await capture.record(event: .pinchFixture())

    // Before shutdown: 2 in store, 2 in buffer
    #expect(await store.count == 2)
    #expect(await capture.bufferedEventCount == 2)

    // Shutdown flush: buffer → store
    let flushedCount = await capture.flushToStore()
    #expect(flushedCount == 2)

    // After shutdown: all 4 in store, buffer empty
    let totalCount = await store.count
    #expect(totalCount == 4)
    #expect(await capture.bufferedEventCount == 0)
  }

  // MARK: - Write Coalescing + Flush Interaction

  @Test("Write coalescing defers saves, flushPendingWrites commits all")
  func writeCoalescingAndFlush() async throws {
    // saveThreshold = 3: saves only after every 3rd insert
    let (capture, store) = try makePipeline(saveThreshold: 3)

    // Insert 2 events (below threshold — not yet persisted to disk)
    await capture.record(event: .touchFixture())
    await capture.record(event: .pinchFixture())

    // Flush to ensure pending writes are committed
    await store.flushPendingWrites()

    let events = await store.events(limit: 10)
    #expect(events.count == 2)
  }

  // MARK: - Event Identity Preservation

  @Test("Event UUIDs are preserved through encrypt-decrypt round-trip")
  func eventIdentityPreservation() async throws {
    let (capture, store) = try makePipeline()

    let originalEvents: [SpatialEvent] = [
      .touchFixture(),
      .pinchFixture(),
      .dragFixture(),
    ]

    let originalIDs = Set(originalEvents.map(\.id))

    for event in originalEvents {
      await capture.record(event: event)
    }

    let decryptedEvents = await store.events(limit: 10)
    let decryptedIDs = Set(decryptedEvents.map(\.id))

    #expect(decryptedIDs == originalIDs)
  }

  // MARK: - Encrypted Payload Verification

  @Test("Stored payload is encrypted — raw ciphertext differs from plaintext")
  func payloadIsEncrypted() async throws {
    let (capture, store) = try makePipeline()

    let event = SpatialEvent.touchFixture()
    await capture.record(event: event)

    // Get the raw ciphertext from the database
    let ciphertext = await store.rawCiphertext(for: event.id)
    #expect(ciphertext != nil)

    // Verify ciphertext is not the same as the JSON plaintext
    let plaintext = try JSONEncoder().encode(event)
    #expect(ciphertext != plaintext)
  }

  // MARK: - Store Metrics After Pipeline Activity

  @Test("Store metrics accurately reflect pipeline activity")
  func metricsAccuracy() async throws {
    let (capture, store) = try makePipeline()

    // Record 5 interaction events
    for _ in 0..<5 {
      await capture.record(event: .touchFixture())
    }

    let metrics = await store.metrics
    #expect(metrics.totalEventsWritten == 5)
    #expect(metrics.droppedEventCount == 0)
    #expect(metrics.decryptionFailureCount == 0)
    #expect(metrics.writeSuccessRate == 100.0)
  }
}
