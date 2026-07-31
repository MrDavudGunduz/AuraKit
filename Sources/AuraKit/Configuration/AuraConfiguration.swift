// AuraConfiguration.swift
// AuraKit — Configuration
//
// Developer-facing dependency injection entry point. Configure once at app launch
// via `AuraKit.shared.configure(with:)`.

import Foundation

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
/// let config = AuraConfiguration(
///     interactionWeight: 1.0,  // Touch/Move: max score, bypasses LLM
///     gazeWeight: 0.3,         // Gaze: low-weight, queued in L1 Buffer
///     bufferCapacity: 512
/// )
/// try await AuraKit.shared.configure(with: config)
/// ```
///
/// ## Weight Semantics
///
/// | Weight | Range | Effect |
/// |--------|-------|--------|
/// | `interactionWeight` | `0.0 – 1.0` | Score assigned to `.interaction` events. At `1.0`, events bypass the ring buffer and write directly to persistent memory. |
/// | `gazeWeight` | `0.0 – 1.0` | Score assigned to `.gaze` events. Lower values deprioritise gaze relative to interaction. |
///
/// > Note: `interactionWeight` defaults to `1.0` and the routing implementation
/// > treats it as a fixed maximum — setting it lower than `1.0` affects the
/// > recorded score only, not routing behaviour (interactions always bypass L1).
public struct AuraConfiguration: Sendable, Equatable {

  // MARK: - Constants

  /// Default weight applied to `.interaction` events (touch, move, pinch, drag).
  public static let defaultInteractionWeight: Double = 1.0

  /// Default weight applied to `.gaze` events.
  public static let defaultGazeWeight: Double = 0.3

  /// Default L1 ring buffer capacity in number of events.
  public static let defaultBufferCapacity: Int = 512

  /// Default maximum number of events the `MemoryStore` will hold.
  ///
  /// When this limit is reached the oldest events are evicted first (FIFO).
  /// Set to `0` to disable the cap (unbounded — not recommended in production).
  public static let defaultStoreCapacity: Int = 10_000

  /// Default number of nodes fetched per batch during encrypted streaming.
  ///
  /// Empirically tuned: 100 nodes × ~2 KB average ciphertext ≈ 200 KB peak
  /// per batch — well within comfortable memory budgets on all Apple platforms.
  /// Smaller values reduce peak memory; larger values reduce fetch overhead.
  public static let defaultStreamBatchSize: Int = 100

  /// Default threshold for emitting runtime warnings when ``EncryptedMemoryStore/allEvents()``
  /// or ``EncryptedMemoryStore/recallAndFetchAll()`` is called on a store containing more
  /// than this many nodes.
  ///
  /// Set to `0` to disable the warning entirely.
  public static let defaultLargeDatasetWarningThreshold: Int = AuraKitConstants.defaultLargeDatasetWarningThreshold

  /// Default number of `append()` calls before ``EncryptedMemoryStore`` issues
  /// a `ModelContext.save()` to persist pending inserts.
  ///
  /// Write coalescing amortises SQLite I/O across multiple inserts. At 60fps
  /// sensor input, a threshold of `10` reduces save calls from 60/sec to 6/sec
  /// — a 10× reduction in disk I/O with minimal data loss window.
  ///
  /// Set to `1` to disable coalescing (save on every append — legacy behaviour).
  public static let defaultSaveThreshold: Int = 10

  /// Default maximum number of events that ``EncryptedMemoryStore`` will hold
  /// in its retry queue when `append()` encounters a transient failure.
  ///
  /// Events in the retry queue are re-attempted on the next successful `append()`
  /// or when ``EncryptedMemoryStore/flushRetryQueue()`` is called explicitly.
  /// When the queue is at capacity, the oldest queued event is permanently dropped.
  ///
  /// Set to `0` to disable retry entirely (legacy behaviour — immediate drop).
  public static let defaultRetryQueueCapacity: Int = 10

  /// Default decay constant (λ) per second used in the Survival Index formula SI(t) = S₀ · Rⁿ · e^(-λt).
  public static let defaultDecayConstant: Double = 0.0001

  /// Default recall multiplier (R) used in the Survival Index formula SI(t) = S₀ · Rⁿ · e^(-λt).
  public static let defaultRecallMultiplier: Double = 1.2

  /// Default Survival Index score threshold below which memories are pruned or archived.
  public static let defaultSurvivalIndexThreshold: Double = 0.15

  // MARK: - Properties

  /// Heuristic importance weight for high-signal interaction events.
  ///
  /// Must be in the range `[0.0, 1.0]`. Validated at configuration time.
  public let interactionWeight: Double

