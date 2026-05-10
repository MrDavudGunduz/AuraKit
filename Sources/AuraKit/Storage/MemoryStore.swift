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
/// ## Performance
///
/// Both `append` and eviction are **O(1)** operations. The backing storage
/// uses a pre-allocated circular array with modular indexing — no element
/// shifting, no dynamic resizing after initialisation.
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
    subsystem: "com.aurakit.framework",
    category: "MemoryStore"
  )

  // MARK: - State

  /// Pre-allocated fixed-size circular storage (bounded mode) or dynamic array (unbounded).
  private var storage: [SpatialEvent?]

  /// Index at which the next write will occur (bounded mode).
  private var writeIndex: Int = 0

  /// Number of valid elements currently stored.
  private var _count: Int = 0

  /// Maximum number of events retained. `0` means unbounded.
  private let capacity: Int

  /// Whether this store operates in bounded (ring) mode.
  private var isBounded: Bool { capacity > 0 }

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
    }

    // Pre-allocate full capacity for bounded mode; empty for unbounded.
    self.storage = safeCapacity > 0
      ? [SpatialEvent?](repeating: nil, count: safeCapacity)
      : []
  }

  // MARK: - Mutations

  /// Appends a high-signal event to the persistent memory log.
  ///
  /// In bounded mode, the oldest event is silently overwritten when full
  /// — O(1) via circular indexing. In unbounded mode, events are simply
  /// appended to the backing array.
  ///
  /// - Parameter event: The ``SpatialEvent`` to persist.
  public func append(_ event: SpatialEvent) {
    if isBounded {
      storage[writeIndex] = event
      writeIndex = (writeIndex + 1) % capacity
      if _count < capacity { _count += 1 }
    } else {
      storage.append(event)
      _count += 1
    }
  }

  // MARK: - Reads

  /// Returns a snapshot of all stored events in chronological order.
  ///
  /// The returned array is a value-type copy — mutations to the return value
  /// do not affect the stored log.
  ///
  /// - Returns: All stored ``SpatialEvent`` values, oldest first.
  public func allEvents() -> [SpatialEvent] {
    if isBounded {
      guard _count > 0 else { return [] }
      var result = [SpatialEvent]()
      result.reserveCapacity(_count)
      let head = _count == capacity ? writeIndex : 0
      for idx in 0..<_count {
        let index = (head + idx) % capacity
        if let event = storage[index] {
          result.append(event)
        }
      }
      return result
    } else {
      return storage.compactMap { $0 }
    }
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

    if isBounded {
      let effectiveLimit = min(limit, _count - offset)
      var result = [SpatialEvent]()
      result.reserveCapacity(effectiveLimit)

      // Head of the circular buffer — oldest element
      let head = _count == capacity ? writeIndex : 0
      let startIndex = (head + offset) % capacity

      for idx in 0..<effectiveLimit {
        let index = (startIndex + idx) % capacity
        if let event = storage[index] {
          result.append(event)
        }
      }
      return result
    } else {
      let end = min(offset + limit, _count)
      return storage[offset..<end].compactMap { $0 }
    }
  }

  /// The total number of events currently in the store.
  public var count: Int {
    _count
  }

  /// Removes all events from the store.
  ///
  /// - Warning: This is a destructive operation. In Phase 2, the encrypted
  ///   SwiftData backing store will require an explicit migration step before
  ///   calling this method in production code.
  public func clear() {
    if isBounded {
      for idx in 0..<capacity { storage[idx] = nil }
      writeIndex = 0
    } else {
      storage.removeAll(keepingCapacity: true)
    }
    _count = 0
  }
}
