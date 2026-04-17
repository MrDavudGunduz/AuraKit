// TestHelpers.swift
// AuraKitTests — Shared test fixture factories
//
// Centralises SpatialEvent construction so all test suites share a single
// source of truth. If SpatialEvent's initialiser ever changes, only this
// file needs updating.

import Foundation
import simd

@testable import AuraKit

// MARK: - SpatialEvent Factories

extension SpatialEvent {

  /// A gaze event at the world-space origin with the supplied score.
  static func gazeFixture(score: Float = 0.3) -> SpatialEvent {
    SpatialEvent(kind: .gaze(position: .zero), score: score)
  }

  /// A touch interaction event at the world-space origin with the supplied score.
  static func touchFixture(score: Float = 1.0) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: score)
  }

  /// A move interaction event at the world-space origin with the supplied score.
  static func moveFixture(score: Float = 1.0) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .move, position: .zero), score: score)
  }

  /// A pinch interaction event at a given position with the supplied score.
  static func pinchFixture(
    position: CodableSIMD3 = .zero,
    score: Float = 1.0
  ) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .pinch, position: position), score: score)
  }

  /// A drag interaction event at a given position with the supplied score.
  static func dragFixture(
    position: CodableSIMD3 = .zero,
    score: Float = 1.0
  ) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .drag, position: position), score: score)
  }
}

// MARK: - CodableSIMD3 Convenience

extension CodableSIMD3 {
  /// World-space origin `(0, 0, 0)`.
  static let zero = CodableSIMD3(SIMD3<Float>(0, 0, 0))

  /// Convenience for a named spatial position in tests.
  static func make(_ x: Float, _ y: Float, _ z: Float) -> CodableSIMD3 {
    CodableSIMD3(SIMD3<Float>(x, y, z))
  }
}

// MARK: - Configuration Factories

extension AuraConfiguration {

  /// A configuration with a small buffer — useful for overflow/capacity tests.
  static func smallBuffer(capacity: Int = 8) throws -> AuraConfiguration {
    try AuraConfiguration(bufferCapacity: capacity)
  }
}