  /// Heuristic importance weight for low-signal passive gaze events.
  ///
  /// Must be in the range `[0.0, 1.0]`. Validated at configuration time.
  public let gazeWeight: Double

  /// The fixed capacity of the L1 `RingBuffer`.
  ///
  /// Must be a positive integer. Setting this too low may cause high gaze
  /// event loss under rapid movement; the recommended minimum is `128`.
  public let bufferCapacity: Int

  /// Maximum number of high-signal events the ``MemoryStore`` will retain.
  ///
  /// When the store reaches this limit the oldest event is evicted before
  /// each new write (FIFO ring semantics). Defaults to `10_000`.
  /// Set to `0` to disable eviction (unbounded growth — not recommended for
  /// long-running visionOS sessions).
  public let storeCapacity: Int

  /// Number of nodes fetched per internal batch during
  /// ``EncryptedMemoryStore/eventStream(limit:offset:batchSize:)``.
  ///
  /// Must be a positive integer. Smaller values reduce peak memory usage;
  /// larger values reduce the number of SwiftData fetch round-trips.
  /// Defaults to `100`.
  public let streamBatchSize: Int

  /// Node count threshold at which ``EncryptedMemoryStore/allEvents()``
  /// emits a runtime `Logger.warning` about potential memory pressure.
  ///
  /// When the store contains more nodes than this value, a diagnostic
  /// warning is logged recommending ``EncryptedMemoryStore/events(limit:offset:)``
  /// or ``EncryptedMemoryStore/eventStream(limit:offset:batchSize:)`` instead.
  ///
  /// Set to `0` to disable the warning. Defaults to `1_000`.
  public let largeDatasetWarningThreshold: Int

  /// Number of `append()` calls before ``EncryptedMemoryStore`` persists
  /// pending inserts to disk via `ModelContext.save()`.
  ///
  /// Write coalescing batches multiple inserts into a single save, reducing
  /// SQLite write amplification on high-frequency capture paths. The pending
  /// inserts are always flushed on ``EncryptedMemoryStore/flushPendingWrites()``,
  /// ``batchAppend(_:)``, or pipeline shutdown.
  ///
  /// Must be a positive integer. Set to `1` to save on every append (disables
  /// coalescing). Defaults to `10`.
  public let saveThreshold: Int

  /// Maximum number of events held in ``EncryptedMemoryStore``'s retry queue.
  ///
  /// When `append()` encounters a transient failure (key retrieval, encryption,
  /// or save error), the event is placed in a retry queue instead of being
  /// permanently dropped. Queued events are retried on the next `append()`.
  ///
  /// Set to `0` to disable retry (immediate drop on failure — legacy behaviour).
  /// Defaults to `10`.
  public let retryQueueCapacity: Int

  /// Exponential decay constant (λ) per second for Survival Index scoring.
  public let decayConstant: Double

  /// Recall multiplier (R) applied each time a memory node is queried.
  public let recallMultiplier: Double

  /// Threshold below which nodes are pruned during Survival Index evaluation.
  public let survivalIndexThreshold: Double

  // MARK: - Init

