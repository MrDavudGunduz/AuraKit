// MemoryStore.swift
// AuraKit — Core Infrastructure
//
// Phase 1 in-memory event store with a configurable FIFO capacity cap.
// High-signal events routed directly by HeuristicRouter land here.
// Phase 2 replaces this with an AES-GCM encrypted SwiftData store
// conforming to the same SpatialEventStore protocol.

import Foundation
import os.log

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
/// ## Storage Model
///
/// - **Bounded** (`capacity > 0`): Pre-allocated circular array with modular
///   indexing — O(1) append and eviction, zero dynamic resizing after
///   initialisation.
/// - **Unbounded** (`capacity == 0`): Dynamic array with no eviction —
///   append-only, O(1) amortised.
///
/// The arrays are plain stored properties and are mutated **in place**. A
/// previous version kept them as enum payloads (`case bounded(storage: …)`);
/// binding a payload with `var` copies the array while the enum still holds a
/// reference, so every append paid an O(capacity) copy-on-write.
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

  // MARK: - Internal Logger

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "MemoryStore"
  )

  // MARK: - State

  /// Ring storage for bounded mode (`capacity > 0`). Empty in unbounded mode.
  private var ring: [SpatialEvent?]

  /// Append-only storage for unbounded mode (`capacity == 0`). Empty otherwise.
  private var log: [SpatialEvent] = []

  /// Next write position in ``ring``.
  private var writeIndex: Int = 0

  /// Maximum events retained; `0` means unbounded.
  private let capacity: Int

  /// Number of valid elements currently stored.
  private var _count: Int = 0

  private var isBounded: Bool { capacity > 0 }

  /// Ring index of the oldest element (bounded mode).
  private var ringHead: Int { _count == capacity ? writeIndex : 0 }

  // MARK: - Init

  /// Creates an empty `MemoryStore`.
  ///
  /// - Parameter capacity: Maximum event count before oldest-first eviction
  ///   kicks in. Pass `0` for unbounded (defaults to
  ///   ``AuraConfiguration/defaultStoreCapacity``).
  ///
  /// - Warning: Passing `0` disables eviction. In long-running visionOS sessions
  ///   this can lead to unbounded memory growth and eventual OOM termination.
  ///   A fault-level log is emitted to the unified logging system when this occurs.
  public init(capacity: Int = AuraConfiguration.defaultStoreCapacity) {
    let safeCapacity = max(0, capacity)
    self.capacity = safeCapacity

    if safeCapacity == 0 {
      MemoryStore.logger.fault(
        """
        [AuraKit] MemoryStore initialised with capacity 0 (unbounded mode). \
        This disables FIFO eviction and may cause OOM termination in long-running \
        sessions. Use a positive capacity for production deployments.
        """
      )
      self.ring = []
    } else {
      self.ring = [SpatialEvent?](repeating: nil, count: safeCapacity)
    }
  }

  // MARK: - Mutations

  /// Appends a high-signal event to the persistent memory log.
  ///
  /// In bounded mode, the oldest event is silently overwritten when full
  /// — O(1) via circular indexing, in place. In unbounded mode, events are
  /// simply appended to the backing array.
  ///
  /// - Parameter event: The ``SpatialEvent`` to persist.
  public func append(_ event: SpatialEvent) {
    if isBounded {
      writeToRing(event)
    } else {
      log.append(event)
      _count += 1
    }
  }

  /// Appends multiple events in a single batch operation.
  ///
  /// Unlike the default `SpatialEventStore` implementation (which falls back
  /// to sequential `append()` calls with N actor hops), this override processes
  /// all events in a single actor-isolated pass — eliminating inter-hop latency
  /// for burst ingestion scenarios.
  ///
  /// In bounded mode, only the newest `capacity` events can survive, so older
  /// events in an oversized batch are skipped instead of written and evicted.
  ///
  /// - Parameter events: The events to persist.
  public func batchAppend(_ events: [SpatialEvent]) {
    guard !events.isEmpty else { return }

    if isBounded {
      for event in events.suffix(capacity) {
        writeToRing(event)
      }
    } else {
      log.append(contentsOf: events)
      _count += events.count
    }
  }

  /// Writes one event into the ring, evicting the oldest when full.
  private func writeToRing(_ event: SpatialEvent) {
    ring[writeIndex] = event
    writeIndex = (writeIndex + 1) % capacity
    if _count < capacity { _count += 1 }
  }

  // MARK: - Reads

  /// Returns a snapshot of all stored events in chronological order.
  ///
  /// The returned array is a value-type copy — mutations to the return value
  /// do not affect the stored log.
  ///
  /// - Returns: All stored ``SpatialEvent`` values, oldest first.
  public func allEvents() -> [SpatialEvent] {
    guard isBounded else { return log }
    return ringSlice(offset: 0, limit: _count)
  }

  /// Returns a paginated slice of stored events in chronological order.
  ///
  /// This is the in-memory counterpart of ``EncryptedMemoryStore/events(limit:offset:)``.
  /// In bounded mode, uses direct circular-buffer traversal with offset/limit
  /// windowing — avoids allocating a full snapshot just to slice it.
  ///
  /// - Parameters:
  ///   - limit: Maximum number of events to return.
  ///   - offset: Number of events to skip from the beginning.
  /// - Returns: Events in chronological order (oldest first).
  public func events(limit: Int, offset: Int = 0) -> [SpatialEvent] {
    guard _count > 0, limit > 0, offset >= 0, offset < _count else { return [] }
    let effectiveLimit = min(limit, _count - offset)

    guard isBounded else {
      return Array(log[offset..<(offset + effectiveLimit)])
    }
    return ringSlice(offset: offset, limit: effectiveLimit)
  }

  /// Chronological window over the ring (bounded mode).
  private func ringSlice(offset: Int, limit: Int) -> [SpatialEvent] {
    guard limit > 0 else { return [] }
    var result = [SpatialEvent]()
    result.reserveCapacity(limit)
    let start = (ringHead + offset) % capacity
    for idx in 0..<limit {
      if let event = ring[(start + idx) % capacity] {
        result.append(event)
      }
    }
    return result
  }

  /// The total number of events currently in the store.
  public var count: Int {
    _count
  }

  /// Removes all events from the store.
  ///
  /// - Warning: Destructive; intended for tests and explicit user-initiated
  ///   resets.
  public func clear() {
    if isBounded {
      for idx in ring.indices { ring[idx] = nil }
    } else {
      log.removeAll(keepingCapacity: true)
    }
    writeIndex = 0
    _count = 0
  }

  /// Removes events with the specified IDs from memory.
  ///
  /// - Parameter ids: Set of event UUIDs to remove.
  /// - Returns: The number of events deleted.
  @discardableResult
  public func removeEvents(withIDs ids: Set<UUID>) -> Int {
    guard !ids.isEmpty, _count > 0 else { return 0 }
    let initialCount = _count

    if isBounded {
      // Compact survivors to the front in chronological order.
      let survivors = allEvents().filter { !ids.contains($0.id) }
      for idx in ring.indices {
        ring[idx] = idx < survivors.count ? survivors[idx] : nil
      }
      _count = survivors.count
      writeIndex = survivors.count % capacity
    } else {
      log.removeAll(where: { ids.contains($0.id) })
      _count = log.count
    }

    let removedCount = initialCount - _count
    if removedCount > 0 {
      MemoryStore.logger.debug(
        "[AuraKit] MemoryStore: Removed \(removedCount) events (requested: \(ids.count))."
      )
    }
    return removedCount
  }
}
