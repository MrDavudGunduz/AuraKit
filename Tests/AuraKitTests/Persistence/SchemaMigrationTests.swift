// SchemaMigrationTests.swift
// AuraKitTests — On-disk SwiftData migration tests.

import Foundation
import SwiftData
import Testing

@testable import AuraKit

@Suite("Persistence — Schema Migration", .serialized)
struct SchemaMigrationTests {

  /// A unique on-disk store URL, removed (with its -wal/-shm siblings) on cleanup.
  private func makeStoreURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("AuraKitMigration-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("AuraKit.store")
  }

  private func removeStore(at url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test("V2 store migrates to V3 without data loss")
  func v2StoreMigratesToV3() throws {
    let url = makeStoreURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { removeStore(at: url) }

    let rawID = UUID()
    let archiveID = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 1_000)
    try writeV2Store(at: url, rawID: rawID, archiveID: archiveID, timestamp: timestamp)

    // Reopen through the production migration plan.
    let v3Schema = Schema(versionedSchema: AuraKitSchemaV3.self)
    let container = try ModelContainer(
      for: v3Schema,
      migrationPlan: AuraKitMigrationPlan.self,
      configurations: [ModelConfiguration(schema: v3Schema, url: url)]
    )
    let context = ModelContext(container)

    let nodes = try context.fetch(FetchDescriptor<RawMemoryNode>())
    #expect(nodes.count == 1)
    let node = try #require(nodes.first)
    #expect(node.id == rawID)
    #expect(node.encryptedPayload == Data([1, 2, 3]))
    #expect(node.score == 0.42)
    #expect(node.timestamp == timestamp)
    #expect(node.spatialEventType == .touch)
    #expect(node.recalled == 3)
    #expect(node.keyVersion == 1)

    let archives = try context.fetch(FetchDescriptor<MemoryArchiveNode>())
    #expect(archives.count == 1)
    #expect(archives.first?.id == archiveID)
    #expect(archives.first?.decodedSourceNodeIDs == [rawID])
  }

  private func writeV2Store(
    at url: URL,
    rawID: UUID,
    archiveID: UUID,
    timestamp: Date
  ) throws {
    let v2Schema = Schema(versionedSchema: AuraKitSchemaV2.self)
    let container = try ModelContainer(
      for: v2Schema,
      configurations: [ModelConfiguration(schema: v2Schema, url: url)]
    )
    let context = ModelContext(container)
    context.insert(AuraKitSchemaV2.RawMemoryNode(
      id: rawID,
      encryptedPayload: Data([1, 2, 3]),
      score: 0.42,
      timestamp: timestamp,
      eventType: SpatialEventType.touch.rawValue,
      recalled: 3,
      keyVersion: 1
    ))
    context.insert(AuraKitSchemaV2.MemoryArchiveNode(
      id: archiveID,
      encryptedSummary: Data([9]),
      createdAt: timestamp,
      sourceNodeIDsData: try JSONEncoder().encode([rawID])
    ))
    try context.save()
  }

  @Test("V3 enforces unique raw node ids (duplicate insert upserts)")
  func v3EnforcesUniqueIDs() throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let context = ModelContext(container)
    let id = UUID()

    for payload in [Data([1]), Data([2])] {
      context.insert(RawMemoryNode(
        id: id,
        encryptedPayload: payload,
        score: 1,
        timestamp: Date(),
        eventType: .touch
      ))
      try context.save()
    }

    let nodes = try context.fetch(FetchDescriptor<RawMemoryNode>())
    #expect(nodes.count == 1)
    #expect(nodes.first?.encryptedPayload == Data([2]))
  }

  @Test("Appending the same event twice keeps a single encrypted row")
  func duplicateAppendIsIdempotent() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touch(at: SIMD3(1, 2, 3)).withScore(1)

    await store.append(event)
    await store.append(event)

    #expect(await store.count == 1)
    #expect(await store.allEvents().map(\.id) == [event.id])
  }
}

