// AuraConfiguration.swift
// AuraKit — Configuration
//
// Developer-facing dependency injection entry point. Configure once at app launch
// via `AuraKit.shared.configure(with:)`.

import Foundation

// MARK: - Sub-Configurations

/// Configuration for the capture pipeline and L1 buffer.
public struct CaptureConfiguration: Sendable, Equatable {
  public let interactionWeight: Double
  public let gazeWeight: Double
  public let bufferCapacity: Int

  public init(interactionWeight: Double, gazeWeight: Double, bufferCapacity: Int) throws {
    guard (0.0...1.0).contains(interactionWeight) else {
      throw AuraError.invalidConfiguration(reason: "interactionWeight \(interactionWeight) is outside [0.0, 1.0]")
    }
    guard (0.0...1.0).contains(gazeWeight) else {
      throw AuraError.invalidConfiguration(reason: "gazeWeight \(gazeWeight) is outside [0.0, 1.0]")
    }
    guard bufferCapacity > 0 else {
      throw AuraError.invalidConfiguration(reason: "bufferCapacity must be > 0, got \(bufferCapacity)")
    }
    self.interactionWeight = interactionWeight
    self.gazeWeight = gazeWeight
    self.bufferCapacity = bufferCapacity
  }

  internal init(uncheckedInteractionWeight: Double, gazeWeight: Double, bufferCapacity: Int) {
    self.interactionWeight = uncheckedInteractionWeight
    self.gazeWeight = gazeWeight
    self.bufferCapacity = bufferCapacity
  }
}

/// Configuration for the AES-GCM encrypted persistence layer.
public struct StorageConfiguration: Sendable, Equatable {
  public let capacity: Int
  public let streamBatchSize: Int
  public let largeDatasetWarningThreshold: Int
  public let saveThreshold: Int
  public let retryQueueCapacity: Int
  public let retryDrainInterval: TimeInterval

  public init(capacity: Int, streamBatchSize: Int, largeDatasetWarningThreshold: Int, saveThreshold: Int, retryQueueCapacity: Int, retryDrainInterval: TimeInterval = 30.0) throws {
    guard capacity >= 0 else {
      throw AuraError.invalidConfiguration(reason: "storeCapacity must be >= 0, got \(capacity)")
    }
    guard streamBatchSize > 0 else {
      throw AuraError.invalidConfiguration(reason: "streamBatchSize must be > 0, got \(streamBatchSize)")
    }
    guard largeDatasetWarningThreshold >= 0 else {
      throw AuraError.invalidConfiguration(reason: "largeDatasetWarningThreshold must be >= 0, got \(largeDatasetWarningThreshold)")
    }
    guard saveThreshold > 0 else {
      throw AuraError.invalidConfiguration(reason: "saveThreshold must be > 0, got \(saveThreshold)")
    }
    guard retryQueueCapacity >= 0 else {
      throw AuraError.invalidConfiguration(reason: "retryQueueCapacity must be >= 0, got \(retryQueueCapacity)")
    }
    guard retryDrainInterval >= 0 else {
      throw AuraError.invalidConfiguration(reason: "retryDrainInterval must be >= 0, got \(retryDrainInterval)")
    }
    self.capacity = capacity
    self.streamBatchSize = streamBatchSize
    self.largeDatasetWarningThreshold = largeDatasetWarningThreshold
    self.saveThreshold = saveThreshold
    self.retryQueueCapacity = retryQueueCapacity
    self.retryDrainInterval = retryDrainInterval
  }

  internal init(uncheckedCapacity: Int, streamBatchSize: Int, largeDatasetWarningThreshold: Int, saveThreshold: Int, retryQueueCapacity: Int, retryDrainInterval: TimeInterval = 30.0) {
    self.capacity = uncheckedCapacity
    self.streamBatchSize = streamBatchSize
    self.largeDatasetWarningThreshold = largeDatasetWarningThreshold
    self.saveThreshold = saveThreshold
    self.retryQueueCapacity = retryQueueCapacity
    self.retryDrainInterval = retryDrainInterval
  }
}

/// Configuration for the MLX Intelligence and Semantic Pruning layer.
public struct IntelligenceConfiguration: Sendable, Equatable {
  public let decayConstant: Double
  public let recallMultiplier: Double
  public let survivalIndexThreshold: Double

