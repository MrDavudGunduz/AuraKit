// SpatialEventStore.swift
// AuraKit — Core Infrastructure
//
// Protocol abstraction for the spatial event persistence layer.
// Enables zero-call-site-modification when swapping MemoryStore for the
// Phase 2 AES-GCM encrypted SwiftData store.

import Foundation

// MARK: - SpatialEventStore

/// A protocol defining the minimal persistence contract for high-signal spatial events.
///
/// `SpatialEventStore` is the **Open/Closed Principle boundary** in AuraKit's
/// storage layer. `CaptureActor` depends on this protocol, not on a concrete type,
/// so the Phase 2 AES-GCM encrypted SwiftData backing store can be injected without
/// modifying any call sites.
///
/// ## Conforming Types
///
/// - ``MemoryStore`` — Phase 1 in-memory implementation.
/// - `EncryptedSwiftDataStore` *(Phase 2)* — AES-GCM encrypted, CloudKit-synced store.
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
/// part of this protocol. It is implemented directly on ``MemoryStore`` and accessed
/// in tests via `@testable import AuraKit`. Production code should never call `clear()`.
public protocol SpatialEventStore: Actor {

  /// Appends a high-signal event to the persistent event log.
  ///
  /// - Parameter event: The ``SpatialEvent`` to persist. Called on the hot path
  ///   immediately after ``HeuristicRouter`` returns ``RouteDecision/directStore(score:)``.
  func append(_ event: SpatialEvent) async

  /// Returns a snapshot of all stored events in chronological order.
  ///
  /// The returned array is a value-type copy — mutations do not affect the log.
  func allEvents() async -> [SpatialEvent]

  /// The total number of events currently in the store.
  var count: Int { get async }
}
