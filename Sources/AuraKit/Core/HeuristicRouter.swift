// HeuristicRouter.swift
// AuraKit — Core Infrastructure
//
// Stateless bypass layer that routes SpatialEvents to either the L1 ring buffer
// (low-signal gaze) or direct persistent memory (high-signal interaction).
// Zero allocations, zero actor hops — pure synchronous decision making.

import Foundation

// MARK: - RouteDecision

/// The routing decision produced by ``HeuristicRouter`` for a single event.
///
/// The associated score reflects the importance of the event as determined by
/// the configuration weights at the time of routing.
public enum RouteDecision: Sendable, Equatable {

  /// The event should be written directly to persistent memory.
  ///
  /// Used for high-signal interactions (touch, move, pinch, drag). The LLM
  /// inference stage is bypassed entirely, eliminating any associated latency.
  ///
  /// - Parameter score: Always `interactionWeight` from the active config
  ///   (defaults to `1.0`).
  case directStore(score: Float)

  /// The event should be enqueued in the L1 ``RingBuffer``.
  ///
  /// Used for low-signal gaze events. Events in the buffer are batched and
  /// forwarded to the LLM intelligence layer (Enterprise tier) when flushed.
  ///
  /// - Parameter score: The `gazeWeight` from the active config (default `0.3`).
  case enqueueBuffer(score: Float)
}

// MARK: - HeuristicRouter

/// A stateless, synchronous routing engine for 3D spatial events.
///
/// `HeuristicRouter` applies a simple but effective heuristic:
/// **high-signal events bypass the AI layer entirely**.
///
/// This design ensures that touch/move interactions — which represent
/// unambiguous user intent — are recorded with < 1ms latency, while
/// gaze events (inherently ambiguous) are batched for optional LLM
/// semantic analysis.
///
/// ## Routing Table
///
/// | Event Kind      | Route             | Score                |
/// |-----------------|-------------------|----------------------|
/// | `.gaze`         | L1 `RingBuffer`   | `config.gazeWeight`  |
/// | `.interaction`  | Persistent memory | `config.interactionWeight` |
///
/// ## Thread Safety
///
/// `HeuristicRouter` is a pure value type with no mutable state.
/// It is `Sendable` and may be captured freely by any actor or task.
public struct HeuristicRouter: Sendable {

  // MARK: - Init

  /// Creates a `HeuristicRouter`. No configuration is captured at init time;
  /// the active configuration is passed per-call to ``route(_:config:)`` for
  /// maximum testability and hot-reload support.
  public init() {}

  // MARK: - Routing

  /// Determines the routing path for a given ``SpatialEvent``.
  ///
  /// This method is fully synchronous and allocation-free — safe to call
  /// at 60fps on the capture hot path without performance concerns.
  ///
  /// - Parameters:
  ///   - event: The incoming spatial event to route.
  ///   - config: The active ``AuraConfiguration`` supplying weight values.
  /// - Returns: A ``RouteDecision`` indicating the destination and assigned score.
  public func route(_ event: SpatialEvent, config: AuraConfiguration) -> RouteDecision {
    switch event.kind {
    case .interaction:
      // High-signal: write directly to persistent memory. LLM bypass.
      return .directStore(score: config.interactionWeight)

    case .gaze:
      // Low-signal: enqueue for batched LLM processing.
      return .enqueueBuffer(score: config.gazeWeight)
    }
  }
}
