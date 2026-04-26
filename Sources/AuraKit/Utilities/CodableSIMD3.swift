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

  // swiftlint:disable identifier_name
  public let x: Float
  public let y: Float
  public let z: Float
  // swiftlint:enable identifier_name

  /// The underlying `SIMD3<Float>` value.
  public var simd3: SIMD3<Float> { SIMD3(x, y, z) }

  /// Creates a `CodableSIMD3` from a raw `SIMD3<Float>`.
  public init(_ value: SIMD3<Float>) {
    self.x = value.x
    self.y = value.y
    self.z = value.z
  }

  /// Creates a `CodableSIMD3` from individual float components.
  ///
  /// Convenience initialiser that eliminates the need to construct a
  /// `SIMD3<Float>` intermediate at call sites.
  // swiftlint:disable identifier_name
  public init(x: Float, y: Float, z: Float) {
    self.x = x
    self.y = y
    self.z = z
  }
  // swiftlint:enable identifier_name
}
