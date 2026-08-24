// StoreMetrics.swift
// AuraKit — Core Infrastructure
//
// Extracted from EncryptedMemoryStore.swift for SwiftLint file_length compliance.
// Provides an immutable, Sendable snapshot of store observability counters
// for production telemetry and cross-actor diagnostics.

import Foundation

// MARK: - StoreMetrics

/// An immutable, `Sendable` snapshot of ``EncryptedMemoryStore`` observability
/// counters captured at a single point in time.
///
/// Designed for production telemetry — pass this across actor boundaries
/// without holding a reference to the store itself.
public struct StoreMetrics: Sendable, Equatable {

  /// Total number of events successfully encrypted and persisted.
  public let totalEventsWritten: Int

  /// Total number of events that failed to persist (key, encryption, or save failure).
  public let droppedEventCount: Int

  /// Total number of individual node decryption failures.
  public let decryptionFailureCount: Int

  /// Number of events currently held in the retry queue awaiting re-attempt.
  ///
  /// A persistently non-zero value indicates ongoing transient failures
  /// (e.g., Secure Enclave unavailability, disk I/O contention).
  public let retryQueueCount: Int

  /// The write success rate as a percentage `[0.0, 100.0]`.
  ///
  /// Returns `100.0` when no events have been processed (no failures, no writes).
  public var writeSuccessRate: Double {
    let total = totalEventsWritten + droppedEventCount
    guard total > 0 else { return 100.0 }
    return (Double(totalEventsWritten) / Double(total)) * 100.0
  }
}
