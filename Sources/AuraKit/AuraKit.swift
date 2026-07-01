// AuraKit.swift
// AuraKit — On-device, cryptographically secured spatial memory framework.
// https://github.com/MrDavudGunduz/AuraKit

import Foundation
import os.log

// # AuraKit
//
// AuraKit is a **fully open-source Swift Package** (MIT) that provides iOS, macOS, and visionOS
// applications with a persistent, privacy-first spatial memory layer.
//
// ## Overview
//
// AuraKit ingests 3D spatial events (gaze, touch, movement) through a Swift 6
// Actor-isolated pipeline, scores them using a heuristic bypass engine, and stores
// them in an on-device AES-GCM encrypted SwiftData store — with no data ever
// leaving the user's device.
//
// Future phases will extend this foundation with:
// - On-device LLM semantic pruning via Apple MLX
// - Survival Index scoring for intelligent memory longevity
// - Semantic consolidation (cognitive compression)
// - GPU-accelerated cosine similarity search via Metal
//
// ## Quick Start
//
// Configure AuraKit once at app launch from a `@MainActor` context. The simplest
// approach is `App.body` or a `Task { @MainActor in }` block:
//
// ```swift
// import AuraKit
//
// @main
// struct MyApp: App {
//     var body: some Scene {
//         WindowGroup { ContentView() }
//             .task {
//                 // .task modifier runs on @MainActor — safe for configure()
//                 let config = try AuraConfiguration(
//                     interactionWeight: 1.0, // Touch/Move: max score, bypasses LLM
//                     gazeWeight: 0.3,        // Gaze: low-weight, queued in L1 Buffer
//                     bufferCapacity: 512
//                 )
//                 AuraKit.shared.configure(with: config)
//             }
//     }
// }
// ```
//
// Record a spatial event using the convenience factory:
//
// ```swift
// try await AuraKit.shared.capture().record(
//     event: SpatialEvent(
//         kind: .gaze(rawPosition: SIMD3(0.1, 0.9, -1.0)),
//         score: 0  // Overwritten by HeuristicRouter at record time
//     )
// )
// ```
//
// ## Concurrency
//
// `AuraKit.shared` and `configure(with:)` are `@MainActor`-isolated.
// Call them from the main actor context — `App.body`, a `.task` modifier,
// or an explicit `Task { @MainActor in ... }` block.
// Calling them from a background task without the correct actor context
// will produce a compile-time error in Swift 6 strict concurrency mode.
//
// ## Architecture
//
// ```
// CaptureActor → IntelligenceActor → MemoryActor → Metal Search
// ```
//
// For complete architecture documentation, see
// [ARCHITECTURE.md](https://github.com/MrDavudGunduz/AuraKit/blob/main/ARCHITECTURE.md).
//
// ## Topics
//
// ### Configuration
// - ``AuraConfiguration``
//
// ### Capture
// - ``CaptureActor``
// - ``SpatialEvent``
// - ``SpatialEventKind``
// - ``InteractionType``
// - ``RingBuffer``
//
// ### Routing
// - ``HeuristicRouter``
// - ``RouteDecision``
//
// ### Storage
// - ``SpatialEventStore``
// - ``MemoryStore``
// - ``EncryptedMemoryStore``
//
// ### Persistence
// - ``RawMemoryNode``
// - ``MemoryArchiveNode``
// - ``PersistenceController``
// - ``SpatialEventType``
// - ``AuraKitSchemaV2``
// - ``AuraKitMigrationPlan``
//
// ### Security
// - ``KeyManager``
// - ``EncryptionService``
//
// ### Errors
// - ``AuraError``

// MARK: - AuraKit

/// The singleton entry point for the AuraKit framework.
///
/// `AuraKit` must be configured once at app launch before any capture operations
/// can be performed. All subsequent access is through the ``capture()``
/// method, which is actor-isolated.
///
/// ## Concurrency
///
/// `AuraKit` is `@MainActor`-isolated. Configure it from a `@MainActor` context —
/// for example, inside a `.task` modifier on your root scene, or inside
/// `Task { @MainActor in }` if you need to configure from a non-isolated context.
///
/// ```swift
/// // ✅ Correct — .task runs on @MainActor
/// WindowGroup { ... }
///     .task { AuraKit.shared.configure(with: config) }
///
/// // ✅ Correct — explicit @MainActor Task
/// Task { @MainActor in AuraKit.shared.configure(with: config) }
///
/// // ❌ Wrong — background Task without @MainActor annotation
/// Task { AuraKit.shared.configure(with: config) }  // compile error in Swift 6
/// ```
@MainActor
public final class AuraKit {

