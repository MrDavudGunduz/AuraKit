// RawMemoryNodeSnapshotTests.swift
// AuraKitTests — RawMemoryNodeSnapshot Tests

import Foundation
import Testing

@testable import AuraKit

@Suite("RawMemoryNodeSnapshot — Concurrency Safety Tests", .serialized)
struct RawMemoryNodeSnapshotTests {

  @Test("RawMemoryNodeSnapshot creates valid Sendable snapshot from RawMemoryNode")
  func snapshotCreationFromNode() throws {
    let id = UUID()
    let now = Date()
    let node = RawMemoryNode(
      id: id,
      encryptedPayload: Data("ciphertext".utf8),
      score: 0.85,
      timestamp: now,
      eventType: .touch,
      recalled: 3,
      keyVersion: 1
    )

    guard let snapshot = RawMemoryNodeSnapshot(node: node) else {
      Issue.record("Failed to create snapshot from valid node")
      return
    }

    #expect(snapshot.id == id)
    #expect(snapshot.score == 0.85)
    #expect(snapshot.timestamp == now)
    #expect(snapshot.eventType == .touch)
    #expect(snapshot.recalled == 3)
    #expect(snapshot.keyVersion == 1)
  }

  @Test("fetchNodeSnapshots returns Sendable snapshots sorted by score")
  func fetchNodeSnapshotsQuery() async throws {
    let store = try makeTestEncryptedStore()

    let event1 = SpatialEvent.touch(at: SIMD3(0, 0, 0)).withScore(0.5)
    let event2 = SpatialEvent.touch(at: SIMD3(1, 1, 1)).withScore(0.9)
    await store.append(event1)
    await store.append(event2)
    await store.flushPendingWrites()

    let snapshots = await store.fetchNodeSnapshots(eventType: .touch)
    #expect(snapshots.count == 2)
    #expect(snapshots[0].score == 0.9)
    #expect(snapshots[1].score == 0.5)
  }
}
