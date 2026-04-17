// SpatialEvent.swift
// AuraKit — Models
//
// Canonical 3D spatial event model and its associated kinds.
// `CodableSIMD3` lives in Utilities/CodableSIMD3.swift.
// All types are Sendable, Hashable, and Codable for Swift 6 strict
// concurrency and Phase 2 SwiftData/CloudKit persistence.

import Foundation
import simd

// MARK: - InteractionType

/// Classifies the physical interaction gesture that produced a spatial event.
///
/// All cases represent high-signal user intent and bypass LLM inference,
/// routing directly to persistent memory with a maximum score of `1.0`.
public enum InteractionType: String, Sendable, Hashable, Codable {
  /// A direct tap or press at a 3D position.
  case touch
  /// Continuous positional movement of the user's hand or pointer.
  case move
  /// A pinch gesture (thumb + index finger closure).
  case pinch
  /// A drag gesture — press followed by movement.
  case drag
}

// MARK: - SpatialEventKind

/// Discriminates between passive observation (gaze) and active interaction events.
///
/// The `HeuristicRouter` uses this distinction to determine the routing path
/// for each event:
/// - **Gaze** → L1 `RingBuffer` (low-signal, queued for optional LLM processing)
/// - **Interaction** → Direct persistent memory write (high-signal, score `1.0`)
public enum SpatialEventKind: Sendable, Hashable, Codable {

  /// A passive gaze event reporting the user's 3D focal point in world space.
  ///
  /// - Parameter position: The world-space position the user is looking at.
  case gaze(position: CodableSIMD3)

  /// An intentional interaction gesture at a specific 3D world-space position.
  ///
  /// - Parameters:
  ///   - type: The kind of interaction gesture performed.
  ///   - position: The world-space position of the interaction.
  case interaction(type: InteractionType, position: CodableSIMD3)

  // MARK: Codable

  private enum CodingKeys: String, CodingKey {
    case kind, position, interactionType
  }

  private enum KindTag: String, Codable {
    case gaze, interaction
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(KindTag.self, forKey: .kind)
    switch tag {
    case .gaze:
      let position = try container.decode(CodableSIMD3.self, forKey: .position)
      self = .gaze(position: position)
    case .interaction:
      let interactionType = try container.decode(InteractionType.self, forKey: .interactionType)
      let position = try container.decode(CodableSIMD3.self, forKey: .position)
      self = .interaction(type: interactionType, position: position)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .gaze(let position):
      try container.encode(KindTag.gaze, forKey: .kind)
      try container.encode(position, forKey: .position)
    case .interaction(let type, let position):
      try container.encode(KindTag.interaction, forKey: .kind)
      try container.encode(type, forKey: .interactionType)
      try container.encode(position, forKey: .position)
    }
  }
}

// MARK: - SpatialEvent

/// A single captured 3D spatial event emitted by the device's sensor pipeline.
///
/// `SpatialEvent` is the atomic unit of data flowing through AuraKit's capture
/// pipeline. The `score` field is computed by ``HeuristicRouter`` at ingestion
/// time and reflects the event's relative importance:
///
/// | Kind         | Score            |
/// |--------------|------------------|
/// | `.gaze`      | `gazeWeight` (configurable, default `0.3`) |
/// | `.interaction` | `1.0` (fixed maximum) |
///
/// ## Thread Safety
///
/// `SpatialEvent` is a fully immutable value type and conforms to `Sendable`,
/// making it safe to pass across actor boundaries without copying overhead
/// beyond the inherent value semantics.
///
/// ## Persistence
///
/// `SpatialEvent` is `Codable`, enabling direct serialisation to JSON,
/// SwiftData (`@Attribute(.externalStorage)` blobs), and CloudKit records
/// in Phase 2.
public struct SpatialEvent: Identifiable, Sendable, Hashable, Codable {

  // MARK: Properties

  /// A unique identifier for this event, suitable for deduplication.
  public let id: UUID

  /// The wall-clock timestamp at which the sensor produced this event.
  public let timestamp: Date

  /// The classification and spatial data for this event.
  public let kind: SpatialEventKind

  /// Heuristic importance score in the range `[0.0, 1.0]`.
  ///
  /// Assigned by ``HeuristicRouter``; higher values indicate stronger user intent.
  public let score: Float

  // MARK: Init

  /// Creates a new spatial event with an automatically generated UUID.
  ///
  /// - Parameters:
  ///   - id: Defaults to a new `UUID()` if not provided.
  ///   - timestamp: Defaults to `Date()` (now) if not provided.
  ///   - kind: The event classification and spatial payload.
  ///   - score: The heuristic score assigned by the router.
  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    kind: SpatialEventKind,
    score: Float
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.score = score
  }
}

// MARK: - Convenience factories (raw SIMD3<Float> → CodableSIMD3)

extension SpatialEventKind {

  /// Convenience factory: creates a `.gaze` kind from a raw `SIMD3<Float>`.
  ///
  /// The `rawPosition` label is intentionally distinct from the enum case's
  /// `position` label (which takes a `CodableSIMD3`) to eliminate autocomplete
  /// ambiguity and compiler overload confusion.
  ///
  /// - Parameter rawPosition: The world-space gaze focal point in raw SIMD form.
  public static func gaze(rawPosition: SIMD3<Float>) -> SpatialEventKind {
    .gaze(position: CodableSIMD3(rawPosition))
  }

  /// Convenience factory: creates an `.interaction` kind from a raw `SIMD3<Float>`.
  ///
  /// - Parameters:
  ///   - type: The kind of interaction gesture.
  ///   - rawPosition: The world-space position of the interaction in raw SIMD form.
  public static func interaction(
    type: InteractionType,
    rawPosition: SIMD3<Float>
  ) -> SpatialEventKind {
    .interaction(type: type, position: CodableSIMD3(rawPosition))
  }
}
