// SwiftDataModelTests.swift
// AuraKitTests — Phase 2: Persistence Layer
//
// Validates RawMemoryNode and MemoryArchiveNode CRUD operations,
// schema integrity, and SwiftData compatibility.

import Foundation
import SwiftData
import Testing

@testable import AuraKit

@Suite("SwiftData Models — RawMemoryNode & MemoryArchiveNode", .serialized)
struct SwiftDataModelTests {

  private func makeContext() throws -> ModelContext {
    let container = try PersistenceController.makeInMemoryContainer()
    return ModelContext(container)
  }

  // MARK: - RawMemoryNode

  @Test("RawMemoryNode insert and fetch round-trip")
  func rawMemoryNodeCRUD() throws {
    let ctx = try makeContext()
    let node = RawMemoryNode(
      encryptedPayload: Data("ciphertext".utf8),
      score: 0.85,
      timestamp: Date(),
      eventType: .touch
    )
    ctx.insert(node)
    try ctx.save()

    let fetched = try ctx.fetch(FetchDescriptor<RawMemoryNode>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.id == node.id)
    #expect(fetched.first?.score == 0.85)
    #expect(fetched.first?.eventType == "touch")
    #expect(fetched.first?.recalled == 0)
  }

  @Test("RawMemoryNode spatialEventType computed property")
  func rawMemoryNodeEventType() throws {
    let node = RawMemoryNode(
      encryptedPayload: Data(),
      score: 1.0,
      timestamp: Date(),
      eventType: .gaze
    )
    #expect(node.spatialEventType == .gaze)
  }

  @Test("RawMemoryNode recalled counter increments")
  func rawMemoryNodeRecallCounter() throws {
    let ctx = try makeContext()
    let node = RawMemoryNode(
      encryptedPayload: Data("test".utf8),
      score: 0.5,
      timestamp: Date(),
      eventType: .move
    )
    ctx.insert(node)
    node.recalled += 1
    node.recalled += 1
    try ctx.save()

    let fetched = try ctx.fetch(FetchDescriptor<RawMemoryNode>())
    #expect(fetched.first?.recalled == 2)
  }

  // MARK: - MemoryArchiveNode

  @Test("MemoryArchiveNode insert and fetch round-trip")
  func memoryArchiveNodeCRUD() throws {
    let ctx = try makeContext()
    let sourceIDs = [UUID(), UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("encrypted summary".utf8),
      sourceNodeIDs: sourceIDs
    )
    ctx.insert(node)
    try ctx.save()

    let fetched = try ctx.fetch(FetchDescriptor<MemoryArchiveNode>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.id == node.id)
    #expect(fetched.first?.decodedSourceNodeIDs == sourceIDs)
  }

  @Test("MemoryArchiveNode source IDs survive encode/decode")
  func archiveNodeSourceIDsRoundTrip() throws {
    let ids = [UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data(),
      sourceNodeIDs: ids
    )
    #expect(node.decodedSourceNodeIDs == ids)
  }

  @Test("MemoryArchiveNode updateSourceNodeIDs replaces IDs")
  func archiveNodeUpdateSourceIDs() throws {
    let node = MemoryArchiveNode(
      encryptedSummary: Data(),
      sourceNodeIDs: [UUID()]
    )
    let newIDs = [UUID(), UUID(), UUID()]
    node.updateSourceNodeIDs(newIDs)
    #expect(node.decodedSourceNodeIDs == newIDs)
  }

  // MARK: - PersistenceController

  @Test("In-memory container creates successfully")
  func inMemoryContainerCreation() throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let ctx = ModelContext(container)
    let count = try ctx.fetchCount(FetchDescriptor<RawMemoryNode>())
    #expect(count == 0)
  }

  // MARK: - SpatialEventType

  @Test("SpatialEventType covers all SpatialEventKind variants")
  func eventTypeBridgeCompleteness() {
    let gaze = SpatialEventKind.gaze(position: .zero)
    #expect(gaze.eventType == .gaze)

    let touch = SpatialEventKind.interaction(type: .touch, position: .zero)
    #expect(touch.eventType == .touch)

    let move = SpatialEventKind.interaction(type: .move, position: .zero)
    #expect(move.eventType == .move)

    let pinch = SpatialEventKind.interaction(type: .pinch, position: .zero)
    #expect(pinch.eventType == .pinch)

    let drag = SpatialEventKind.interaction(type: .drag, position: .zero)
    #expect(drag.eventType == .drag)
  }

  @Test("SpatialEventType rawValue round-trip")
  func eventTypeRawValueRoundTrip() {
    for eventType in SpatialEventType.allCases {
      let raw = eventType.rawValue
      let decoded = SpatialEventType(rawValue: raw)
      #expect(decoded == eventType)
    }
  }

  // MARK: - Edge Cases

  @Test("MemoryArchiveNode with empty sourceNodeIDs returns empty array")
  func archiveNodeEmptySourceIDs() {
    let node = MemoryArchiveNode(
      encryptedSummary: Data(),
      sourceNodeIDs: []
    )
    #expect(node.decodedSourceNodeIDs.isEmpty)
  }

  @Test("MemoryArchiveNode with corrupt sourceNodeIDsData returns empty array")
  func archiveNodeCorruptSourceIDs() {
    let node = MemoryArchiveNode(
      encryptedSummary: Data(),
      sourceNodeIDs: [UUID()]
    )
    // Manually corrupt the source data
    node.sourceNodeIDsData = Data("not valid json".utf8)
    #expect(node.decodedSourceNodeIDs.isEmpty)
  }

  @Test("RawMemoryNode with unknown eventType raw value returns nil spatialEventType")
  func rawNodeCorruptEventType() {
    let node = RawMemoryNode(
      encryptedPayload: Data(),
      score: 0.5,
      timestamp: Date(),
      eventType: .gaze
    )
    // Manually set an invalid event type
    node.eventType = "unknown_type"
    #expect(node.spatialEventType == nil)
  }
}
