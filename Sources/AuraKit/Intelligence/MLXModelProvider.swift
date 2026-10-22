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
  /// Whether this provider performs real model inference whose output may be
  /// trusted for **destructive** operations (e.g. cognitive compression, which
  /// deletes source nodes after archiving the model's summary, or
  /// ``IntelligenceActor/processAndPrune(_:referenceDate:)``).
  ///
  /// Defaults to `false` (**fail-closed**): a provider must explicitly opt in
  /// by returning `true`. Placeholder providers (such as
  /// ``SandboxedMLXModelProvider`` today) keep the default, which makes
  /// destructive APIs refuse to run instead of replacing or deleting user
  /// memories based on meaningless output.
  ///
  /// ```swift
  /// struct MyMLXProvider: MLXModelProvider {
  ///     var isProductionInferenceBackend: Bool { true }
  ///     func infer(prompt: String) async throws -> String { ... }
  /// }
  /// ```
  var isProductionInferenceBackend: Bool { get }

  /// Executes inference for a batch prompt on the on-device LLM.
  ///
  /// - Parameter prompt: The serialized JSON prompt.
  /// - Returns: The model's raw output response.
  func infer(prompt: String) async throws -> String
}

extension MLXModelProvider {
  /// Fail-closed default — see ``MLXModelProvider/isProductionInferenceBackend``.
  public var isProductionInferenceBackend: Bool { false }
}

// MARK: - Mock Model Provider for CI & Unit Testing

/// High-performance mock LLM provider for unit tests and CI.
///
/// Guarantees sub-50ms inference completion without external model weight dependencies.
public struct MockMLXModelProvider: MLXModelProvider, Sendable {

  /// Simulated processing delay in milliseconds.
  public let latencyMs: UInt64

  /// Whether destructive operations may trust this mock's output.
  ///
  /// `false` by default so a mock can never accidentally delete real data;
  /// tests that exercise compression/pruning opt in explicitly.
  public let trustedForDestructiveOperations: Bool

  /// Mirrors ``trustedForDestructiveOperations``.
  public var isProductionInferenceBackend: Bool { trustedForDestructiveOperations }

  /// Custom score override handler if provided.
  private let customScoreProvider: (@Sendable (String) -> String)?

  /// Initializes a mock MLX provider with a fixed mock response.
  ///
  /// - Parameters:
  ///   - mockResponse: The string response to return for all inference calls.
  ///   - latencyMs: Simulated latency in milliseconds (default: 0ms).
  ///   - trustedForDestructiveOperations: Allow destructive operations (tests only).
  public init(
    mockResponse: String,
    latencyMs: UInt64 = 0,
    trustedForDestructiveOperations: Bool = false
  ) {
    self.latencyMs = latencyMs
    self.trustedForDestructiveOperations = trustedForDestructiveOperations
    self.customScoreProvider = { _ in mockResponse }
  }

  /// Initializes a mock MLX provider.
  ///
  /// - Parameters:
  ///   - latencyMs: Simulated latency in milliseconds (default: 5ms).
  ///   - trustedForDestructiveOperations: Allow destructive operations (tests only).
  ///   - customScoreProvider: Optional closure to format responses per prompt.
  public init(
    latencyMs: UInt64 = 5,
    trustedForDestructiveOperations: Bool = false,
    customScoreProvider: (@Sendable (String) -> String)? = nil
  ) {
    self.latencyMs = latencyMs
    self.trustedForDestructiveOperations = trustedForDestructiveOperations
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
/// - Warning: **This does not run MLX inference yet.** `infer(prompt:)` unconditionally
///   delegates to ``fallbackProvider`` (a ``MockMLXModelProvider``). There is no
///   `mlx-swift` dependency and no code path that loads a real model. Supply your own
///   ``MLXModelProvider`` conformance or wait for `mlx-swift` integration (see ROADMAP.md).
///   Because of this, ``isProductionInferenceBackend`` is `false` and destructive
///   operations such as ``IntelligenceActor/compressIdleMemories(referenceDate:)`` refuse to run.
public struct SandboxedMLXModelProvider: MLXModelProvider, Sendable {

  /// Always `false`: this provider delegates to a mock and runs no real model.
  public var isProductionInferenceBackend: Bool { false }

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
