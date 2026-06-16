// AuraKitConstants.swift
// AuraKit — Utilities
//
// Centralised constant definitions for framework-wide identifiers.
// Eliminates hardcoded string repetition across Logger, SignpostLogger,
// KeychainHelper, and other components — single source of truth.

import Foundation

// MARK: - AuraKitConstants

/// Framework-wide constant definitions.
///
/// `AuraKitConstants` provides a single source of truth for identifiers
/// that are referenced across multiple components — primarily the unified
/// logging subsystem string and Keychain service identifiers.
///
/// ## Motivation
///
/// Prior to this centralisation, the subsystem string `"com.aurakit.framework"`
/// was duplicated in 8 separate files. A typo in any one of them would silently
/// break Console.app filtering without any compiler diagnostic. By routing all
/// references through this enum, the compiler guarantees consistency.
///
/// ## Thread Safety
///
/// `AuraKitConstants` is a caseless `enum` with only `static let` properties —
/// fully `Sendable` and safe to access from any concurrency context.
public enum AuraKitConstants {

  /// The unified logging subsystem identifier for all AuraKit components.
  ///
  /// Used by `os.log.Logger`, `OSLog` (signposts), and any future
  /// telemetry integrations. Matches the reverse-DNS convention
  /// recommended by Apple's Unified Logging documentation.
  ///
  /// Filter in Console.app: `subsystem:com.aurakit.framework`
  public static let subsystem = "com.aurakit.framework"

  /// Default threshold at which ``EncryptedMemoryStore/allEvents()`` emits
  /// a runtime warning about potential memory pressure from full-table
  /// decryption. When the store contains more nodes than this value,
  /// a `Logger.warning` is emitted recommending paginated or streaming
  /// alternatives.
  ///
  /// Override via ``AuraConfiguration/largeDatasetWarningThreshold``.
  public static let defaultLargeDatasetWarningThreshold: Int = 1_000
}
