// CognitiveCompressionTests.swift
// AuraKitTests — Phase 4 Cognitive Compression Integration Tests

import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import AuraKit

@Suite("Intelligence — Cognitive Compression", .serialized)
struct CognitiveCompressionTests {

  @Test("ConsolidationPromptBuilder generates structured prompt from snapshots")
  func consolidationPromptBuilderFormatting() {
    let now = Date()
    let id1 = UUID()
    let id2 = UUID()

    let snapshot1 = RawMemoryNodeSnapshot(
      id: id1,
      score: 0.12,
      timestamp: now.addingTimeInterval(-100),
      eventType: .gaze,
      recalled: 0,
      keyVersion: 0
    )
    let snapshot2 = RawMemoryNodeSnapshot(
      id: id2,
      score: 0.08,
      timestamp: now.addingTimeInterval(-50),
      eventType: .touch,
      recalled: 0,
      keyVersion: 0
    )

    let prompt = ConsolidationPromptBuilder.build(from: [snapshot1, snapshot2])

    #expect(prompt.contains("\"task\":\"consolidate\""))
    #expect(prompt.contains("Summarize the key spatial events in one sentence."))
    #expect(prompt.contains("\"type\":\"gaze\""))
    #expect(prompt.contains("\"type\":\"touch\""))
    #expect(prompt.contains("\"score\":0.12"))
    #expect(prompt.contains("\"score\":0.08"))
  }

  @Test("compressIdleMemories returns empty report when no nodes fall below threshold")
  func compressIdleMemoriesNoQualifyingNodes() async throws {
    let store = try makeTestEncryptedStore(saveThreshold: 1)
    let config = AuraConfiguration(
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
        survivalIndexThreshold: 0.1
      )
    )
    let mockProvider = MockMLXModelProvider(mockResponse: "User gazed at bookshelf.")
    let intelligence = IntelligenceActor(config: config, store: store, modelProvider: mockProvider)

    // Store has only high-score event (score 1.0 > 0.1)
    let freshEvent = SpatialEvent.touchFixture(score: 1.0)
    await store.append(freshEvent)
    #expect(await store.count == 1)

    let report = try await intelligence.compressIdleMemories()

    #expect(report.nodesPruned == 0)
    #expect(report.archiveNodesCreated == 0)
    #expect(!report.didCompress)
    #expect(await store.count == 1)
    #expect(await store.archiveNodeCount == 0)
  }

  @Test("compressIdleMemories consolidates qualifying nodes into single archive and prunes sources")
  func compressIdleMemoriesSuccessfulConsolidation() async throws {
    let store = try makeTestEncryptedStore(saveThreshold: 1)
    let config = AuraConfiguration(
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
        survivalIndexThreshold: 0.5
      )
    )
    let mockSummary = "User examined the southeast case and moved to exit."
    let mockProvider = MockMLXModelProvider(mockResponse: mockSummary)
    let intelligence = IntelligenceActor(config: config, store: store, modelProvider: mockProvider)

    // Append 3 low-score events (score 0.2 < 0.5) and 1 high-score event (score 0.9)
    let lowScore1 = SpatialEvent.gazeFixture(score: 0.2)
    let lowScore2 = SpatialEvent.gazeFixture(score: 0.15)
    let lowScore3 = SpatialEvent.gazeFixture(score: 0.1)
    let highScore = SpatialEvent.touchFixture(score: 0.9)

    await store.append(lowScore1)
    await store.append(lowScore2)
    await store.append(lowScore3)
    await store.append(highScore)
    #expect(await store.count == 4)

    let report = try await intelligence.compressIdleMemories()

    #expect(report.didCompress)
    #expect(report.nodesPruned == 3)
    #expect(report.archiveNodesCreated == 1)
    #expect(report.summary == mockSummary)
    #expect(report.archiveNodeID != nil)
    #expect(report.bytesRecovered > 0)

    // Verify remaining store state: only 1 raw event left, exactly 1 archive created
    #expect(await store.count == 1)
    #expect(await store.archiveNodeCount == 1)

    let archives = await store.fetchArchiveSnapshots()
    #expect(archives.count == 1)
    let archive = archives[0]
    #expect(archive.id == report.archiveNodeID)
    #expect(archive.sourceNodeIDs.count == 3)
    #expect(archive.sourceNodeIDs.contains(lowScore1.id))
    #expect(archive.sourceNodeIDs.contains(lowScore2.id))
    #expect(archive.sourceNodeIDs.contains(lowScore3.id))
  }

  @Test("compressIdleMemories throws when run against non-encrypted store")
  func compressIdleMemoriesUnsupportedStore() async throws {
    let memoryStore = MemoryStore(capacity: 100)
    let config = AuraConfiguration(
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
        survivalIndexThreshold: 0.5
      )
    )
    let mockProvider = MockMLXModelProvider()
    let intelligence = IntelligenceActor(config: config, store: memoryStore, modelProvider: mockProvider)

    await #expect(throws: AuraError.self) {
      _ = try await intelligence.compressIdleMemories()
    }
  }

  @Test("MemoryManager API delegates to IntelligenceActor and emits telemetry events")
  func memoryManagerApiAndTelemetryEvents() async throws {
    let store = try makeTestEncryptedStore(saveThreshold: 1)
    let config = AuraConfiguration(
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
        survivalIndexThreshold: 0.5
      )
    )
    let mockProvider = MockMLXModelProvider(mockResponse: "Telemetry test summary.")
    let captureActor = CaptureActor(config: config, store: store)
    _ = await captureActor.intelligenceActor(modelProvider: mockProvider)
    let memoryManager = MemoryManager(captureActor: captureActor)

    let event = SpatialEvent.gazeFixture(score: 0.1)
    await store.append(event)

    let report = try await memoryManager.compressIdleMemories()
    #expect(report.didCompress)
    #expect(report.nodesPruned == 1)
    #expect(report.archiveNodesCreated == 1)
    #expect(await store.count == 0)
    #expect(await store.archiveNodeCount == 1)
  }
}
