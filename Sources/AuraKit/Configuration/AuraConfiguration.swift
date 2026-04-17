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
  public static let defaultInteractionWeight: Float = 1.0

  /// Default weight applied to `.gaze` events.
  public static let defaultGazeWeight: Float = 0.3

  /// Default L1 ring buffer capacity in number of events.
  public static let defaultBufferCapacity: Int = 512

  /// Default maximum number of events the `MemoryStore` will hold.
  ///
  /// When this limit is reached the oldest events are evicted first (FIFO).
  /// Set to `0` to disable the cap (unbounded — not recommended in production).
  public static let defaultStoreCapacity: Int = 10_000

  // MARK: - Properties

  /// Heuristic importance weight for high-signal interaction events.
  ///
  /// Must be in the range `[0.0, 1.0]`. Validated at configuration time.
  public let interactionWeight: Float

  /// Heuristic importance weight for low-signal passive gaze events.
  ///
  /// Must be in the range `[0.0, 1.0]`. Validated at configuration time.
  public let gazeWeight: Float

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

  // MARK: - Init

  /// Creates a validated `AuraConfiguration`, throwing if any parameter is out of range.
  ///
  /// - Parameters:
  ///   - interactionWeight: Score for interaction events. Default `1.0`.
  ///   - gazeWeight: Score for gaze events. Default `0.3`.
  ///   - bufferCapacity: L1 ring buffer capacity. Default `512`.
  ///   - storeCapacity: Max events in the persistent `MemoryStore`. Default `10_000`.
  ///     Pass `0` to disable the cap (unbounded).
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if any parameter
  ///   is out of its valid range.
  public init(
    interactionWeight: Float = defaultInteractionWeight,
    gazeWeight: Float = defaultGazeWeight,
    bufferCapacity: Int = defaultBufferCapacity,
    storeCapacity: Int = defaultStoreCapacity
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
    self.interactionWeight = interactionWeight
    self.gazeWeight = gazeWeight
    self.bufferCapacity = bufferCapacity
    self.storeCapacity = storeCapacity
  }

  /// Private unchecked initialiser for known-valid constant values only.
  /// Bypasses validation to avoid `try!` or force-unwrap at call sites
  /// where correctness is guaranteed by the compiler (e.g., `AuraConfiguration.default`).
  private init(
    uncheckedInteractionWeight interactionWeight: Float,
    gazeWeight: Float,
    bufferCapacity: Int,
    storeCapacity: Int
  ) {
    self.interactionWeight = interactionWeight
    self.gazeWeight = gazeWeight
    self.bufferCapacity = bufferCapacity
    self.storeCapacity = storeCapacity
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
  public static let `default` = AuraConfiguration(
    uncheckedInteractionWeight: defaultInteractionWeight,
    gazeWeight: defaultGazeWeight,
    bufferCapacity: defaultBufferCapacity,
    storeCapacity: defaultStoreCapacity
  )
}
