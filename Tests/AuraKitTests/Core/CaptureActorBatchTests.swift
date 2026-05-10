// CaptureActorBatchTests.swift
// AuraKitTests — CaptureActor Batch Record Integration
//
// Validates the CaptureActor.recordBatch() pipeline end-to-end:
// - Interaction events route to persistent store via batchAppend
// - Gaze events route to L1 RingBuffer
// - Mixed event routing invariant
// - HeuristicRouter score overwrite behaviour
// - Empty batch no-op

import CryptoKit
import Foundation
import Testing

@testable import AuraKit

// MARK: - CaptureActor Batch Integration

@Suite("CaptureActor — Batch Record")
struct CaptureActorBatchTests {

  @Test("recordBatch routes interaction events to store via batchAppend")
  func recordBatchInteractionEvents() async throws {
    let store = try makeTestEncryptedStore()
    let config = try AuraConfiguration(bufferCapacity: 64, storeCapacity: 100)
    let capture = CaptureActor(config: config, store: store)

    let events = (0..<10).map { _ in
      SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: 0)
    }

    await capture.recordBatch(events: events)

    let persisted = await capture.persistedEvents()
    #expect(persisted.count == 10)
  }

  @Test("recordBatch overwrites event scores via HeuristicRouter")
  func recordBatchScoreOverwrite() async throws {
    let config = try AuraConfiguration(
      interactionWeight: 0.8,
      gazeWeight: 0.4,
      bufferCapacity: 64
    )
    let capture = CaptureActor(config: config)

    let events: [SpatialEvent] = [
      SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: 0),
      SpatialEvent(kind: .gaze(position: .zero), score: 0),
    ]

    await capture.recordBatch(events: events)

    // Interaction event should have interactionWeight score
    let persisted = await capture.persistedEvents()
    #expect(persisted.count == 1)
    #expect(persisted.first?.score == 0.8, "Router must overwrite score with interactionWeight")

    // Gaze event should have gazeWeight score
    let flushed = await capture.flush()
    #expect(flushed.count == 1)
    #expect(flushed.first?.score == 0.4, "Router must overwrite score with gazeWeight")
  }

  @Test("recordBatch routes gaze events to buffer")
  func recordBatchGazeEvents() async throws {
    let config = try AuraConfiguration(bufferCapacity: 64)
    let capture = CaptureActor(config: config)

    let events = (0..<5).map { _ in
      SpatialEvent(kind: .gaze(position: .zero), score: 0)
    }

    await capture.recordBatch(events: events)

    let buffered = await capture.bufferedEventCount
    #expect(buffered == 5)
  }

  @Test("recordBatch with mixed events routes correctly")
  func recordBatchMixedRouting() async throws {
    let config = try AuraConfiguration(bufferCapacity: 64)
    let capture = CaptureActor(config: config)

    let events: [SpatialEvent] = [
      SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: 0),
      SpatialEvent(kind: .gaze(position: .zero), score: 0),
      SpatialEvent(kind: .interaction(type: .move, position: .zero), score: 0),
      SpatialEvent(kind: .gaze(position: .zero), score: 0),
      SpatialEvent(kind: .interaction(type: .pinch, position: .zero), score: 0),
    ]

    await capture.recordBatch(events: events)

    let persisted = await capture.persistedEventCount
    let buffered = await capture.bufferedEventCount
    #expect(persisted == 3, "3 interaction events should be in the store")
    #expect(buffered == 2, "2 gaze events should be in the buffer")
  }

  @Test("recordBatch with empty array is a no-op")
  func recordBatchEmpty() async throws {
    let config = try AuraConfiguration(bufferCapacity: 64)
    let capture = CaptureActor(config: config)

    await capture.recordBatch(events: [])

    #expect(await capture.persistedEventCount == 0)
    #expect(await capture.bufferedEventCount == 0)
  }
}