  /// Creates a validated `AuraConfiguration`, throwing if any parameter is out of range.
  ///
  /// - Parameters:
  ///   - interactionWeight: Score for interaction events. Default `1.0`.
  ///   - gazeWeight: Score for gaze events. Default `0.3`.
  ///   - bufferCapacity: L1 ring buffer capacity. Default `512`.
  ///   - storeCapacity: Max events in the persistent `MemoryStore`. Default `10_000`.
  ///     Pass `0` to disable the cap (unbounded).
  ///   - streamBatchSize: Nodes per batch in streaming decryption. Default `100`.
  ///   - decayConstant: Decay rate (λ) per second for Survival Index calculation. Default `0.0001`.
  ///   - recallMultiplier: Multiplier (R) for recall counts. Default `1.2`.
  ///   - survivalIndexThreshold: Score threshold below which nodes are pruned. Default `0.15`.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter
  ///   is out of its valid range.
  // swiftlint:disable:next function_body_length cyclomatic_complexity
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
    guard (0.0...1.0).contains(interactionWeight) else {
      throw AuraError.invalidConfiguration(
        reason: "interactionWeight \(interactionWeight) is outside [0.0, 1.0]"
      )
    }
    guard (0.0...1.0).contains(gazeWeight) else {
      throw AuraError.invalidConfiguration(
        reason: "gazeWeight \(gazeWeight) is outside [0.0, 1.0]"
      )
    }
    guard bufferCapacity > 0 else {
      throw AuraError.invalidConfiguration(
        reason: "bufferCapacity must be > 0, got \(bufferCapacity)"
      )
    }
    guard storeCapacity >= 0 else {
      throw AuraError.invalidConfiguration(
        reason: "storeCapacity must be >= 0, got \(storeCapacity)"
      )
    }
    guard streamBatchSize > 0 else {
      throw AuraError.invalidConfiguration(
        reason: "streamBatchSize must be > 0, got \(streamBatchSize)"
      )
    }
    guard largeDatasetWarningThreshold >= 0 else {
      throw AuraError.invalidConfiguration(
        reason: "largeDatasetWarningThreshold must be >= 0, got \(largeDatasetWarningThreshold)"
      )
    }
    guard saveThreshold > 0 else {
      throw AuraError.invalidConfiguration(
        reason: "saveThreshold must be > 0, got \(saveThreshold)"
      )
    }
    guard retryQueueCapacity >= 0 else {
      throw AuraError.invalidConfiguration(
        reason: "retryQueueCapacity must be >= 0, got \(retryQueueCapacity)"
      )
    }
    guard decayConstant >= 0.0 else {
      throw AuraError.invalidConfiguration(
        reason: "decayConstant must be >= 0.0, got \(decayConstant)"
      )
    }
    guard recallMultiplier >= 1.0 else {
      throw AuraError.invalidConfiguration(
        reason: "recallMultiplier must be >= 1.0, got \(recallMultiplier)"
      )
    }
    guard (0.0...1.0).contains(survivalIndexThreshold) else {
      throw AuraError.invalidConfiguration(
        reason: "survivalIndexThreshold \(survivalIndexThreshold) is outside [0.0, 1.0]"
      )
    }
    self.interactionWeight = interactionWeight
    self.gazeWeight = gazeWeight
    self.bufferCapacity = bufferCapacity
    self.storeCapacity = storeCapacity
    self.streamBatchSize = streamBatchSize
    self.largeDatasetWarningThreshold = largeDatasetWarningThreshold
    self.saveThreshold = saveThreshold
    self.retryQueueCapacity = retryQueueCapacity
    self.decayConstant = decayConstant
    self.recallMultiplier = recallMultiplier
    self.survivalIndexThreshold = survivalIndexThreshold
  }

  /// Private unchecked initialiser for known-valid constant values only.
  /// Bypasses validation to avoid `try!` or force-unwrap at call sites
  /// where correctness is guaranteed by the compiler (e.g., `AuraConfiguration.default`).
  private init(
    uncheckedInteractionWeight interactionWeight: Double,
    gazeWeight: Double,
    bufferCapacity: Int,
    storeCapacity: Int,
    streamBatchSize: Int,
    largeDatasetWarningThreshold: Int,
    saveThreshold: Int,
    retryQueueCapacity: Int,
    decayConstant: Double,
    recallMultiplier: Double,
    survivalIndexThreshold: Double
  ) {
    self.interactionWeight = interactionWeight
    self.gazeWeight = gazeWeight
    self.bufferCapacity = bufferCapacity
    self.storeCapacity = storeCapacity
    self.streamBatchSize = streamBatchSize
    self.largeDatasetWarningThreshold = largeDatasetWarningThreshold
    self.saveThreshold = saveThreshold
    self.retryQueueCapacity = retryQueueCapacity
    self.decayConstant = decayConstant
    self.recallMultiplier = recallMultiplier
    self.survivalIndexThreshold = survivalIndexThreshold
  }
}

// MARK: - Default Configuration

extension AuraConfiguration {

  /// A ready-to-use configuration with recommended production defaults.
  ///
  /// - `interactionWeight`: `1.0`
  /// - `gazeWeight`: `0.3`
  /// - `bufferCapacity`: `512`
  /// - `storeCapacity`: `10_000`
  /// - `streamBatchSize`: `100`
  /// - `largeDatasetWarningThreshold`: `1_000`
  /// - `saveThreshold`: `10`
  /// - `decayConstant`: `0.0001`
  /// - `recallMultiplier`: `1.2`
  /// - `survivalIndexThreshold`: `0.15`
  public static let `default` = AuraConfiguration(
    uncheckedInteractionWeight: defaultInteractionWeight,
    gazeWeight: defaultGazeWeight,
    bufferCapacity: defaultBufferCapacity,
    storeCapacity: defaultStoreCapacity,
    streamBatchSize: defaultStreamBatchSize,
    largeDatasetWarningThreshold: defaultLargeDatasetWarningThreshold,
    saveThreshold: defaultSaveThreshold,
    retryQueueCapacity: defaultRetryQueueCapacity,
    decayConstant: defaultDecayConstant,
    recallMultiplier: defaultRecallMultiplier,
    survivalIndexThreshold: defaultSurvivalIndexThreshold
  )
}
