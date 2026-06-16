// DroppedEvent.swift
// AuraKit — Models
//
// Notification payload for events that failed to persist in the
// EncryptedMemoryStore pipeline. Host applications can subscribe
// to these notifications via `EncryptedMemoryStore.droppedEventStream`
// for production telemetry and alerting.

import Foundation

// MARK: - DroppedEvent

/// A notification payload describing a ``SpatialEvent`` that failed to persist.
///
/// `DroppedEvent` is emitted through ``EncryptedMemoryStore/droppedEventStream``
/// whenever an event is silently dropped due to key retrieval failure, encryption
/// failure, or SwiftData save failure.
///
/// ## Usage
///
/// ```swift
/// Task {
///     for await drop in store.droppedEventStream {
///         analytics.track("aurakit.event_dropped", properties: [
///             "event_id": drop.eventID.uuidString,
///             "reason": drop.reason
///         ])
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// `DroppedEvent` is a fully immutable value type conforming to `Sendable`,
/// safe to pass across actor boundaries.
public struct DroppedEvent: Sendable, Equatable {

  /// The UUID of the event that was dropped, if available.
  ///
  /// May be `nil` when the drop occurs before individual event processing
  /// (e.g., a batch-level key retrieval failure where individual UUIDs
  /// are not yet resolved).
  public let eventID: UUID?

  /// A human-readable diagnostic description of why the event was dropped.
  ///
  /// Examples:
  /// - `"Encryption failed: CryptoKit error"`
  /// - `"Key retrieval failed: Secure Enclave unavailable"`
  /// - `"Context save failed: SQLite constraint violation"`
  public let reason: String

  /// The wall-clock time at which the drop was detected.
  public let timestamp: Date

  /// Creates a new `DroppedEvent` notification.
  ///
  /// - Parameters:
  ///   - eventID: The UUID of the dropped event, or `nil` for batch-level failures.
  ///   - reason: A diagnostic description of the failure.
  ///   - timestamp: The time of the drop. Defaults to `Date()`.
  public init(
    eventID: UUID? = nil,
    reason: String,
    timestamp: Date = Date()
  ) {
    self.eventID = eventID
    self.reason = reason
    self.timestamp = timestamp
  }
}