  public init(decayConstant: Double, recallMultiplier: Double, survivalIndexThreshold: Double) throws {
    guard decayConstant >= 0.0 else {
      throw AuraError.invalidConfiguration(reason: "decayConstant must be >= 0.0, got \(decayConstant)")
    }
    guard recallMultiplier >= 1.0 else {
      throw AuraError.invalidConfiguration(reason: "recallMultiplier must be >= 1.0, got \(recallMultiplier)")
    }
    guard (0.0...1.0).contains(survivalIndexThreshold) else {
      throw AuraError.invalidConfiguration(reason: "survivalIndexThreshold \(survivalIndexThreshold) is outside [0.0, 1.0]")
    }
    self.decayConstant = decayConstant
    self.recallMultiplier = recallMultiplier
    self.survivalIndexThreshold = survivalIndexThreshold
  }

  internal init(uncheckedDecayConstant: Double, recallMultiplier: Double, survivalIndexThreshold: Double) {
    self.decayConstant = uncheckedDecayConstant
    self.recallMultiplier = recallMultiplier
    self.survivalIndexThreshold = survivalIndexThreshold
  }
}

// MARK: - AuraConfiguration

/// The primary configuration object for AuraKit's capture pipeline.
///
/// Inject a configured instance at app launch to control routing weights,
/// buffer sizing, and future feature flags. `AuraConfiguration` is a
/// pure value type — copy freely across actor boundaries.
///
/// ## Example
///
/// ```swift
/// let captureConfig = try CaptureConfiguration(interactionWeight: 1.0, gazeWeight: 0.3, bufferCapacity: 512)
/// let storageConfig = try StorageConfiguration(capacity: 10_000, streamBatchSize: 100, largeDatasetWarningThreshold: 1_000, saveThreshold: 10, retryQueueCapacity: 10)
/// let intelligenceConfig = try IntelligenceConfiguration(decayConstant: 0.0001, recallMultiplier: 1.2, survivalIndexThreshold: 0.15)
/// let config = AuraConfiguration(capture: captureConfig, storage: storageConfig, intelligence: intelligenceConfig)
/// try await AuraKit.shared.configure(with: config)
/// ```
public struct AuraConfiguration: Sendable, Equatable {

  // MARK: - Constants

  public static let defaultInteractionWeight: Double = 1.0
  public static let defaultGazeWeight: Double = 0.3
  public static let defaultBufferCapacity: Int = 512
  public static let defaultStoreCapacity: Int = 10_000
  public static let defaultStreamBatchSize: Int = 100
  public static let defaultLargeDatasetWarningThreshold: Int = AuraKitConstants.defaultLargeDatasetWarningThreshold
  public static let defaultSaveThreshold: Int = 10
  public static let defaultRetryQueueCapacity: Int = 10
  public static let defaultRetryDrainInterval: TimeInterval = 30.0
  public static let defaultDecayConstant: Double = 0.0001
  public static let defaultRecallMultiplier: Double = 1.2
  public static let defaultSurvivalIndexThreshold: Double = 0.15

  // MARK: - Grouped Configurations
  
  /// Configuration for the capture pipeline and L1 buffer.
  public let capture: CaptureConfiguration
  
  /// Configuration for the AES-GCM encrypted persistence layer.
  public let storage: StorageConfiguration
  
  /// Configuration for the MLX Intelligence and Semantic Pruning layer.
  public let intelligence: IntelligenceConfiguration

  // MARK: - Deprecated Properties

  @available(*, deprecated, message: "Use capture.interactionWeight instead.")
  public var interactionWeight: Double { capture.interactionWeight }
  
  @available(*, deprecated, message: "Use capture.gazeWeight instead.")
  public var gazeWeight: Double { capture.gazeWeight }

  @available(*, deprecated, message: "Use capture.bufferCapacity instead.")
  public var bufferCapacity: Int { capture.bufferCapacity }

  @available(*, deprecated, message: "Use storage.capacity instead.")
  public var storeCapacity: Int { storage.capacity }
  
