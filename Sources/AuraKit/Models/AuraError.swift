// AuraError.swift
// AuraKit — Phase 1: Core Infrastructure
//
// Domain-specific error type for all AuraKit failure paths.

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
    }
  }
}
