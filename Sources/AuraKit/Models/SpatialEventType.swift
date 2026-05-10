// SpatialEventType.swift
// AuraKit — Models
//
// Persitable classification of spatial event subtypes for SwiftData storage.
// Extracted from SpatialEventKind to enable efficient, indexed queries
// on event type without deserializing the full encrypted payload.

import Foundation

// MARK: - SpatialEventType

/// A flat classification of spatial event types for SwiftData persistence.
///
/// Unlike ``SpatialEventKind``, which carries associated 3D positional data,
/// `SpatialEventType` is a simple `String`-backed enum suitable for:
/// - SwiftData `@Model` properties (indexed, filterable)
/// - CloudKit `CKRecord` field storage
/// - Survival Index calculations (event-type-weighted decay)
///
/// ## Mapping from SpatialEventKind
///
/// | `SpatialEventKind`            | `SpatialEventType` |
/// |-------------------------------|---------------------|
/// | `.gaze(position:)`            | `.gaze`             |
/// | `.interaction(type: .touch)`  | `.touch`            |
/// | `.interaction(type: .move)`   | `.move`             |
/// | `.interaction(type: .pinch)`  | `.pinch`            |
/// | `.interaction(type: .drag)`   | `.drag`             |
public enum SpatialEventType: String, Sendable, Hashable, Codable, CaseIterable {

  /// A passive gaze observation — low signal, queued for LLM evaluation.
  case gaze

  /// A direct tap or press — high signal, bypasses LLM.
  case touch

  /// Continuous positional movement — high signal, bypasses LLM.
  case move

  /// A pinch gesture — high signal, bypasses LLM.
  case pinch

  /// A drag gesture — high signal, bypasses LLM.
  case drag
}

// MARK: - SpatialEventKind → SpatialEventType Bridge

extension SpatialEventKind {

  /// Returns the flat ``SpatialEventType`` classification for this event kind.
  ///
  /// This property is used when persisting a `RawMemoryNode` to SwiftData,
  /// where the event type needs to be stored as a queryable, non-encrypted field
  /// alongside the encrypted payload.
  public var eventType: SpatialEventType {
    switch self {
    case .gaze:
      return .gaze
    case .interaction(let type, _):
      switch type {
      case .touch: return .touch
      case .move: return .move
      case .pinch: return .pinch
      case .drag: return .drag
      }
    }
  }
}
