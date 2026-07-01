// SpatialEventStore.swift
// AuraKit — Core Infrastructure
//
// Protocol abstraction for the spatial event persistence layer.
// Enables zero-call-site-modification when swapping MemoryStore for the
// Phase 2 AES-GCM encrypted SwiftData store.

import Foundation

// MARK: - SpatialEventStore

/// A protocol defining the persistence contract for high-signal spatial events.
///
/// `SpatialEventStore` is the **Open/Closed Principle boundary** in AuraKit's
/// storage layer. `CaptureActor` depends on this protocol, not on a concrete type,
/// so the Phase 2 AES-GCM encrypted SwiftData backing store can be injected without
/// modifying any call sites.
///
/// ## Conforming Types
///
/// - ``MemoryStore`` — Phase 1 in-memory implementation.
/// - ``EncryptedMemoryStore`` — Phase 2 AES-GCM encrypted, SwiftData-backed store.
///
/// ## Concurrency
///
/// All mutating and reading operations are `async` to accommodate actor-isolated
/// and async-throwing implementations equally. Conforming types must be actors
/// or otherwise guarantee their own thread safety.
///
/// ## Note on `clear()`
///
/// `clear()` is a destructive, test-only operation and is intentionally **not**
/// part of this protocol. It is implemented directly on conforming types and accessed
/// in tests via `@testable import AuraKit`. Production code should never call `clear()`.
public protocol SpatialEventStore: Actor {

  /// Appends a high-signal event to the persistent event log.
  ///
  /// - Parameter event: The ``SpatialEvent`` to persist. Called on the hot path
  ///   immediately after ``HeuristicRouter`` returns ``RouteDecision/directStore(score:)``.
  func append(_ event: SpatialEvent) async

  /// Appends multiple events in a single batch, amortising I/O cost.
  ///
  /// For stores backed by persistent storage (e.g., ``EncryptedMemoryStore``),
  /// this method inserts all events into the context and issues a single
  /// `save()` call — reducing I/O operations from `N` to `1`.
  ///
  /// The default implementation falls back to sequential ``append(_:)`` calls
  /// for stores that do not override this method.
  ///
  /// - Parameter events: The ``SpatialEvent`` array to persist.
  func batchAppend(_ events: [SpatialEvent]) async

  /// Returns a snapshot of all stored events in chronological order.
  ///
  /// The returned array is a value-type copy — mutations do not affect the log.
  ///
  /// - Warning: For stores backed by encrypted persistent storage (e.g.,
  ///   ``EncryptedMemoryStore``), this method performs a **full-table decrypt**
  ///   which can cause significant memory pressure and latency with large
  ///   datasets (1,000+ events).
  ///
  ///   ## ⚠️ Deprecation Path
  ///
  ///   `allEvents()` will be deprecated in a future AuraKit release.
  ///   Migrate to one of the bounded alternatives below **now** to avoid
  ///   a forced migration later.
  ///
  ///   ## Choosing the Right API
  ///
  ///   | Use Case                        | Recommended API                         |
  ///   |---------------------------------|-----------------------------------------|
  ///   | Known-small dataset (\< 1,000)   | ``allEvents()``                         |
  ///   | Production with unknown size    | ``events(limit:offset:)``               |
  ///   | Large dataset streaming          | `eventStream(limit:offset:batchSize:)`  |
  ///   | Safety-critical code paths       | `allEventsIfSmallDataset(threshold:)`   |
  ///   | Unit tests / debugging           | ``allEvents()``                         |
  func allEvents() async -> [SpatialEvent]

  /// Returns a paginated slice of stored events in chronological order.
  ///
  /// Use this instead of ``allEvents()`` when the store is expected to contain
  /// thousands of events. Each call processes only `limit` events, preventing
  /// memory pressure spikes from full-table operations.
  ///
  /// - Parameters:
  ///   - limit: Maximum number of events to return.
  ///   - offset: Number of events to skip from the beginning. Defaults to `0`.
  /// - Returns: Events in chronological order (oldest first).
  func events(limit: Int, offset: Int) async -> [SpatialEvent]

  /// The total number of events currently in the store.
  var count: Int { get async }

  /// Flushes any pending writes that have been coalesced but not yet persisted.
  ///
  /// For stores with write coalescing (e.g., ``EncryptedMemoryStore`` with
  /// ``saveThreshold`` > 1), `append()` may defer persistence until a threshold
  /// is reached. This method forces an immediate commit of all pending inserts.
  ///
  /// Call this during pipeline shutdown, before reads that must see the latest
  /// writes, or at app lifecycle boundaries.
  ///
  /// The default implementation is a no-op — stores without write coalescing
  /// (e.g., ``MemoryStore``) do not need to override this.
  func flushPendingWrites() async
}

// MARK: - Default Implementations

extension SpatialEventStore {

  /// Default batch append — falls back to sequential single-event appends.
  ///
  /// Conforming types with I/O-backed storage should override this method
  /// to batch inserts and issue a single save for optimal throughput.
  public func batchAppend(_ events: [SpatialEvent]) async {
    for event in events {
      await append(event)
    }
  }

  /// Default paginated fetch — slices the full `allEvents()` snapshot.
  ///
  /// Conforming types with large stores should override this method with
  /// an optimised implementation that avoids loading the full dataset
  /// (e.g., SwiftData `fetchLimit`/`fetchOffset`).
  public func events(limit: Int, offset: Int = 0) async -> [SpatialEvent] {
    let all = await allEvents()
    guard limit > 0, offset >= 0, offset < all.count else { return [] }
    let end = min(offset + limit, all.count)
    return Array(all[offset..<end])
  }

  /// Default no-op implementation for stores that do not use write coalescing.
  public func flushPendingWrites() async {}
}
