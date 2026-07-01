// TestHelpers.swift
// AuraKitTests — Shared test fixture factories
//
// Centralises SpatialEvent construction and EncryptedMemoryStore setup
// so all test suites share a single source of truth. If any initialiser
// ever changes, only this file needs updating.

import CryptoKit
import Foundation
import simd
import SwiftData

@testable import AuraKit

// MARK: - SpatialEvent Factories

extension SpatialEvent {

  /// A gaze event at the world-space origin with the supplied score.
  static func gazeFixture(score: Double = 0.3) -> SpatialEvent {
    SpatialEvent(kind: .gaze(position: .zero), score: score)
  }

  /// A touch interaction event at the world-space origin with the supplied score.
  static func touchFixture(score: Double = 1.0) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .touch, position: .zero), score: score)
  }

  /// A move interaction event at the world-space origin with the supplied score.
  static func moveFixture(score: Double = 1.0) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .move, position: .zero), score: score)
  }

  /// A pinch interaction event at a given position with the supplied score.
  static func pinchFixture(
    position: CodableSIMD3 = .zero,
    score: Double = 1.0
  ) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .pinch, position: position), score: score)
  }

  /// A drag interaction event at a given position with the supplied score.
  static func dragFixture(
    position: CodableSIMD3 = .zero,
    score: Double = 1.0
  ) -> SpatialEvent {
    SpatialEvent(kind: .interaction(type: .drag, position: position), score: score)
  }
}

// MARK: - CodableSIMD3 Convenience

extension CodableSIMD3 {

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

// MARK: - EncryptedMemoryStore Test Factory

/// Shared 256-bit test key for all `EncryptedMemoryStore` test suites.
///
/// Using a single shared key across suites eliminates key-generation
/// duplication and ensures all test stores use a consistent encryption
/// context. Each test still creates a fresh in-memory container, so
/// there is no state leakage between tests.
let sharedTestKey = SymmetricKey(size: .bits256)

/// Creates an ``EncryptedMemoryStore`` backed by an in-memory container
/// and the shared test key.
///
/// This factory centralises the setup boilerplate that was previously
/// duplicated across `EncryptedMemoryStoreTests`, `ZeroTrustTests`,
/// and `Phase2HardeningTests`.
func makeTestEncryptedStore(
  key: SymmetricKey = sharedTestKey,
  saveThreshold: Int = 1
) throws -> EncryptedMemoryStore {
  let container = try PersistenceController.makeInMemoryContainer()
  return EncryptedMemoryStore(
    container: container,
    keyManager: KeyManager(staticKey: key),
    saveThreshold: saveThreshold
  )
}
