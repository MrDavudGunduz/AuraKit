// SpatialEventFactoryTests.swift
// AuraKitTests — Models
//
// Validates the top-level SpatialEvent convenience factories:
// .gaze(at:), .touch(at:), .move(at:), .pinch(at:), .drag(at:)

import Foundation
import simd
import Testing

@testable import AuraKit

@Suite("SpatialEvent — Convenience Factories")
struct SpatialEventFactoryTests {

  // MARK: - Test Position

  private let testPosition = SIMD3<Float>(1.5, 2.0, -0.5)

  // MARK: - Gaze Factory

  @Test(".gaze(at:) creates a gaze event at the correct position")
  func gazeFactory() {
    let event = SpatialEvent.gaze(at: testPosition)

    if case .gaze(let position) = event.kind {
      #expect(position.x == testPosition.x)
      #expect(position.y == testPosition.y)
      #expect(position.z == testPosition.z)
    } else {
      Issue.record("Expected .gaze kind, got \(event.kind)")
    }
  }

  @Test(".gaze(at:) defaults score to 0")
  func gazeFactoryDefaultScore() {
    let event = SpatialEvent.gaze(at: testPosition)
    #expect(event.score == 0)
  }

  // MARK: - Touch Factory

  @Test(".touch(at:) creates a touch interaction event")
  func touchFactory() {
    let event = SpatialEvent.touch(at: testPosition)

    if case .interaction(let type, let position) = event.kind {
      #expect(type == .touch)
      #expect(position.x == testPosition.x)
      #expect(position.y == testPosition.y)
      #expect(position.z == testPosition.z)
    } else {
      Issue.record("Expected .interaction(type: .touch) kind, got \(event.kind)")
    }
  }

  // MARK: - Move Factory

  @Test(".move(at:) creates a move interaction event")
  func moveFactory() {
    let event = SpatialEvent.move(at: testPosition)

    if case .interaction(let type, let position) = event.kind {
      #expect(type == .move)
      #expect(position.x == testPosition.x)
    } else {
      Issue.record("Expected .interaction(type: .move) kind, got \(event.kind)")
    }
  }

  // MARK: - Pinch Factory

  @Test(".pinch(at:) creates a pinch interaction event")
  func pinchFactory() {
    let event = SpatialEvent.pinch(at: testPosition)

    if case .interaction(let type, let position) = event.kind {
      #expect(type == .pinch)
      #expect(position.y == testPosition.y)
    } else {
      Issue.record("Expected .interaction(type: .pinch) kind, got \(event.kind)")
    }
  }

  // MARK: - Drag Factory

  @Test(".drag(at:) creates a drag interaction event")
  func dragFactory() {
    let event = SpatialEvent.drag(at: testPosition)

    if case .interaction(let type, let position) = event.kind {
      #expect(type == .drag)
      #expect(position.z == testPosition.z)
    } else {
      Issue.record("Expected .interaction(type: .drag) kind, got \(event.kind)")
    }
  }

  // MARK: - All Factories Generate Unique IDs

  @Test("Each factory call generates a unique UUID")
  func factoriesGenerateUniqueIDs() {
    let events = [
      SpatialEvent.gaze(at: testPosition),
      SpatialEvent.touch(at: testPosition),
      SpatialEvent.move(at: testPosition),
      SpatialEvent.pinch(at: testPosition),
      SpatialEvent.drag(at: testPosition),
    ]

    let ids = Set(events.map(\.id))
    #expect(ids.count == 5, "All factory-created events should have unique IDs")
  }

  // MARK: - All Factories Set Default Score

  @Test("All interaction factories default score to 0")
  func allFactoriesDefaultScoreToZero() {
    let events = [
      SpatialEvent.touch(at: testPosition),
      SpatialEvent.move(at: testPosition),
      SpatialEvent.pinch(at: testPosition),
      SpatialEvent.drag(at: testPosition),
    ]

    for event in events {
      #expect(event.score == 0, "Factory event should have default score 0")
    }
  }

  // MARK: - Codable Round-Trip

  @Test("Factory-created events survive JSON encode/decode round-trip")
  func factoryEventsCodableRoundTrip() throws {
    let events = [
      SpatialEvent.gaze(at: testPosition),
      SpatialEvent.touch(at: testPosition),
      SpatialEvent.move(at: testPosition),
      SpatialEvent.pinch(at: testPosition),
      SpatialEvent.drag(at: testPosition),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for event in events {
      let data = try encoder.encode(event)
      let decoded = try decoder.decode(SpatialEvent.self, from: data)
      #expect(decoded == event, "Round-trip should preserve equality")
    }
  }
}
