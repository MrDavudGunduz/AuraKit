// CompressionReport.swift
// AuraKit — Models
//
// Immutable result type returned by the cognitive compression API.
// Contains metrics about the compression operation including node counts,
// bytes recovered, and the LLM-generated semantic summary.

import Foundation

// MARK: - CompressionReport

/// An immutable, `Sendable` report describing the outcome of a cognitive
/// compression operation triggered by ``MemoryManager/compressIdleMemories()``.
///
/// `CompressionReport` provides the host application with actionable telemetry
/// about each compression pass:
///
/// ```swift
/// let report = try await AuraKit.shared.memory.compressIdleMemories()
/// logger.info("""
///     Compressed \(report.nodesPruned) nodes → \(report.archiveNodesCreated) archive(s).
///     Recovered \(report.bytesRecovered) bytes.
///     Summary: \(report.summary)
/// """)
/// ```
///
/// ## Thread Safety
///
/// `CompressionReport` is a fully immutable value type conforming to `Sendable`.
/// It can be passed across actor boundaries without copying overhead beyond
/// inherent value semantics.
public struct CompressionReport: Sendable, Equatable {

  // MARK: - Properties

  /// The number of ``RawMemoryNode`` records that were pruned (deleted)
  /// during compression.
  ///
  /// This equals the number of source nodes whose Survival Index fell
  /// below the configured threshold.
  public let nodesPruned: Int

  /// The number of ``MemoryArchiveNode`` records created during compression.
  ///
  /// Typically `1` per compression pass (all qualifying nodes → one archive),
  /// or `0` if no nodes qualified for compression.
  public let archiveNodesCreated: Int

  /// The total number of encrypted payload bytes recovered by deleting
  /// the pruned ``RawMemoryNode`` records.
  ///
  /// This is an estimate based on the `encryptedPayload.count` of the
  /// deleted nodes — actual SQLite page reclamation may differ due to
  /// page-level allocation and WAL journaling.
  public let bytesRecovered: Int64

  /// The LLM-generated natural-language summary of the compressed events.
  ///
  /// Empty string when no nodes qualified for compression.
  ///
  /// ## Example
  ///
  /// > "User inspected the southeast exhibit case twice then moved toward the exit."
  public let summary: String

  /// The UUID of the ``MemoryArchiveNode`` created during compression,
  /// or `nil` if no archive was created (zero qualifying nodes).
  public let archiveNodeID: UUID?

  /// The wall-clock duration of the compression operation.
  public let duration: Duration

  // MARK: - Convenience

  /// Whether the compression pass actually compressed any nodes.
  ///
  /// Returns `false` when no nodes qualified for compression (i.e., all
  /// nodes had Survival Index scores above the threshold).
  public var didCompress: Bool {
    nodesPruned > 0
  }

  /// An empty compression report indicating no nodes qualified for compression.
  public static let empty = CompressionReport(
    nodesPruned: 0,
    archiveNodesCreated: 0,
    bytesRecovered: 0,
    summary: "",
    archiveNodeID: nil,
    duration: .zero
  )
}
