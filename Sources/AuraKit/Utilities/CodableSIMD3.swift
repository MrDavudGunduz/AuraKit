// CodableSIMD3.swift
// AuraKit — Utilities
//
// Codable wrapper for SIMD3<Float>.
// Extracted into its own file so Phase 2 SIMD4 / quaternion wrappers
// live alongside this one without bloating SpatialEvent.swift.

import simd

// MARK: - CodableSIMD3

/// A `Codable` wrapper for `SIMD3<Float>`.
///
/// `SIMD3<Float>` does not conform to `Codable` in the standard library.
/// `CodableSIMD3` bridges this gap, enabling `SpatialEvent` to be serialised
/// to JSON, SwiftData, and CloudKit without manual encoding/decoding boilerplate
/// at every call site.
public struct CodableSIMD3: Sendable, Hashable, Codable {

  public let x: Float
  public let y: Float
  public let z: Float

  /// The underlying `SIMD3<Float>` value.
  public var simd3: SIMD3<Float> { SIMD3(x, y, z) }

  /// Creates a `CodableSIMD3` from a raw `SIMD3<Float>`.
  public init(_ value: SIMD3<Float>) {
    self.x = value.x
    self.y = value.y
    self.z = value.z
  }

  /// Creates a `CodableSIMD3` from individual float components.
  public init(x: Float, y: Float, z: Float) {
    self.x = x
    self.y = y
    self.z = z
  }
}

// MARK: - Common Constants

extension CodableSIMD3 {

  /// The world-space origin `(0, 0, 0)`.
  ///
  /// Convenience constant for the most common 3D position. Eliminates the
  /// boilerplate of wrapping `SIMD3<Float>(0, 0, 0)` at every call site.
  public static let zero = CodableSIMD3(SIMD3<Float>(0, 0, 0))
}
