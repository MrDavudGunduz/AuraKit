// SpatialEventCodableTests.swift
// AuraKitTests — Phase 1: Codable round-trip tests
//
// Validates that SpatialEvent, SpatialEventKind, and CodableSIMD3 survive a
// full JSON encode → decode cycle with no data loss. This is critical for
// Phase 2 SwiftData / CloudKit persistence correctness.

import Foundation
import Testing
import simd

@testable import AuraKit

// MARK: - CodableSIMD3 Tests

@Suite("CodableSIMD3 Codable")
struct CodableSIMD3CodableTests {

  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  @Test("CodableSIMD3 round-trips origin (0, 0, 0)")
  func testOriginRoundTrip() throws {
    let original = CodableSIMD3(SIMD3<Float>(0, 0, 0))
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(CodableSIMD3.self, from: data)
    #expect(decoded.x == original.x)
    #expect(decoded.y == original.y)
    #expect(decoded.z == original.z)
  }

  @Test("CodableSIMD3 round-trips non-zero components")
  func testNonZeroRoundTrip() throws {
    let original = CodableSIMD3(SIMD3<Float>(1.23, -4.56, 7.89))
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(CodableSIMD3.self, from: data)
    #expect(decoded.x == original.x)
    #expect(decoded.y == original.y)
    #expect(decoded.z == original.z)
  }

  @Test("CodableSIMD3.simd3 returns the original SIMD3<Float> value")
  func testSIMD3Property() {
    let raw = SIMD3<Float>(0.1, 0.2, 0.3)
    let wrapped = CodableSIMD3(raw)
    #expect(wrapped.simd3 == raw)
  }
}

// MARK: - SpatialEventKind Tests

@Suite("SpatialEventKind Codable")
struct SpatialEventKindCodableTests {

  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  @Test(".gaze round-trips position through JSON")
  func testGazeRoundTrip() throws {
    let position = CodableSIMD3(SIMD3<Float>(0.5, 1.0, -2.5))
    let original = SpatialEventKind.gaze(position: position)
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(SpatialEventKind.self, from: data)

    guard case .gaze(let decodedPosition) = decoded else {
      Issue.record("Expected .gaze, got \(decoded)")
      return
    }
    #expect(decodedPosition.x == position.x)
    #expect(decodedPosition.y == position.y)
    #expect(decodedPosition.z == position.z)
  }

  @Test(".interaction round-trips type and position through JSON")
  func testInteractionRoundTrip() throws {
    let position = CodableSIMD3(SIMD3<Float>(0.1, 0.9, -1.0))
    let original = SpatialEventKind.interaction(type: .pinch, position: position)
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(SpatialEventKind.self, from: data)

    guard case .interaction(let decodedType, let decodedPosition) = decoded else {
      Issue.record("Expected .interaction, got \(decoded)")
      return
    }
    #expect(decodedType == .pinch)
    #expect(decodedPosition.x == position.x)
    #expect(decodedPosition.y == position.y)
    #expect(decodedPosition.z == position.z)
  }

  @Test("All InteractionType cases survive encode/decode")
  func testAllInteractionTypes() throws {
    let types: [InteractionType] = [.touch, .move, .pinch, .drag]
    for type_ in types {
      let kind = SpatialEventKind.interaction(
        type: type_,
        position: CodableSIMD3(SIMD3<Float>(0, 0, 0))
      )
      let data = try encoder.encode(kind)
      let decoded = try decoder.decode(SpatialEventKind.self, from: data)
      guard case .interaction(let decodedType, _) = decoded else {
        Issue.record("Expected .interaction for \(type_)")
        continue
      }
      #expect(decodedType == type_)
    }
  }
}

// MARK: - SpatialEvent Full Round-Trip

@Suite("SpatialEvent Codable")
struct SpatialEventCodableTests {

  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  @Test("Gaze SpatialEvent round-trips id, timestamp, kind, and score")
  func testGazeEventFullRoundTrip() throws {
    let id = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let position = CodableSIMD3(SIMD3<Float>(0.7, 0.2, -0.5))
    let original = SpatialEvent(
      id: id,
      timestamp: timestamp,
      kind: .gaze(position: position),
      score: 0.3
    )

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(SpatialEvent.self, from: data)

    #expect(decoded.id == id)
    #expect(decoded.timestamp == timestamp)
    #expect(decoded.score == 0.3)
    guard case .gaze(let decodedPos) = decoded.kind else {
      Issue.record("Expected .gaze kind")
      return
    }
    #expect(approxEqual(decodedPos.x, position.x))
    #expect(approxEqual(decodedPos.y, position.y))
    #expect(approxEqual(decodedPos.z, position.z))
  }

  @Test("Touch SpatialEvent round-trips id, timestamp, kind, and score")
  func testTouchEventFullRoundTrip() throws {
    let id = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let position = CodableSIMD3(SIMD3<Float>(1.0, -1.0, 0.5))
    let original = SpatialEvent(
      id: id,
      timestamp: timestamp,
      kind: .interaction(type: .touch, position: position),
      score: 1.0
    )

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(SpatialEvent.self, from: data)

    #expect(decoded.id == id)
    #expect(decoded.score == 1.0)
    guard case .interaction(let type, let decodedPos) = decoded.kind else {
      Issue.record("Expected .interaction kind")
      return
    }
    #expect(type == .touch)
    #expect(approxEqual(decodedPos.x, position.x))
    #expect(approxEqual(decodedPos.y, position.y))
    #expect(approxEqual(decodedPos.z, position.z))
  }

  @Test("SpatialEvent JSON is human-readable (no binary encoding)")
  func testJSONIsHumanReadable() throws {
    let event = SpatialEvent(
      kind: .gaze(position: CodableSIMD3(SIMD3<Float>(0.1, 0.2, 0.3))),
      score: 0.3
    )
    let data = try encoder.encode(event)
    let json = String(decoding: data, as: UTF8.self)

    #expect(json.contains("\"kind\""))
    #expect(json.contains("\"gaze\""))
    #expect(json.contains("\"score\""))
  }
}

// MARK: - Float Approximate Equality (test scope only)

/// Returns `true` when `lhs` and `rhs` differ by less than 100 ULPs.
/// Prefer this over the `≈` infix operator inside `#expect` — the Testing
/// macro expander resolves custom operators via binary expression parsing,
/// which requires an explicit infix `operator` declaration.
private func approxEqual(_ lhs: Float, _ rhs: Float) -> Bool {
  abs(lhs - rhs) < Float.ulpOfOne * 100
}
