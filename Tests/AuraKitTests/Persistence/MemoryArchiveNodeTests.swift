// MemoryArchiveNodeTests.swift
// AuraKitTests — Persistence Layer
//
// Validates MemoryArchiveNode's sourceNodeIDs encoding, decoding,
// caching, and edge cases for the compressed semantic archive model.

import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - MemoryArchiveNode Tests

@Suite("Persistence — MemoryArchiveNode", .serialized)
struct MemoryArchiveNodeTests {

  // MARK: - Round-Trip Encoding

  @Test("sourceNodeIDs round-trip encoding/decoding preserves UUIDs")
  func sourceNodeIDsRoundTrip() throws {
    let sourceIDs = [UUID(), UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("encrypted-summary".utf8),
      sourceNodeIDs: sourceIDs
    )

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded == sourceIDs, "Decoded source node IDs should match original")
  }

  // MARK: - Empty Source IDs

  @Test("Empty sourceNodeIDs array encodes and decodes correctly")
  func emptySourceNodeIDs() throws {
    let node = MemoryArchiveNode(
      encryptedSummary: Data("empty-test".utf8),
      sourceNodeIDs: []
    )

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.isEmpty, "Empty source IDs should decode to empty array")
  }

  // MARK: - Single UUID

  @Test("Single UUID round-trips correctly")
  func singleUUIDRoundTrip() throws {
    let singleID = UUID()
    let node = MemoryArchiveNode(
      encryptedSummary: Data("single".utf8),
      sourceNodeIDs: [singleID]
    )

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.count == 1)
    #expect(decoded.first == singleID)
  }

  // MARK: - Large ID Set

  @Test("100+ sourceNodeIDs round-trip without data loss")
  func largeSourceNodeIDsRoundTrip() throws {
    let sourceIDs = (0..<150).map { _ in UUID() }
    let node = MemoryArchiveNode(
      encryptedSummary: Data("large-set".utf8),
      sourceNodeIDs: sourceIDs
    )

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.count == 150, "All 150 UUIDs should survive round-trip")
    #expect(decoded == sourceIDs, "Order should be preserved")
  }

  // MARK: - Update Source Node IDs

  @Test("updateSourceNodeIDs replaces existing IDs")
  func updateSourceNodeIDs() throws {
    let originalIDs = [UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("update-test".utf8),
      sourceNodeIDs: originalIDs
    )

    let newIDs = [UUID(), UUID(), UUID(), UUID()]
    node.updateSourceNodeIDs(newIDs)

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded == newIDs, "Updated IDs should replace original")
    #expect(decoded.count == 4)
  }

  // MARK: - Cache Invalidation

  @Test("decodedSourceNodeIDs cache is invalidated after updateSourceNodeIDs")
  func cacheInvalidationOnUpdate() throws {
    let originalIDs = [UUID(), UUID()]
    let node = MemoryArchiveNode(
      encryptedSummary: Data("cache-test".utf8),
      sourceNodeIDs: originalIDs
    )

    // First access — populates cache
    let firstRead = node.decodedSourceNodeIDs
    #expect(firstRead == originalIDs)

    // Second access — should return cached value (same content)
    let cachedRead = node.decodedSourceNodeIDs
    #expect(cachedRead == originalIDs, "Cached read should match original")

    // Update — should invalidate cache
    let updatedIDs = [UUID()]
    node.updateSourceNodeIDs(updatedIDs)

    // Post-update access — should reflect new values
    let postUpdateRead = node.decodedSourceNodeIDs
    #expect(postUpdateRead == updatedIDs, "Post-update read should reflect new IDs")
    #expect(postUpdateRead.count == 1)
  }

  // MARK: - Corrupted Data Resilience

  @Test("decodedSourceNodeIDs returns empty array for corrupted data")
  func corruptedDataResilience() throws {
    let node = MemoryArchiveNode(
      encryptedSummary: Data("corrupt-test".utf8),
      sourceNodeIDs: [UUID()]
    )

    // Corrupt the sourceNodeIDsData
    node.sourceNodeIDsData = Data("not-valid-json".utf8)
    // Invalidate cache by setting it to nil
    node._cachedSourceNodeIDs = nil

    let decoded = node.decodedSourceNodeIDs
    #expect(decoded.isEmpty, "Corrupted data should decode to empty array, not crash")
  }

  // MARK: - Properties

  @Test("MemoryArchiveNode properties are correctly set on init")
  func propertiesSetCorrectly() throws {
    let id = UUID()
    let summary = Data("test-summary".utf8)
    let date = Date()
    let sourceIDs = [UUID(), UUID()]

    let node = MemoryArchiveNode(
      id: id,
      encryptedSummary: summary,
      createdAt: date,
      sourceNodeIDs: sourceIDs
    )

    #expect(node.id == id)
    #expect(node.encryptedSummary == summary)
    #expect(node.createdAt == date)
    #expect(node.decodedSourceNodeIDs == sourceIDs)
  }

  // MARK: - Default Values

  @Test("MemoryArchiveNode auto-generates id and createdAt")
  func defaultValues() throws {
    let before = Date()
    let node = MemoryArchiveNode(
      encryptedSummary: Data("defaults".utf8),
      sourceNodeIDs: []
    )
    let after = Date()

    // id should be auto-generated
    #expect(node.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))

    // createdAt should be between before and after
    #expect(node.createdAt >= before)
    #expect(node.createdAt <= after)
  }
}
