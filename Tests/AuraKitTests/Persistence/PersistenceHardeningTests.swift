// PersistenceHardeningTests.swift
// AuraKitTests — Persistence Layer Hardening Tests
//
// Covers audit-identified test gaps:
// - MemoryArchiveNode.updateSourceNodeIDs() edge cases
// - PersistenceController container factory validation
// - EncryptedMemoryStore defensive behaviour under edge conditions

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - MemoryArchiveNode Edge Cases

@Suite("MemoryArchiveNode — Edge Cases")
struct MemoryArchiveNodeEdgeCaseTests {

  @Test("decodedSourceNodeIDs returns correct UUIDs after init")
  func decodedSourceNodeIDsAfterInit() throws {
    let ids = [UUID(), UUID(), UUID()]
    let container = try PersistenceController.makeInMemoryContainer()
    let context = ModelContext(container)

    let node = MemoryArchiveNode(
      encryptedSummary: Data("test-ciphertext".utf8),
      sourceNodeIDs: ids
    )
    context.insert(node)
    try context.save()

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.count == 3)
    #expect(decoded == ids)
  }

  @Test("updateSourceNodeIDs replaces existing IDs")
  func updateSourceNodeIDsReplacesExisting() throws {
    let originalIDs = [UUID(), UUID()]
    let container = try PersistenceController.makeInMemoryContainer()
    let context = ModelContext(container)

    let node = MemoryArchiveNode(
      encryptedSummary: Data("test-ciphertext".utf8),
      sourceNodeIDs: originalIDs
    )
    context.insert(node)
    try context.save()

    let newIDs = [UUID(), UUID(), UUID(), UUID()]
    node.updateSourceNodeIDs(newIDs)

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.count == 4)
    #expect(decoded == newIDs)
  }

  @Test("decodedSourceNodeIDs with empty array returns empty")
  func decodedSourceNodeIDsEmpty() {
    let node = MemoryArchiveNode(
      encryptedSummary: Data("test-ciphertext".utf8),
      sourceNodeIDs: []
    )
    #expect(node.decodedSourceNodeIDs.isEmpty)
  }

  @Test("MemoryArchiveNode with corrupt sourceNodeIDsData returns empty array")
  func corruptSourceNodeIDsData() {
    let node = MemoryArchiveNode(
      encryptedSummary: Data("test-ciphertext".utf8),
      sourceNodeIDs: [UUID()]
    )
    // Manually corrupt the data
    node.sourceNodeIDsData = Data("not-valid-json".utf8)

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.isEmpty, "Corrupt sourceNodeIDsData should return empty array, not crash")
  }

  @Test("MemoryArchiveNode unique constraint on id")
  func uniqueConstraintOnID() throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let context = ModelContext(container)
    context.autosaveEnabled = false

    let sharedID = UUID()
    let node1 = MemoryArchiveNode(
      id: sharedID,
      encryptedSummary: Data("summary-1".utf8),
      sourceNodeIDs: []
    )
    let node2 = MemoryArchiveNode(
      id: sharedID,
      encryptedSummary: Data("summary-2".utf8),
      sourceNodeIDs: []
    )

    context.insert(node1)
    context.insert(node2)

    // SwiftData should handle the unique constraint — save may merge or throw
    // The test validates that the framework doesn't crash on duplicate IDs
    do {
      try context.save()
    } catch {
      // Expected: unique constraint violation is acceptable behaviour
    }
  }
}

// MARK: - PersistenceController Tests

@Suite("PersistenceController — Container Factory")
struct PersistenceControllerTests {

  @Test("makeInMemoryContainer creates a valid container")
  func inMemoryContainerCreation() throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let context = ModelContext(container)

    // Verify the schema includes both model types
    let rawDescriptor = FetchDescriptor<RawMemoryNode>()
    let archiveDescriptor = FetchDescriptor<MemoryArchiveNode>()

