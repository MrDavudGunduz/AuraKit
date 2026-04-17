// AuraKit.swift
// AuraKit — On-device, cryptographically secured spatial memory framework.
// https://github.com/MrDavudGunduz/AuraKit

import Foundation
import os.log

/// # AuraKit
///
/// AuraKit is an **open-core Swift Package** that provides iOS, macOS, and visionOS
/// applications with a persistent, privacy-first spatial memory layer.
///
/// ## Overview
///
/// AuraKit ingests 3D spatial events (gaze, touch, movement) through a Swift 6
/// Actor-isolated pipeline, scores them using a heuristic bypass engine, and stores
/// them in an on-device AES-GCM encrypted SwiftData store — with no data ever
/// leaving the user's device.
///
/// The Enterprise tier (`Aura Intelligence`) extends this foundation with:
/// - On-device LLM semantic pruning via Apple MLX
/// - Survival Index scoring for intelligent memory longevity
/// - Semantic consolidation (cognitive compression)
/// - GPU-accelerated cosine similarity search via Metal
///
/// ## Quick Start
///
/// Configure AuraKit once at app launch from a `@MainActor` context. The simplest
/// approach is `App.body` or a `Task { @MainActor in }` block:
///
/// ```swift
/// import AuraKit
///
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup { ContentView() }
///             .task {
///                 // .task modifier runs on @MainActor — safe for configure()
///                 let config = try AuraConfiguration(
///                     interactionWeight: 1.0, // Touch/Move: max score, bypasses LLM
///                     gazeWeight: 0.3,        // Gaze: low-weight, queued in L1 Buffer
///                     bufferCapacity: 512
///                 )
///                 AuraKit.shared.configure(with: config)
///             }
///     }
/// }
/// ```
///
/// Record a spatial event using the convenience factory:
///
/// ```swift
/// try await AuraKit.shared.capture().record(
///     event: SpatialEvent(
///         kind: .gaze(rawPosition: SIMD3(0.1, 0.9, -1.0)),
///         score: 0  // Overwritten by HeuristicRouter at record time
///     )
/// )
/// ```
///
/// ## Concurrency
///
/// `AuraKit.shared` and `configure(with:)` are `@MainActor`-isolated.
/// Call them from the main actor context — `App.body`, a `.task` modifier,
/// or an explicit `Task { @MainActor in ... }` block.
/// Calling them from a background task without the correct actor context
/// will produce a compile-time error in Swift 6 strict concurrency mode.
///
/// ## Architecture
///
/// ```
/// CaptureActor → IntelligenceActor (Enterprise) → MemoryActor → Metal Search
/// ```
///
/// For complete architecture documentation, see
/// [ARCHITECTURE.md](https://github.com/MrDavudGunduz/AuraKit/blob/main/ARCHITECTURE.md).
///
/// ## Topics
///
/// ### Configuration
/// - ``AuraConfiguration``
///
/// ### Capture
/// - ``CaptureActor``
/// - ``SpatialEvent``
/// - ``SpatialEventKind``
/// - ``InteractionType``
/// - ``RingBuffer``
///
/// ### Routing
/// - ``HeuristicRouter``
/// - ``RouteDecision``
///
/// ### Storage
/// - ``SpatialEventStore``
/// - ``MemoryStore``
///
/// ### Errors
/// - ``AuraError``

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
    subsystem: "com.aurakit.framework",
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
  ///   intervening ``reset()`` is a programming error. In DEBUG builds an
  ///   `assertionFailure` is raised (visible in Xcode) and a fault is logged to
  ///   the `com.aurakit.framework` subsystem. In RELEASE builds the second call is
  ///   silently ignored — the existing configuration is preserved.
  ///   Call ``reset()`` explicitly first if reconfiguration is intentional (e.g., in tests).
  ///
  /// - Parameter config: The validated ``AuraConfiguration`` to apply.
  public func configure(with config: AuraConfiguration) {
    guard _capture == nil else {
      assertionFailure(
        "[AuraKit] configure(with:) called more than once. "
          + "Call AuraKit.shared.reset() before reconfiguring."
      )
      AuraKit.logger.fault(
        """
        [AuraKit] configure(with:) called more than once. \
        Call AuraKit.shared.reset() before reconfiguring. \
        This call has been ignored.
        """
      )
      return
    }
    _capture = CaptureActor(
      config: config,
      store: MemoryStore(capacity: config.storeCapacity)
    )
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
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter is out of range.
  public func configure(
    interactionWeight: Float = AuraConfiguration.defaultInteractionWeight,
    gazeWeight: Float = AuraConfiguration.defaultGazeWeight,
    bufferCapacity: Int = AuraConfiguration.defaultBufferCapacity,
    storeCapacity: Int = AuraConfiguration.defaultStoreCapacity
  ) throws {
    let config = try AuraConfiguration(
      interactionWeight: interactionWeight,
      gazeWeight: gazeWeight,
      bufferCapacity: bufferCapacity,
      storeCapacity: storeCapacity
    )
    configure(with: config)
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

  /// Tears down the current configuration, allowing ``configure(with:)`` to
  /// be called again.
  ///
  /// - Warning: This discards the current ``CaptureActor`` and all in-flight
  ///   events. Intended for use in unit tests only — do not call in production.
  public func reset() {
    _capture = nil
  }

  // MARK: - Convenience Static API

  /// Convenience static wrapper for ``configure(with:)``.
  ///
  /// Equivalent to `AuraKit.shared.configure(with: config)`.
  public static func configure(with config: AuraConfiguration) {
    shared.configure(with: config)
  }

  /// Convenience static wrapper for the throwing ``configure(interactionWeight:gazeWeight:bufferCapacity:storeCapacity:)`` overload.
  ///
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter is out of range.
  public static func configure(
    interactionWeight: Float = AuraConfiguration.defaultInteractionWeight,
    gazeWeight: Float = AuraConfiguration.defaultGazeWeight,
    bufferCapacity: Int = AuraConfiguration.defaultBufferCapacity,
    storeCapacity: Int = AuraConfiguration.defaultStoreCapacity
  ) throws {
    try shared.configure(
      interactionWeight: interactionWeight,
      gazeWeight: gazeWeight,
      bufferCapacity: bufferCapacity,
      storeCapacity: storeCapacity
    )
  }

  /// Convenience static wrapper for ``capture()``.
  ///
  /// - Throws: ``AuraError/notConfigured`` if not yet configured.
  public static func capture() throws -> CaptureActor {
    try shared.capture()
  }
}
