// SpatialEventPropertyTests.swift
// AuraKitTests — Property-Based Round-Trip Testing
//
// Validates that SpatialEvent maintains full fidelity through JSON
// serialization round-trips. Uses parameterized tests with diverse
// event configurations to verify Codable conformance correctness.

import Foundation
import simd
import Testing

@testable import AuraKit

// MARK: - SpatialEvent Codable Round-Trip

@Suite("Property — SpatialEvent Codable Round-Trip")
struct SpatialEventPropertyTests {

  /// Diverse set of positions covering origin, positive, negative, and extreme values.
  static let testPositions: [CodableSIMD3] = [
    .zero,
    CodableSIMD3(SIMD3<Float>(1.0, 2.0, 3.0)),
    CodableSIMD3(SIMD3<Float>(-1.0, -2.0, -3.0)),
    CodableSIMD3(SIMD3<Float>(0.001, 0.002, 0.003)),
    CodableSIMD3(SIMD3<Float>(999.99, -999.99, 0.0)),
    CodableSIMD3(SIMD3<Float>(.leastNormalMagnitude, .greatestFiniteMagnitude, .pi)),
  ]

  /// All interaction types the system supports.
  static let interactionTypes: [InteractionType] = [
    .touch, .move, .pinch, .drag,
  ]

  @Test(
    "Gaze event survives JSON round-trip at diverse positions",
    arguments: testPositions
  )
  func gazeRoundTrip(position: CodableSIMD3) throws {
    let original = SpatialEvent(kind: .gaze(position: position), score: 0.42)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SpatialEvent.self, from: encoded)

    #expect(decoded.id == original.id)
    #expect(decoded.kind == original.kind)
    #expect(decoded.score == original.score)
    #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 0.001)
  }

  @Test(
    "Interaction event survives JSON round-trip for all interaction types",
    arguments: interactionTypes
  )
  func interactionRoundTrip(type: InteractionType) throws {
    let position = CodableSIMD3(SIMD3<Float>(0.5, 1.2, -0.8))
    let original = SpatialEvent(
      kind: .interaction(type: type, position: position),
      score: 1.0
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SpatialEvent.self, from: encoded)

    #expect(decoded.id == original.id)
    #expect(decoded.kind == original.kind)
    #expect(decoded.score == original.score)

    // Verify the interaction type survived the round-trip
    if case .interaction(let decodedType, let decodedPosition) = decoded.kind {
      #expect(decodedType == type)
      #expect(decodedPosition == position)
    } else {
      Issue.record("Decoded event kind is not .interaction — expected .interaction(type: \(type))")
    }
  }

  @Test("Score boundary values survive round-trip")
  func scoreBoundaryRoundTrip() throws {
    let scores: [Double] = [0.0, 0.001, 0.5, 0.999, 1.0]

    for score in scores {
      let original = SpatialEvent(
        kind: .gaze(position: .zero),
        score: score
      )
      let encoded = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(SpatialEvent.self, from: encoded)
      #expect(decoded.score == original.score, "Score \(score) did not survive round-trip")
    }
  }

  @Test("UUID identity is preserved through serialization")
  func uuidPreservation() throws {
    let fixedID = UUID()
    let original = SpatialEvent(
      id: fixedID,
      kind: .interaction(type: .touch, position: .zero),
      score: 0.8
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SpatialEvent.self, from: encoded)

    #expect(decoded.id == fixedID)
  }

  @Test("Batch of mixed events all survive round-trip")
  func batchMixedRoundTrip() throws {
    let events: [SpatialEvent] = [
      .gazeFixture(score: 0.3),
      .touchFixture(score: 1.0),
      .moveFixture(score: 0.9),
      .pinchFixture(score: 0.7),
      .dragFixture(score: 0.5),
      SpatialEvent(kind: .gaze(position: CodableSIMD3(SIMD3<Float>(100, -200, 300))), score: 0.1),
    ]

    let encoded = try JSONEncoder().encode(events)
    let decoded = try JSONDecoder().decode([SpatialEvent].self, from: encoded)

    #expect(decoded.count == events.count)
    for (original, restored) in zip(events, decoded) {
      #expect(restored.id == original.id)
      #expect(restored.kind == original.kind)
      #expect(restored.score == original.score)
    }
  }

  @Test("AES-GCM encrypt → decrypt round-trip preserves full event fidelity")
  func encryptDecryptRoundTrip() throws {
    let service = EncryptionService()
    let key = SymmetricKey(size: .bits256)
    let original = SpatialEvent(
      kind: .interaction(
        type: .pinch,
        position: CodableSIMD3(SIMD3<Float>(1.5, -2.3, 0.7))
      ),
      score: 0.85
    )

    let plaintext = try JSONEncoder().encode(original)
    let ciphertext = try service.encrypt(plaintext, using: key)
    let decrypted = try service.decrypt(ciphertext, using: key)
    let restored = try JSONDecoder().decode(SpatialEvent.self, from: decrypted)

    #expect(restored.id == original.id)
    #expect(restored.kind == original.kind)
    #expect(restored.score == original.score)
  }
}
