// CompressionIntegrityTests.swift
// AuraKitTests — Metadata integrity and bounded, content-aware compression.

import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Test-only tampering hooks

extension EncryptedMemoryStore {

  /// Simulates an attacker editing the plaintext `score` column on disk.
  fileprivate func tamperScore(of id: UUID, to score: Double) throws {
    let descriptor = FetchDescriptor<RawMemoryNode>(predicate: #Predicate { $0.id == id })
    let node = try #require(try modelContext.fetch(descriptor).first)
    node.score = score
    try modelContext.save()
  }

  /// Simulates an attacker editing the plaintext `timestamp` column on disk.
  fileprivate func tamperTimestamp(of id: UUID, to timestamp: Date) throws {
    let descriptor = FetchDescriptor<RawMemoryNode>(predicate: #Predicate { $0.id == id })
    let node = try #require(try modelContext.fetch(descriptor).first)
    node.timestamp = timestamp
    try modelContext.save()
  }
}

/// Records every prompt the model receives.
private actor PromptRecorder {
  private(set) var prompts: [String] = []
  func record(_ prompt: String) { prompts.append(prompt) }
}

@Suite("Intelligence — Compression Integrity", .serialized)
struct CompressionIntegrityTests {

  private func makeConfig(threshold: Double) throws -> AuraConfiguration {
    AuraConfiguration(
      capture: try CaptureConfiguration(interactionWeight: 1.0, gazeWeight: 0.3, bufferCapacity: 512),
      storage: try StorageConfiguration(
        capacity: 1000,
        streamBatchSize: 100,
        largeDatasetWarningThreshold: 1000,
        saveThreshold: 1,
        retryQueueCapacity: 10
      ),
      intelligence: try IntelligenceConfiguration(
        decayConstant: 0.0001,
        recallMultiplier: 1.2,
        survivalIndexThreshold: threshold
      )
    )
  }

  private func trustedProvider(recorder: PromptRecorder? = nil) -> MockMLXModelProvider {
    MockMLXModelProvider(
      latencyMs: 0,
      trustedForDestructiveOperations: true,
      customScoreProvider: { prompt in
        if let recorder {
          Task { await recorder.record(prompt) }
        }
        return "User touched the table near the window."
      }
    )
  }

  // MARK: - Read-path verification

  @Test("Tampered plaintext score is detected on read")
  func tamperedScoreDetectedOnRead() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture(score: 0.9)
    await store.append(event)

    try await store.tamperScore(of: event.id, to: 0.01)

    #expect(await store.allEvents().isEmpty)
    #expect(await store.decryptionFailureCount == 1)
  }

  @Test("Tampered plaintext timestamp is detected on read")
  func tamperedTimestampDetectedOnRead() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture(score: 0.9)
    await store.append(event)

    try await store.tamperTimestamp(of: event.id, to: .distantPast)

    #expect(await store.allEvents().isEmpty)
    #expect(await store.decryptionFailureCount == 1)
  }

  @Test("Untampered records round-trip metadata exactly")
  func untamperedRecordsRoundTrip() async throws {
    let store = try makeTestEncryptedStore()
    let events = (0..<20).map { index in
      SpatialEvent(
        timestamp: Date(timeIntervalSinceNow: -Double(index) * 1.234_567_89),
        kind: .interaction(type: .pinch, rawPosition: SIMD3(Float(index), 0.5, -1))
      ).withScore(Double(index) / 19.0)
    }
    await store.batchAppend(events)

    #expect(await store.allEvents().count == events.count)
    #expect(await store.decryptionFailureCount == 0)
  }

  // MARK: - Compression

  @Test("Compression never deletes a node whose metadata was tampered with")
  func compressionSkipsTamperedNodes() async throws {
    let store = try makeTestEncryptedStore()
    let honest = SpatialEvent.touchFixture(score: 0.2)
    let victim = SpatialEvent.touchFixture(score: 0.95)
    await store.batchAppend([honest, victim])

    // Attacker lowers the victim's score so it is selected for compression.
    try await store.tamperScore(of: victim.id, to: 0.01)

    let intelligence = IntelligenceActor(
      config: try makeConfig(threshold: 0.5),
      store: store,
      modelProvider: trustedProvider()
    )
    let report = try await intelligence.compressIdleMemories()

    #expect(report.nodesPruned == 1)
    #expect(await store.count == 1, "Tampered node must survive compression")
    #expect(await store.recalledCount(for: victim.id) != nil)
    #expect(await store.recalledCount(for: honest.id) == nil)
  }

  @Test("Compression fails without deleting anything when no candidate verifies")
  func compressionAllTamperedFails() async throws {
    let store = try makeTestEncryptedStore()
    let victim = SpatialEvent.touchFixture(score: 0.95)
    await store.append(victim)
    try await store.tamperScore(of: victim.id, to: 0.01)

    let intelligence = IntelligenceActor(
      config: try makeConfig(threshold: 0.5),
      store: store,
      modelProvider: trustedProvider()
    )

    await #expect(throws: AuraError.self) {
      try await intelligence.compressIdleMemories()
    }
    #expect(await store.count == 1)
    #expect(await store.archiveNodeCount == 0)
  }

  @Test("Compression prompt includes decrypted positions")
  func compressionPromptIncludesPositions() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent(
      kind: .interaction(type: .touch, rawPosition: SIMD3(1.5, -2.25, 3.75))
    ).withScore(0.1)
    await store.append(event)

    let recorder = PromptRecorder()
    let intelligence = IntelligenceActor(
      config: try makeConfig(threshold: 0.5),
      store: store,
      modelProvider: trustedProvider(recorder: recorder)
    )
    _ = try await intelligence.compressIdleMemories()

    // The recorder hop is fire-and-forget; give it a moment to land.
    for _ in 0..<50 where await recorder.prompts.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    let prompt = try #require(await recorder.prompts.first)
    #expect(prompt.contains("\"position\":[1.5,-2.25,3.75]"))
  }

  @Test("Compression consolidates at most maxNodes per call, oldest first")
  func compressionIsBounded() async throws {
    let store = try makeTestEncryptedStore()
    let base = Date(timeIntervalSinceNow: -60)
    let events = (0..<5).map { index in
      SpatialEvent(
        timestamp: base.addingTimeInterval(Double(index)),
        kind: .interaction(type: .touch, rawPosition: SIMD3(0, 0, 0))
      ).withScore(0.1)
    }
    await store.batchAppend(events)

    let intelligence = IntelligenceActor(
      config: try makeConfig(threshold: 0.5),
      store: store,
      modelProvider: trustedProvider()
    )

    let first = try await intelligence.compressIdleMemories(maxNodes: 2)
    #expect(first.nodesPruned == 2)
    #expect(await store.count == 3)
    #expect(await store.recalledCount(for: events[0].id) == nil)
    #expect(await store.recalledCount(for: events[1].id) == nil)
    #expect(await store.recalledCount(for: events[2].id) != nil)

    let second = try await intelligence.compressIdleMemories(maxNodes: 10)
    #expect(second.nodesPruned == 3)
    #expect(await store.isEmpty)
    #expect(await store.archiveNodeCount == 2)
  }
}