  // MARK: - Internal Logger

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "AuraKit"
  )

  // MARK: - Singleton

  /// The shared, process-wide AuraKit instance.
  ///
  /// Use this to configure and access the capture pipeline.
  /// - Warning: Accessing ``capture()`` before calling ``configure(with:)``
  ///   throws ``AuraError/notConfigured``.
  public static let shared = AuraKit()

  // MARK: - Versioning

  /// The current version of the AuraKit framework.
  ///
  /// Follows [Semantic Versioning](https://semver.org).
  /// Nonisolated — accessible from any concurrency context.
  public nonisolated static let version: String = "1.0.0"

  // MARK: - State

  /// The underlying capture actor. `nil` until ``configure(with:)`` is called.
  private var _capture: CaptureActor?

  // MARK: - Init

  private init() {}

  // MARK: - Public API

  /// Configures the AuraKit pipeline with the provided settings.
  ///
  /// This method initialises the ``CaptureActor`` and its dependencies
  /// using the supplied ``AuraConfiguration``.
  ///
  /// - Important: Calling `configure(with:)` more than once without an
  ///   intervening ``reset()`` throws ``AuraError/alreadyConfigured``.
  ///   Call ``reset()`` explicitly first if reconfiguration is intentional
  ///   (e.g., in tests).
  ///
  /// - Parameter config: The validated ``AuraConfiguration`` to apply.
  /// - Throws: ``AuraError/alreadyConfigured`` if the pipeline is already active.
  public func configure(with config: AuraConfiguration) throws {
    try configure(with: config, store: nil)
  }

  /// Configures the AuraKit pipeline with the provided settings and an optional
  /// custom persistence store.
  ///
  /// This overload enables host applications to inject a production-grade
  /// ``EncryptedMemoryStore`` (or any ``SpatialEventStore`` conforming type)
  /// at configuration time:
  ///
  /// ```swift
  /// let container = try PersistenceController.makeContainer()
  /// let store = EncryptedMemoryStore(container: container)
  /// try AuraKit.shared.configure(with: config, store: store)
  /// ```
  ///
  /// When `store` is `nil`, a default ``MemoryStore`` is created using
  /// `config.storeCapacity` — matching the behaviour of ``configure(with:)``.
  ///
  /// - Important: Calling `configure` more than once without an
  ///   intervening ``reset()`` throws ``AuraError/alreadyConfigured``.
  ///
  /// - Parameters:
  ///   - config: The validated ``AuraConfiguration`` to apply.
  ///   - store: An optional ``SpatialEventStore`` to use for persistence.
  ///     Pass `nil` to use the default in-memory store.
  /// - Throws: ``AuraError/alreadyConfigured`` if the pipeline is already active.
  public func configure(
    with config: AuraConfiguration,
    store: (any SpatialEventStore)?
  ) throws {
    guard _capture == nil else {
      AuraKit.logger.fault(
        """
        [AuraKit] configure(with:) called more than once. \
        Call AuraKit.shared.reset() before reconfiguring.
        """
      )
      throw AuraError.alreadyConfigured
    }
    _capture = CaptureActor(config: config, store: store)
  }

  /// Convenience throwing overload — constructs an ``AuraConfiguration`` from
  /// raw parameters and configures the pipeline in a single call.
  ///
  /// Eliminates the `try AuraConfiguration(…)` + `configure(with:)` two-step,
  /// removing the temptation to force-try configuration construction.
  ///
  /// - Parameters:
  ///   - interactionWeight: Score for interaction events. Default `1.0`.
  ///   - gazeWeight: Score for gaze events. Default `0.3`.
  ///   - bufferCapacity: L1 ring buffer capacity. Default `512`.
  ///   - storeCapacity: Max events in persistent memory. Default `10_000`.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter is out of range,
  ///   or ``AuraError/alreadyConfigured`` if the pipeline is already active.
  public func configure(
    interactionWeight: Double = AuraConfiguration.defaultInteractionWeight,
    gazeWeight: Double = AuraConfiguration.defaultGazeWeight,
    bufferCapacity: Int = AuraConfiguration.defaultBufferCapacity,
    storeCapacity: Int = AuraConfiguration.defaultStoreCapacity
  ) throws {
    let config = try AuraConfiguration(
      interactionWeight: interactionWeight,
      gazeWeight: gazeWeight,
      bufferCapacity: bufferCapacity,
      storeCapacity: storeCapacity
    )
    try configure(with: config)
  }

  /// The active ``CaptureActor`` for recording spatial events.
  ///
  /// - Throws: ``AuraError/notConfigured`` if ``configure(with:)`` has not
  ///   been called.
  public func capture() throws -> CaptureActor {
    guard let capture = _capture else {
      throw AuraError.notConfigured
    }
    return capture
  }

  /// The active ``CaptureActor``, or `nil` if not yet configured.
  ///
  /// A non-throwing alternative to ``capture()`` for hot-path contexts where
  /// catching ``AuraError/notConfigured`` would add unnecessary overhead:
  ///
  /// ```swift
  /// // Guard-style — no try/catch needed
  /// guard let capture = AuraKit.shared.captureOrNil else { return }
  /// await capture.record(event: event)
  /// ```
  ///
  /// Use ``capture()`` when the not-configured state is truly exceptional
  /// and should propagate as an error. Use `captureOrNil` when the caller
  /// can gracefully skip recording (e.g., optional telemetry).
  public var captureOrNil: CaptureActor? {
    _capture
  }

  /// Whether `configure(with:)` has been called and the pipeline is active.
  ///
  /// Use this for guard-style checks where catching `AuraError.notConfigured`
  /// from ``capture()`` would be unnecessarily heavy.
  public var isConfigured: Bool {
    _capture != nil
  }

  /// Tears down the current configuration, allowing ``configure(with:)`` to
  /// be called again.
  ///
  /// - Warning: This is a **hard reset** that discards the current
  ///   ``CaptureActor`` and all in-flight events **without flushing**.
  ///   Available in **DEBUG builds only** — in release builds this method
  ///   is a **no-op** that logs a fault-level diagnostic.
  ///   For production teardown, use ``shutdown()`` instead, which flushes
  ///   buffered events before tearing down.
  ///
  /// ## Production Safety
  ///
  /// Calling `reset()` in a release build will **not** tear down the pipeline.
  /// This prevents accidental data loss from a misplaced `reset()` call in
  /// production code paths. The fault-level log ensures the call is visible
  /// in production telemetry.
  ///
  /// ```swift
  /// // ✅ Production teardown — flushes buffered events
  /// await AuraKit.shared.shutdown()
  ///
  /// // ❌ Production — no-op, logs fault
  /// AuraKit.shared.reset()
  ///
  /// // ✅ Test teardown — resets immediately
  /// AuraKit.shared.reset()  // Works in DEBUG builds
  /// ```
  public func reset() {
    #if !DEBUG
    AuraKit.logger.fault(
      """
      [AuraKit] reset() called in RELEASE build — this is a no-op. \
      Use shutdown() for production teardown. reset() is intended for \
      unit tests only and is disabled in release builds to prevent \
      accidental data loss.
      """
    )
    return
    #else
    if _capture != nil {
      AuraKit.logger.info("[AuraKit] reset() — tearing down capture pipeline (hard reset, no flush).")
    }
    _capture = nil
    #endif
  }

  /// Gracefully shuts down the capture pipeline, flushing all in-flight events
  /// before teardown.
  ///
  /// Unlike ``reset()``, which discards buffered events immediately, `shutdown()`
  /// first drains the L1 ``RingBuffer`` and writes all pending gaze events to the
  /// persistent ``SpatialEventStore`` via ``CaptureActor/flushToStore()``. This
  /// ensures zero data loss during application lifecycle transitions.
  ///
  /// After this call, ``isConfigured`` returns `false` and ``configure(with:)``
  /// may be called again.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// // In your App's scenePhase handler or applicationWillTerminate:
  /// await AuraKit.shared.shutdown()
  /// ```
  ///
  /// - Returns: The number of buffered events that were flushed to the store.
  ///   Returns `0` if no events were buffered or if the pipeline was not configured.
  @discardableResult
  public func shutdown() async -> Int {
    guard let capture = _capture else {
      AuraKit.logger.info("[AuraKit] shutdown() — pipeline not configured, nothing to tear down.")
      return 0
    }

    let flushedCount = await capture.flushToStore()

    if flushedCount > 0 {
      AuraKit.logger.info(
        "[AuraKit] shutdown() — flushed \(flushedCount) buffered events to store before teardown."
      )
    }

    AuraKit.logger.info("[AuraKit] shutdown() — capture pipeline torn down gracefully.")
    _capture = nil
    return flushedCount
  }

  // MARK: - Idempotent Configuration

  /// Configures the pipeline **only if** it has not been configured yet.
  ///
  /// Unlike ``configure(with:)``, which throws ``AuraError/alreadyConfigured``
  /// on repeated calls, `configureIfNeeded` is a **no-op** when the pipeline
  /// is already active. This makes it safe to call from multiple entry points
  /// (e.g., both `App.init` and a `.task` modifier) without coordination.
  ///
  /// ```swift
  /// // Safe to call multiple times — only the first call takes effect
  /// AuraKit.shared.configureIfNeeded(with: config)
  /// AuraKit.shared.configureIfNeeded(with: config) // no-op, no throw
  /// ```
  ///
  /// ## When to Use
  ///
  /// | Scenario | Recommended API |
  /// |----------|-----------------|
  /// | Single, well-defined init point | ``configure(with:)`` (strict) |
  /// | Multiple possible init paths | `configureIfNeeded(with:)` (idempotent) |
  /// | Test teardown / reconfiguration | ``reset()`` + ``configure(with:)`` |
  ///
  /// - Parameter config: The validated ``AuraConfiguration`` to apply.
  ///   Ignored if the pipeline is already configured.
  public func configureIfNeeded(with config: AuraConfiguration) {
    configureIfNeeded(with: config, store: nil)
  }

  /// Configures the pipeline with an optional custom store **only if** it has
  /// not been configured yet.
  ///
  /// This is the idempotent counterpart to ``configure(with:store:)``.
  /// If the pipeline is already active, this method returns silently.
  ///
  /// - Parameters:
  ///   - config: The validated ``AuraConfiguration`` to apply.
  ///   - store: An optional ``SpatialEventStore`` for persistence.
  ///     Pass `nil` to use the default in-memory store.
  public func configureIfNeeded(
    with config: AuraConfiguration,
    store: (any SpatialEventStore)?
  ) {
    guard _capture == nil else { return }
    _capture = CaptureActor(config: config, store: store)
  }
}

