// AuraError.swift
// AuraKit — Core Infrastructure
//
// Domain-specific error type for all AuraKit failure paths.
// Phase 1: notConfigured, invalidConfiguration
// Phase 2: encryptionFailed, decryptionFailed, secureEnclaveUnavailable, persistenceFailed

import Foundation

// MARK: - AuraError

/// Represents all failure conditions that can occur within the AuraKit pipeline.
///
/// Throw and catch `AuraError` values to distinguish AuraKit failures from
/// system errors. All cases carry enough context to construct a meaningful
/// error message without relying on external state.
///
/// ## Usage
///
/// ```swift
/// do {
///     let capture = try AuraKit.shared.capture()
///     await capture.record(event: event)
/// } catch AuraError.notConfigured {
///     // Call AuraKit.shared.configure(with:) at app launch first
/// } catch AuraError.invalidConfiguration(let reason) {
///     print("Bad config: \(reason)")
/// }
/// ```
public enum AuraError: Error, Sendable, Equatable {

  /// ``AuraKit/capture()`` was called before ``AuraKit/configure(with:)``.
  ///
  /// **Resolution:** Call `AuraKit.shared.configure(with:)` exactly once at app
  /// launch from a `@MainActor` context before accessing the capture pipeline.
  case notConfigured

  /// The supplied ``AuraConfiguration`` contains one or more invalid values.
  ///
  /// - Parameter reason: A human-readable description of why the configuration
  ///   is invalid (e.g., `"interactionWeight must be in [0.0, 1.0]"`).
  case invalidConfiguration(reason: String)

  // MARK: - Phase 2: Security & Persistence

  /// AES-GCM encryption of a spatial event payload failed.
  ///
  /// - Parameter reason: A diagnostic description of why the encryption operation
  ///   failed (e.g., CryptoKit internal error).
  case encryptionFailed(reason: String)

  /// AES-GCM decryption of a stored ciphertext payload failed.
  ///
  /// This may indicate a corrupted record, a wrong key, or a tampered
  /// authentication tag.
  ///
  /// - Parameter reason: A diagnostic description of the decryption failure.
  case decryptionFailed(reason: String)

  /// The Secure Enclave is unavailable or a key operation failed.
  ///
  /// On simulator builds this is expected — a software P256 fallback is used.
  /// On physical devices, this indicates a hardware or entitlement issue.
  ///
  /// - Parameter reason: A diagnostic description of the Secure Enclave failure.
  case secureEnclaveUnavailable(reason: String)

  /// A SwiftData persistence operation (insert, fetch, save) failed.
  ///
  /// - Parameter reason: A diagnostic description of the persistence failure.
  case persistenceFailed(reason: String)
}

// MARK: - LocalizedError

extension AuraError: LocalizedError {

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "[AuraKit] Not configured. Call `AuraKit.shared.configure(with:)` "
        + "from a @MainActor context (e.g., .task modifier on your root Scene) at app launch."
    case .invalidConfiguration(let reason):
      return "[AuraKit] Invalid configuration: \(reason)"
    case .encryptionFailed(let reason):
      return "[AuraKit] Encryption failed: \(reason)"
    case .decryptionFailed(let reason):
      return "[AuraKit] Decryption failed: \(reason)"
    case .secureEnclaveUnavailable(let reason):
      return "[AuraKit] Secure Enclave unavailable: \(reason)"
    case .persistenceFailed(let reason):
      return "[AuraKit] Persistence failed: \(reason)"
    }
  }
}

// MARK: - CustomNSError

extension AuraError: CustomNSError {

  /// The error domain used when bridging `AuraError` to `NSError`.
  public static var errorDomain: String { "com.aurakit.AuraError" }

  /// A stable integer code for each error case, suitable for equality checks
  /// in Objective-C and SwiftUI error handling.
  public var errorCode: Int {
    switch self {
    case .notConfigured: return 1_001
    case .invalidConfiguration: return 1_002
    case .encryptionFailed: return 1_003
    case .decryptionFailed: return 1_004
    case .secureEnclaveUnavailable: return 1_005
    case .persistenceFailed: return 1_006
    }
  }
}
