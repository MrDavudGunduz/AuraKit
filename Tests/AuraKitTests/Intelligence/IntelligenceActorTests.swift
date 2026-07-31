// IntelligenceActorTests.swift
// AuraKitTests — Phase 3 IntelligenceActor Integration Tests

import Foundation
import Testing
@testable import AuraKit

@Suite("IntelligenceActor — On-Device LLM & Semantic Pruning")
struct IntelligenceActorTests {

  @Test("512-event batch inference completes under 200ms benchmark")
  func batchInferenceLatencyBenchmark() async throws {
    let config = try AuraConfiguration(bufferCapacity: 512)
    let store = MemoryStore(capacity: 1000)
    let mockProvider = MockMLXModelProvider(latencyMs: 5)
    let intelligenceActor = IntelligenceActor(config: config, store: store, modelProvider: mockProvider)

    var events: [SpatialEvent] = []
    events.reserveCapacity(512)
    for _ in 0..<512 {
      events.append(.gazeFixture(score: 0.8))
    }

    let startTime = ContinuousClock.now
    let evaluated = try await intelligenceActor.evaluateBatch(events)
    let duration = startTime.duration(to: ContinuousClock.now)

    #expect(evaluated.count == 512)
    #expect(duration < .milliseconds(200))
  }

  @Test("processAndPrune deletes events below SI threshold from MemoryStore")
  func semanticPruningMemoryStore() async throws {
    let config = try AuraConfiguration(
      decayConstant: 0.01,
      survivalIndexThreshold: 0.2
    )
    let store = MemoryStore(capacity: 100)

    // Old low-score event (will decay below 0.2 threshold)
    let oldEvent = SpatialEvent(
      id: UUID(),
      timestamp: Date().addingTimeInterval(-1000),
      kind: .gaze(position: .zero),
      score: 0.3
    )

    // Fresh high-score event
    let freshEvent = SpatialEvent.touchFixture(score: 1.0)

    await store.append(oldEvent)
    await store.append(freshEvent)
    #expect(await store.count == 2)

    let mockProvider = MockMLXModelProvider(latencyMs: 1)
    let intelligenceActor = IntelligenceActor(config: config, store: store, modelProvider: mockProvider)

    let (evaluated, prunedCount) = try await intelligenceActor.processAndPrune([oldEvent, freshEvent])

    #expect(evaluated.count == 2)
    #expect(prunedCount == 1)
    #expect(await store.count == 1)
  }

  @Test("processAndPrune operates cleanly with EncryptedMemoryStore")
  func semanticPruningEncryptedStore() async throws {
    let config = try AuraConfiguration(
      decayConstant: 0.05,
      survivalIndexThreshold: 0.3
    )
    let store = try makeTestEncryptedStore(saveThreshold: 1)

    let oldEvent = SpatialEvent(
      id: UUID(),
      timestamp: Date().addingTimeInterval(-500),
      kind: .gaze(position: .zero),
      score: 0.4
    )

    await store.append(oldEvent)
    #expect(await store.count == 1)

    let mockProvider = MockMLXModelProvider(latencyMs: 1)
    let intelligenceActor = IntelligenceActor(config: config, store: store, modelProvider: mockProvider)

    let (_, prunedCount) = try await intelligenceActor.processAndPrune([oldEvent])

    #expect(prunedCount == 1)
    #expect(await store.count == 0)
  }
}
