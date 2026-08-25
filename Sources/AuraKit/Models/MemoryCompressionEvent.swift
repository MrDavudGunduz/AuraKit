// MemoryCompressionEvent.swift
// AuraKit — Models
//
// Telemetry event emitted via AsyncStream during cognitive compression.
// Host applications can subscribe to these events for real-time monitoring
// of compression progress, feeding telemetry dashboards and alerting systems.

import Foundation

// MARK: - MemoryCompressionEvent

/// A telemetry event describing the current phase of a cognitive compression pass.
///
/// `MemoryCompressionEvent` is emitted through
/// ``IntelligenceActor/compressionEventStream`` at each stage of the
/// compression pipeline. Host applications can subscribe to this stream
/// for real-time monitoring without blocking the compression operation.
///
/// ## Usage
///
/// ```swift
/// Task {
///     let intelligence = ...
///     for await event in await intelligence.compressionEventStream {
///         analytics.track("aurakit.compression", properties: [
///             "phase": event.phase.rawValue,
///             "detail": event.detail,
///         ])
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// `MemoryCompressionEvent` is a fully immutable value type conforming to
/// `Sendable`, safe to pass across actor boundaries.
public struct MemoryCompressionEvent: Sendable, Equatable {

  // MARK: - Phase

  /// The discrete phases of a cognitive compression operation.
  ///
  /// Phases are emitted in the following order during a successful compression:
  ///
  /// ```
  /// started → nodesSelected → summaryGenerated → archiveCreated
  ///         → sourceNodesDeleted → completed
  /// ```
  ///
  /// On failure, `failed` is emitted instead of `completed`.
  public enum Phase: String, Sendable, Equatable {

    /// Compression operation has begun.
    case started

    /// Low-SI nodes have been identified and selected for compression.
    case nodesSelected

    /// The LLM has generated a semantic summary of the selected nodes.
    case summaryGenerated

    /// A ``MemoryArchiveNode`` has been created with the encrypted summary.
    case archiveCreated

    /// Source ``RawMemoryNode`` records have been deleted.
    case sourceNodesDeleted

    /// Compression completed successfully.
    case completed

    /// Compression failed at some stage.
    case failed
  }

  // MARK: - Properties

  /// The current phase of the compression operation.
  public let phase: Phase

  /// The wall-clock time at which this phase was reached.
  public let timestamp: Date

  /// A human-readable diagnostic detail about this phase.
  ///
  /// Examples:
  /// - `"Selected 1,000 nodes below SI threshold 0.15"`
  /// - `"Summary: User inspected the southeast exhibit case..."`
  /// - `"Compression failed: Encryption service unavailable"`
  public let detail: String

  // MARK: - Init

  /// Creates a new compression event.
  ///
  /// - Parameters:
  ///   - phase: The compression phase.
  ///   - detail: A human-readable diagnostic detail.
  ///   - timestamp: The time of the event. Defaults to `Date()`.
  public init(
    phase: Phase,
    detail: String,
    timestamp: Date = Date()
  ) {
    self.phase = phase
    self.detail = detail
    self.timestamp = timestamp
  }
}
