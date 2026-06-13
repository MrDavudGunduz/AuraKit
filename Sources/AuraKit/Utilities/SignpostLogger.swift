// SignpostLogger.swift
// AuraKit — Utilities
//
// Centralised OSSignpost instrumentation for AuraKit's performance-critical paths.
// Provides named signpost intervals that surface in Instruments → Time Profiler,
// enabling production-grade performance telemetry without third-party dependencies.

import Foundation
import os.log
import os.signpost

// MARK: - SignpostLogger

/// Centralised signpost instrumentation for AuraKit's performance-critical paths.
///
/// `SignpostLogger` wraps `os.signpost` to provide named performance intervals
/// that are visible in **Instruments → Time Profiler** and **os_signpost** views.
///
/// ## Supported Intervals
///
/// | Interval         | Location                      | Purpose                        |
/// |------------------|-------------------------------|--------------------------------|
/// | `encrypt`        | `EncryptedMemoryStore.append` | Single-event encrypt + persist |
/// | `batchEncrypt`   | `EncryptedMemoryStore.batch`  | Batch encrypt + single save    |
/// | `decrypt`        | `+Decryption.decryptNodes`    | Full-table or batch decrypt    |
/// | `keyDerivation`  | `KeyManager.deriveKey`        | ECDH + HKDF key derivation     |
///
/// ## Thread Safety
///
/// `SignpostLogger` is a stateless `enum` with `static` methods — fully `Sendable`
/// and safe to call from any actor or task without synchronisation.
///
/// ## Zero-Cost in Release
///
/// `os_signpost` calls are compiled away by the system when no profiling session
/// is attached. There is **zero runtime overhead** in production when Instruments
/// is not recording.
public enum SignpostLogger {

  // MARK: - Signpost Log

  /// The `OSLog` instance used for all AuraKit signpost intervals.
  ///
  /// The subsystem matches AuraKit's unified logging subsystem for consistent
  /// filtering in Console.app and Instruments.
  private static let log = OSLog(
    subsystem: "com.aurakit.framework",
    category: .pointsOfInterest
  )

  // MARK: - Encrypt

  /// Marks the beginning of a single-event encryption interval.
  ///
  /// - Returns: An `OSSignpostID` to pass to ``endEncrypt(_:)``.
  public static func beginEncrypt() -> OSSignpostID {
    let signpostID = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "Encrypt", signpostID: signpostID)
    return signpostID
  }

  /// Marks the end of a single-event encryption interval.
  ///
  /// - Parameter signpostID: The ID returned by ``beginEncrypt()``.
  public static func endEncrypt(_ signpostID: OSSignpostID) {
    os_signpost(.end, log: log, name: "Encrypt", signpostID: signpostID)
  }

  // MARK: - Batch Encrypt

  /// Marks the beginning of a batch encryption interval.
  ///
  /// - Parameter count: The number of events in the batch (included as metadata).
  /// - Returns: An `OSSignpostID` to pass to ``endBatchEncrypt(_:)``.
  public static func beginBatchEncrypt(count: Int) -> OSSignpostID {
    let signpostID = OSSignpostID(log: log)
    os_signpost(
      .begin, log: log, name: "BatchEncrypt", signpostID: signpostID,
      "count=%d", count
    )
    return signpostID
  }

  /// Marks the end of a batch encryption interval.
  ///
  /// - Parameter signpostID: The ID returned by ``beginBatchEncrypt(count:)``.
  public static func endBatchEncrypt(_ signpostID: OSSignpostID) {
    os_signpost(.end, log: log, name: "BatchEncrypt", signpostID: signpostID)
  }

  // MARK: - Decrypt

  /// Marks the beginning of a decrypt interval.
  ///
  /// - Parameter count: The number of nodes to decrypt (included as metadata).
  /// - Returns: An `OSSignpostID` to pass to ``endDecrypt(_:)``.
  public static func beginDecrypt(count: Int) -> OSSignpostID {
    let signpostID = OSSignpostID(log: log)
    os_signpost(
      .begin, log: log, name: "Decrypt", signpostID: signpostID,
      "count=%d", count
    )
    return signpostID
  }

  /// Marks the end of a decrypt interval.
  ///
  /// - Parameter signpostID: The ID returned by ``beginDecrypt(count:)``.
  public static func endDecrypt(_ signpostID: OSSignpostID) {
    os_signpost(.end, log: log, name: "Decrypt", signpostID: signpostID)
  }

  // MARK: - Key Derivation

  /// Marks the beginning of a key derivation interval.
  ///
  /// - Returns: An `OSSignpostID` to pass to ``endKeyDerivation(_:)``.
  public static func beginKeyDerivation() -> OSSignpostID {
    let signpostID = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "KeyDerivation", signpostID: signpostID)
    return signpostID
  }

  /// Marks the end of a key derivation interval.
  ///
  /// - Parameter signpostID: The ID returned by ``beginKeyDerivation()``.
  public static func endKeyDerivation(_ signpostID: OSSignpostID) {
    os_signpost(.end, log: log, name: "KeyDerivation", signpostID: signpostID)
  }
}
