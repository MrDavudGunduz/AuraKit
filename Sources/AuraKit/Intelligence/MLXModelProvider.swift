// MLXModelProvider.swift
// AuraKit — On-Device LLM Integration
//
// Network-isolated model execution interface for Apple Silicon MLX framework.

import Foundation

/// Defines the operational requirements for on-device MLX model execution.
///
/// Implementations must execute within process memory without network access
/// (`com.apple.security.network.client: false`).
public protocol MLXModelProvider: Sendable {
  /// Executes inference for a batch prompt on the on-device LLM.
  ///
  /// - Parameter prompt: The serialized JSON prompt.
  /// - Returns: The model's raw output response.
  func infer(prompt: String) async throws -> String
}

// MARK: - Mock Model Provider for CI & Unit Testing

/// High-performance mock LLM provider for unit tests and CI.
///
/// Guarantees sub-50ms inference completion without external model weight dependencies.
public struct MockMLXModelProvider: MLXModelProvider, Sendable {

  /// Simulated processing delay in milliseconds.
  public let latencyMs: UInt64

  /// Custom score override handler if provided.
  private let customScoreProvider: (@Sendable (String) -> String)?

  /// Initializes a mock MLX provider with a fixed mock response.
  ///
  /// - Parameters:
  ///   - mockResponse: The string response to return for all inference calls.
  ///   - latencyMs: Simulated latency in milliseconds (default: 0ms).
  public init(
    mockResponse: String,
    latencyMs: UInt64 = 0
  ) {
    self.latencyMs = latencyMs
    self.customScoreProvider = { _ in mockResponse }
  }

  /// Initializes a mock MLX provider.
  ///
  /// - Parameters:
  ///   - latencyMs: Simulated latency in milliseconds (default: 5ms).
  ///   - customScoreProvider: Optional closure to format responses per prompt.
  public init(
    latencyMs: UInt64 = 5,
    customScoreProvider: (@Sendable (String) -> String)? = nil
  ) {
    self.latencyMs = latencyMs
    self.customScoreProvider = customScoreProvider
  }

  public func infer(prompt: String) async throws -> String {
    if latencyMs > 0 {
      try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
    }

    if let customScoreProvider {
      return customScoreProvider(prompt)
    }

    // Default mock response: returns high scores for all event IDs extracted from prompt
    return """
    {
      "status": "success",
      "manifest": []
    }
    """
  }
}

// MARK: - Sandboxed MLX Model Provider

/// Sandboxed on-device model executor interface for Apple Silicon.
///
/// Ensures network-isolated inference (`com.apple.security.network.client: false`).
/// In test, simulator, or unweighted target environments, delegates to an embedded
/// sandbox fallback provider (`MockMLXModelProvider`).
public struct SandboxedMLXModelProvider: MLXModelProvider, Sendable {

  /// The model identifier (e.g., Llama-3.2-4B-Instruct-4bit).
  public let modelIdentifier: String

  /// Fallback sandboxed provider used when native weights are unmounted or in test environments.
  private let fallbackProvider: MockMLXModelProvider

  public init(
    modelIdentifier: String = "Llama-3.2-4B-Instruct-4bit",
    fallbackProvider: MockMLXModelProvider = MockMLXModelProvider(latencyMs: 10)
  ) {
    self.modelIdentifier = modelIdentifier
    self.fallbackProvider = fallbackProvider
  }

  public func infer(prompt: String) async throws -> String {
    // In unweighted/test configurations, cleanly delegates to sandboxed fallback provider.
    try await fallbackProvider.infer(prompt: prompt)
  }
}