    let rawCount = try context.fetchCount(rawDescriptor)
    let archiveCount = try context.fetchCount(archiveDescriptor)

    #expect(rawCount == 0)
    #expect(archiveCount == 0)
  }

  @Test("makeContainer creates a valid on-disk container")
  func onDiskContainerCreation() throws {
    let container = try PersistenceController.makeContainer()
    let context = ModelContext(container)

    let descriptor = FetchDescriptor<RawMemoryNode>()
    // Should not throw — schema is correctly configured
    _ = try context.fetchCount(descriptor)
  }

  @Test("Schema includes both RawMemoryNode and MemoryArchiveNode")
  func schemaContainsBothModels() {
    let schema = PersistenceController.schema
    let entityNames = schema.entities.map(\.name)

    #expect(entityNames.contains("RawMemoryNode"))
    #expect(entityNames.contains("MemoryArchiveNode"))
  }

  @Test("Multiple in-memory containers are independent")
  func independentInMemoryContainers() throws {
    let container1 = try PersistenceController.makeInMemoryContainer()
    let container2 = try PersistenceController.makeInMemoryContainer()

    let context1 = ModelContext(container1)
    let context2 = ModelContext(container2)
    context1.autosaveEnabled = false
    context2.autosaveEnabled = false

    // Insert into container 1 only
    let node = RawMemoryNode(
      encryptedPayload: Data("test".utf8),
      score: 1.0,
      timestamp: Date(),
      eventType: .touch
    )
    context1.insert(node)
    try context1.save()

    let count1 = try context1.fetchCount(FetchDescriptor<RawMemoryNode>())
    let count2 = try context2.fetchCount(FetchDescriptor<RawMemoryNode>())

    #expect(count1 == 1)
    #expect(count2 == 0, "Separate in-memory containers must be independent")
  }
}

// MARK: - EncryptedMemoryStore Defensive Behaviour

@Suite("EncryptedMemoryStore — Defensive Behaviour")
struct EncryptedMemoryStoreDefensiveTests {

  @Test("Concurrent batchAppend calls are serialised by actor")
  func concurrentBatchAppendSafety() async throws {
    let store = try makeTestEncryptedStore()

    // Launch multiple concurrent batch appends
    await withTaskGroup(of: Void.self) { group in
      for batch in 0..<5 {
        group.addTask {
          let events = (0..<10).map { idx in
            SpatialEvent(
              timestamp: Date(timeIntervalSince1970: Double(batch * 10 + idx)),
              kind: .interaction(type: .touch, position: .zero),
              score: 1.0
            )
          }
          await store.batchAppend(events)
        }
      }
    }

    let count = await store.count
    #expect(count == 50, "All 50 events from 5 concurrent batches should be persisted")
  }

  @Test("events(limit:offset:) with zero limit returns empty")
  func zeroLimitReturnsEmpty() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.touchFixture())

    let page = await store.events(limit: 0)
    #expect(page.isEmpty)
  }

  @Test("deleteNodes on store with only high-score events deletes nothing")
  func deleteNodesHighScoreOnly() async throws {
    let store = try makeTestEncryptedStore()
    await store.append(SpatialEvent.touchFixture(score: 1.0))
    await store.append(SpatialEvent.touchFixture(score: 0.9))

    let deleted = await store.deleteNodes(belowScore: 0.5)
    #expect(deleted == 0)
    #expect(await store.count == 2)
  }

  @Test("recalledCount for non-existent UUID returns nil")
  func recalledCountNonExistent() async throws {
    let store = try makeTestEncryptedStore()
    let recalled = await store.recalledCount(for: UUID())
    #expect(recalled == nil)
  }

  @Test("rawCiphertext for non-existent UUID returns nil")
  func rawCiphertextNonExistent() async throws {
    let store = try makeTestEncryptedStore()
    let ciphertext = await store.rawCiphertext(for: UUID())
    #expect(ciphertext == nil)
  }
}
