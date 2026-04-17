// MemoryStore.swift
// AuraKit — Core Infrastructure
//
// Phase 1 in-memory event store with a configurable FIFO capacity cap.
// High-signal events routed directly by HeuristicRouter land here.
// Phase 2 replaces this with an AES-GCM encrypted SwiftData store
// conforming to the same SpatialEventStore protocol.

import Foundation

// MARK: - MemoryStore

/// An actor-isolated in-memory store for high-signal ``SpatialEvent`` records.
///
/// In Phase 1, `MemoryStore` acts as the terminal sink for all events routed
/// via ``RouteDecision/directStore(score:)``. It provides an append-only log
/// with an optional FIFO capacity cap to prevent unbounded memory growth in
/// long-running visionOS sessions.
///
/// ## Capacity Semantics
///
/// When `capacity` is greater than `0`, the store enforces a hard upper bound.
/// Once the limit is reached the **oldest event is evicted** before each new
/// write — the same ring semantics used by the L1 ``RingBuffer``. Set `capacity`
/// to `0` to disable eviction (unbounded growth — not recommended for production).
///
/// ## Protocol Conformance
///
/// `MemoryStore` conforms to ``SpatialEventStore``. `CaptureActor` depends on
/// the protocol — not this concrete type — so the Phase 2 AES-GCM encrypted
/// SwiftData store can be injected without modifying any call sites.
///
/// ## Thread Safety
///
/// All operations are actor-isolated. Concurrent callers automatically serialise
/// through Swift's actor runtime — no locks, no data races.
public actor MemoryStore: SpatialEventStore {

  // MARK: - State

  /// The ordered log of all high-signal events received since initialization.
  private var events: [SpatialEvent] = []

  /// Maximum number of events retained. `0` means unbounded.
  private let capacity: Int

  // MARK: - Init

  /// Creates an empty `MemoryStore`.
  ///
  /// - Parameter capacity: Maximum event count before oldest-first eviction
  ///   kicks in. Pass `0` for unbounded (defaults to
  ///   ``AuraConfiguration/defaultStoreCapacity``).
  public init(capacity: Int = AuraConfiguration.defaultStoreCapacity) {
    self.capacity = max(0, capacity)
  }

  // MARK: - Mutations

  /// Appends a high-signal event to the persistent memory log.
  ///
  /// If the store has reached `capacity`, the oldest event is evicted
  /// before the new one is appended — maintaining a constant memory footprint.
  ///
  /// - Parameter event: The ``SpatialEvent`` to persist.
  public func append(_ event: SpatialEvent) {
    if capacity > 0 && events.count >= capacity {
      events.removeFirst()
    }
    events.append(event)
  }

  // MARK: - Reads

  /// Returns a snapshot of all stored events in chronological order.
  ///
  /// The returned array is a value-type copy — mutations to the return value
  /// do not affect the stored log.
  ///
  /// - Returns: All stored ``SpatialEvent`` values, oldest first.
  public func allEvents() -> [SpatialEvent] {
    events
  }

  /// The total number of events currently in the store.
  public var count: Int {
    events.count
  }

  /// Removes all events from the store.
  ///
  /// - Warning: This is a destructive operation. In Phase 2, the encrypted
  ///   SwiftData backing store will require an explicit migration step before
  ///   calling this method in production code.
  public func clear() {
    events.removeAll(keepingCapacity: true)
  }
}
