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
/// The backing storage uses a `StorageMode` enum that encapsulates the two
/// mutually exclusive modes at the type level:
/// - **Bounded**: Pre-allocated circular array with modular indexing — O(1)
///   append and eviction, zero dynamic resizing after initialisation.
/// - **Unbounded**: Dynamic array with no eviction — append-only, O(1) amortised.
///
/// This design eliminates the previous dual-array approach (which always
/// allocated an empty companion array) and makes the mode distinction a
/// compile-time guarantee.
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

  // MARK: - Storage Mode

  /// Encapsulates the two mutually exclusive storage strategies.
  ///
  /// Using an enum instead of two separate arrays ensures that only one
  /// storage representation exists at any time — the compiler enforces this
  /// invariant, and no memory is wasted on an empty companion array.
  private enum StorageMode {
    /// Ring-buffer storage with fixed capacity and modular indexing.
    case bounded(storage: [SpatialEvent?], writeIndex: Int, capacity: Int)
    /// Dynamic array storage with no eviction — append-only.
    case unbounded(storage: [SpatialEvent])
  }

  // MARK: - State

  /// The active storage mode, determined at init time and immutable thereafter.
  private var mode: StorageMode

  /// Number of valid elements currently stored.
  private var _count: Int = 0

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

    if safeCapacity == 0 {
      MemoryStore.logger.fault(
        """
        [AuraKit] MemoryStore initialised with capacity 0 (unbounded mode). \
        This disables FIFO eviction and may cause OOM termination in long-running \
        sessions. Use a positive capacity for production deployments.
        """
      )
      self.mode = .unbounded(storage: [])
    } else {
      self.mode = .bounded(
        storage: [SpatialEvent?](repeating: nil, count: safeCapacity),
        writeIndex: 0,
        capacity: safeCapacity
      )
    }
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
    switch mode {
    case .bounded(var storage, var writeIndex, let capacity):
      storage[writeIndex] = event
      writeIndex = (writeIndex + 1) % capacity
      if _count < capacity { _count += 1 }
      mode = .bounded(storage: storage, writeIndex: writeIndex, capacity: capacity)

    case .unbounded(var storage):
      storage.append(event)
      _count += 1
      mode = .unbounded(storage: storage)
    }
  }

  /// Appends multiple events in a single batch operation.
  ///
  /// Unlike the default `SpatialEventStore` implementation (which falls back
  /// to sequential `append()` calls with N actor hops), this override processes
  /// all events in a single actor-isolated pass — eliminating inter-hop latency
  /// for burst ingestion scenarios.
  ///
  /// In bounded mode, FIFO eviction is applied per-event as in `append()`.
  /// In unbounded mode, all events are appended in a single array operation.
  ///
  /// - Parameter events: The events to persist.
  public func batchAppend(_ events: [SpatialEvent]) {
    guard !events.isEmpty else { return }

    switch mode {
    case .bounded(var storage, var writeIndex, let capacity):
      for event in events {
        storage[writeIndex] = event
        writeIndex = (writeIndex + 1) % capacity
        if _count < capacity { _count += 1 }
      }
      mode = .bounded(storage: storage, writeIndex: writeIndex, capacity: capacity)

    case .unbounded(var storage):
      storage.reserveCapacity(storage.count + events.count)
      storage.append(contentsOf: events)
      _count += events.count
      mode = .unbounded(storage: storage)
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
    switch mode {
    case .bounded(let storage, let writeIndex, let capacity):
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

    case .unbounded(let storage):
      // Unbounded storage never contains nil — return directly.
      return storage
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

    switch mode {
    case .bounded(let storage, let writeIndex, let capacity):
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

    case .unbounded(let storage):
      // Unbounded storage never contains nil — direct slice, no compactMap.
      let end = min(offset + limit, _count)
      return Array(storage[offset..<end])
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
    switch mode {
    case .bounded(var storage, _, let capacity):
      for idx in 0..<capacity { storage[idx] = nil }
      mode = .bounded(storage: storage, writeIndex: 0, capacity: capacity)

    case .unbounded(var storage):
      storage.removeAll(keepingCapacity: true)
      mode = .unbounded(storage: storage)
    }
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

    switch mode {
    case .bounded(_, _, let capacity):
      let activeEvents = allEvents().filter { !ids.contains($0.id) }
      var newStorage = Array<SpatialEvent?>(repeating: nil, count: capacity)
      for (idx, event) in activeEvents.enumerated() {
        newStorage[idx] = event
      }
      _count = activeEvents.count
      mode = .bounded(storage: newStorage, writeIndex: activeEvents.count % capacity, capacity: capacity)

    case .unbounded(var storage):
      storage.removeAll(where: { ids.contains($0.id) })
      _count = storage.count
      mode = .unbounded(storage: storage)
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

