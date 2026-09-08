// MetalSearchConfiguration.swift
// AuraKit — Configuration
//
// Configuration for the Metal GPU-accelerated cosine similarity search engine.
// Decomposed into two domain-specific sub-configurations:
//
//   VectorConfiguration         — embedding dimensions and capacity
//   ComputeDispatchConfiguration — GPU threadgroup and dispatch parameters
//
// MetalSearchConfiguration composes both into a single, validated entry point
// following the same pattern as AuraConfiguration's sub-configuration design.

import Foundation

// MARK: - Sub-Configurations

/// Configuration for the embedding vector space used by ``MetalSearchEngine``.
///
/// Controls the dimensionality and capacity constraints of the vector database
/// that is uploaded to GPU memory for cosine similarity search.
///
/// ## Dimension Selection
///
/// The default of `384` is chosen for compatibility with Apple's
/// `NaturalLanguage` framework embedding output and common sentence
/// transformer models (e.g., `all-MiniLM-L6-v2`). All vectors uploaded
/// to ``MetalSearchEngine`` must match this dimension exactly.
///
/// ## Thread Safety
///
/// Fully immutable `Sendable` value type — safe to share across actors.
public struct VectorConfiguration: Sendable, Equatable {

  /// Default embedding vector dimension (compatible with NaturalLanguage framework).
  public static let defaultDimension: Int = 384

  /// Default maximum number of vectors per search dispatch.
  public static let defaultMaxCount: Int = 10_000

  /// The number of floats in each embedding vector.
  ///
  /// All query and memory vectors must have exactly this many dimensions.
  /// Mismatched dimensions will produce incorrect similarity scores.
  public let dimension: Int

  /// The maximum number of memory vectors that can be searched in a single dispatch.
  ///
  /// This controls the size of the `MTLBuffer` allocation for memory vectors.
  /// Exceeding this count will cause the search to truncate gracefully.
  public let maxCount: Int

  /// Creates a vector configuration with validated parameters.
  ///
  /// - Parameters:
  ///   - dimension: Floats per embedding vector. Must be > 0. Default: `384`.
  ///   - maxCount: Maximum vectors per search. Must be > 0. Default: `10_000`.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter is invalid.
  public init(
    dimension: Int = defaultDimension,
    maxCount: Int = defaultMaxCount
  ) throws {
    guard dimension > 0 else {
      throw AuraError.invalidConfiguration(
        reason: "vectorDimension must be > 0, got \(dimension)"
      )
    }
    guard maxCount > 0 else {
      throw AuraError.invalidConfiguration(
        reason: "maxVectorCount must be > 0, got \(maxCount)"
      )
    }
    self.dimension = dimension
    self.maxCount = maxCount
  }

  /// Internal unchecked initialiser for default configuration construction.
  internal init(uncheckedDimension: Int, maxCount: Int) {
    self.dimension = uncheckedDimension
    self.maxCount = maxCount
  }
}

/// Configuration for the Metal GPU compute dispatch used by ``MetalSearchEngine``.
///
/// Controls how the cosine similarity kernel is dispatched to the GPU,
/// including the threadgroup size that determines parallelism granularity.
///
/// ## Threadgroup Sizing
///
/// The `threadgroupSize` must be a power of 2 and must not exceed the
/// device's `maxTotalThreadsPerThreadgroup`. The default of `256` is
/// optimal for Apple Silicon GPUs (A14+). Reducing this value may be
/// necessary for older or lower-tier GPUs.
///
/// ## Thread Safety
///
/// Fully immutable `Sendable` value type — safe to share across actors.
public struct ComputeDispatchConfiguration: Sendable, Equatable {

  /// Default threads per threadgroup for Metal compute dispatch.
  public static let defaultThreadgroupSize: Int = 256

  /// The number of threads per threadgroup in the Metal compute dispatch.
  ///
  /// Must be a power of 2 and not exceed the device's `maxTotalThreadsPerThreadgroup`.
  /// The default of `256` is optimal for Apple Silicon GPUs (A14+).
  public let threadgroupSize: Int

  /// Creates a compute dispatch configuration with validated parameters.
  ///
  /// - Parameter threadgroupSize: Threads per threadgroup. Must be > 0. Default: `256`.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if the parameter is invalid.
  public init(threadgroupSize: Int = defaultThreadgroupSize) throws {
    guard threadgroupSize > 0 else {
      throw AuraError.invalidConfiguration(
        reason: "threadgroupSize must be > 0, got \(threadgroupSize)"
      )
    }
    self.threadgroupSize = threadgroupSize
  }

  /// Internal unchecked initialiser for default configuration construction.
  internal init(uncheckedThreadgroupSize: Int) {
    self.threadgroupSize = uncheckedThreadgroupSize
  }
}

// MARK: - MetalSearchConfiguration