  @available(*, deprecated, message: "Use storage.streamBatchSize instead.")
  public var streamBatchSize: Int { storage.streamBatchSize }
  
  @available(*, deprecated, message: "Use storage.largeDatasetWarningThreshold instead.")
  public var largeDatasetWarningThreshold: Int { storage.largeDatasetWarningThreshold }
  
  @available(*, deprecated, message: "Use storage.saveThreshold instead.")
  public var saveThreshold: Int { storage.saveThreshold }
  
  @available(*, deprecated, message: "Use storage.retryQueueCapacity instead.")
  public var retryQueueCapacity: Int { storage.retryQueueCapacity }
  
  @available(*, deprecated, message: "Use intelligence.decayConstant instead.")
  public var decayConstant: Double { intelligence.decayConstant }
  
  @available(*, deprecated, message: "Use intelligence.recallMultiplier instead.")
  public var recallMultiplier: Double { intelligence.recallMultiplier }
  
  @available(*, deprecated, message: "Use intelligence.survivalIndexThreshold instead.")
  public var survivalIndexThreshold: Double { intelligence.survivalIndexThreshold }

  // MARK: - Init
  
  public init(
    capture: CaptureConfiguration,
    storage: StorageConfiguration,
    intelligence: IntelligenceConfiguration
  ) {
    self.capture = capture
    self.storage = storage
    self.intelligence = intelligence
  }

  @available(*, deprecated, message: "Use the initialiser taking CaptureConfiguration, StorageConfiguration, and IntelligenceConfiguration instead.")
  public init(
    interactionWeight: Double = defaultInteractionWeight,
    gazeWeight: Double = defaultGazeWeight,
    bufferCapacity: Int = defaultBufferCapacity,
    storeCapacity: Int = defaultStoreCapacity,
    streamBatchSize: Int = defaultStreamBatchSize,
    largeDatasetWarningThreshold: Int = defaultLargeDatasetWarningThreshold,
    saveThreshold: Int = defaultSaveThreshold,
    retryQueueCapacity: Int = defaultRetryQueueCapacity,
    decayConstant: Double = defaultDecayConstant,
    recallMultiplier: Double = defaultRecallMultiplier,
    survivalIndexThreshold: Double = defaultSurvivalIndexThreshold
  ) throws {
    self.capture = try CaptureConfiguration(
      interactionWeight: interactionWeight,
      gazeWeight: gazeWeight,
      bufferCapacity: bufferCapacity
    )
    self.storage = try StorageConfiguration(
      capacity: storeCapacity,
      streamBatchSize: streamBatchSize,
      largeDatasetWarningThreshold: largeDatasetWarningThreshold,
      saveThreshold: saveThreshold,
      retryQueueCapacity: retryQueueCapacity
    )
    self.intelligence = try IntelligenceConfiguration(
      decayConstant: decayConstant,
      recallMultiplier: recallMultiplier,
      survivalIndexThreshold: survivalIndexThreshold
    )
  }

  internal init(
    uncheckedCapture: CaptureConfiguration,
    uncheckedStorage: StorageConfiguration,
    uncheckedIntelligence: IntelligenceConfiguration
  ) {
    self.capture = uncheckedCapture
    self.storage = uncheckedStorage
    self.intelligence = uncheckedIntelligence
  }
}

// MARK: - Default Configuration

extension AuraConfiguration {
  public static let `default` = AuraConfiguration(
    uncheckedCapture: CaptureConfiguration(
      uncheckedInteractionWeight: defaultInteractionWeight,
      gazeWeight: defaultGazeWeight,
      bufferCapacity: defaultBufferCapacity
    ),
    uncheckedStorage: StorageConfiguration(
      uncheckedCapacity: defaultStoreCapacity,
      streamBatchSize: defaultStreamBatchSize,
      largeDatasetWarningThreshold: defaultLargeDatasetWarningThreshold,
      saveThreshold: defaultSaveThreshold,
      retryQueueCapacity: defaultRetryQueueCapacity
    ),
    uncheckedIntelligence: IntelligenceConfiguration(
      uncheckedDecayConstant: defaultDecayConstant,
      recallMultiplier: defaultRecallMultiplier,
      survivalIndexThreshold: defaultSurvivalIndexThreshold
    )
  )
}