/// The primary configuration object for AuraKit's Metal GPU-accelerated
/// cosine similarity search.
///
/// `MetalSearchConfiguration` composes two domain-specific sub-configurations:
///
/// | Sub-Configuration | Responsibility |
/// |-------------------|----------------|
/// | ``VectorConfiguration`` | Embedding dimensions and vector capacity |
/// | ``ComputeDispatchConfiguration`` | GPU threadgroup and dispatch parameters |
///
/// ## Example
///
/// ```swift
/// // Use the convenience flat initialiser
/// let config = try MetalSearchConfiguration(
///     vectorDimension: 384,
///     maxVectorCount: 10_000,
///     threadgroupSize: 256
/// )
///
/// // Or compose from sub-configurations
/// let vectorConfig = try VectorConfiguration(dimension: 768, maxCount: 50_000)
/// let dispatchConfig = try ComputeDispatchConfiguration(threadgroupSize: 512)
/// let config = MetalSearchConfiguration(vector: vectorConfig, dispatch: dispatchConfig)
/// ```
///
/// ## Thread Safety
///
/// `MetalSearchConfiguration` is a fully immutable `Sendable` value type.
public struct MetalSearchConfiguration: Sendable, Equatable {

  // MARK: - Constants (Backward Compatibility)

  /// Default embedding vector dimension (compatible with NaturalLanguage framework).
  public static let defaultVectorDimension: Int = VectorConfiguration.defaultDimension

  /// Default maximum number of vectors per search dispatch.
  public static let defaultMaxVectorCount: Int = VectorConfiguration.defaultMaxCount

  /// Default threads per threadgroup for Metal compute dispatch.
  public static let defaultThreadgroupSize: Int = ComputeDispatchConfiguration.defaultThreadgroupSize

  // MARK: - Grouped Configurations

  /// Configuration for the embedding vector space.
  public let vector: VectorConfiguration

  /// Configuration for GPU compute dispatch.
  public let dispatch: ComputeDispatchConfiguration

  // MARK: - Convenience Accessors

  /// The number of floats in each embedding vector.
  ///
  /// Convenience accessor delegating to ``VectorConfiguration/dimension``.
  public var vectorDimension: Int { vector.dimension }

  /// The maximum number of memory vectors per search dispatch.
  ///
  /// Convenience accessor delegating to ``VectorConfiguration/maxCount``.
  public var maxVectorCount: Int { vector.maxCount }

  /// The number of threads per threadgroup in the Metal compute dispatch.
  ///
  /// Convenience accessor delegating to ``ComputeDispatchConfiguration/threadgroupSize``.
  public var threadgroupSize: Int { dispatch.threadgroupSize }

  // MARK: - Grouped Init

  /// Creates a Metal search configuration from sub-configurations.
  ///
  /// - Parameters:
  ///   - vector: Embedding vector configuration.
  ///   - dispatch: GPU compute dispatch configuration.
  public init(
    vector: VectorConfiguration,
    dispatch: ComputeDispatchConfiguration
  ) {
    self.vector = vector
    self.dispatch = dispatch
  }

  // MARK: - Flat Init (Convenience)

  /// Creates a Metal search configuration with individually validated parameters.
  ///
  /// This is a convenience initialiser that constructs the sub-configurations
  /// internally, matching the call-site ergonomics of the original flat API.
  ///
  /// - Parameters:
  ///   - vectorDimension: Floats per embedding vector. Must be > 0. Default: `384`.
  ///   - maxVectorCount: Maximum vectors per search. Must be > 0. Default: `10_000`.
  ///   - threadgroupSize: Threads per threadgroup. Must be > 0. Default: `256`.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter is invalid.
  public init(
    vectorDimension: Int = defaultVectorDimension,
    maxVectorCount: Int = defaultMaxVectorCount,
    threadgroupSize: Int = defaultThreadgroupSize
  ) throws {
    self.vector = try VectorConfiguration(
      dimension: vectorDimension,
      maxCount: maxVectorCount
    )
    self.dispatch = try ComputeDispatchConfiguration(
      threadgroupSize: threadgroupSize
    )
  }

  /// Internal unchecked initialiser for default configuration construction.
  internal init(
    uncheckedVector: VectorConfiguration,
    uncheckedDispatch: ComputeDispatchConfiguration
  ) {
    self.vector = uncheckedVector
    self.dispatch = uncheckedDispatch
  }
}

// MARK: - Default Configuration

extension MetalSearchConfiguration {

  /// The default Metal search configuration.
  ///
  /// Uses 384-dimensional vectors, a maximum of 10,000 vectors per search,
  /// and 256 threads per threadgroup.
  public static let `default` = MetalSearchConfiguration(
    uncheckedVector: VectorConfiguration(
      uncheckedDimension: VectorConfiguration.defaultDimension,
      maxCount: VectorConfiguration.defaultMaxCount
    ),
    uncheckedDispatch: ComputeDispatchConfiguration(
      uncheckedThreadgroupSize: ComputeDispatchConfiguration.defaultThreadgroupSize
    )
  )
}
