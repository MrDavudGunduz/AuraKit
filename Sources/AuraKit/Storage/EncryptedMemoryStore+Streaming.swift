// EncryptedMemoryStore+Streaming.swift
// AuraKit — Core Infrastructure
//
// AsyncStream-based lazy decryption API for EncryptedMemoryStore.
// Enables streaming decryption of large stores without loading all
// decrypted payloads into memory simultaneously — OOM protection.

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Streaming API

extension EncryptedMemoryStore {

  /// Returns an `AsyncStream` that lazily decrypts and yields events one at a time.
  ///
  /// Unlike ``allEvents()`` which decrypts the entire store into an `[SpatialEvent]`
  /// array, this method decrypts each node on-demand, keeping memory usage
  /// proportional to the consumer's processing rate rather than the total store size.
  ///
  /// This is the preferred API for large stores (1,000+ events) where loading
  /// all decrypted payloads simultaneously risks exceeding memory limits.
  ///
  /// **Pure read** — no recall counters are incremented.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// for await event in store.eventStream() {
  ///     process(event)
  /// }
  /// ```
  ///
  /// ## Error Handling
  ///
  /// Nodes that fail decryption are silently skipped (logged at error level).
  /// The stream continues yielding subsequent nodes — a single corrupted
  /// record never terminates the entire stream.
  ///
  /// - Parameters:
  ///   - limit: Maximum number of events to yield. Pass `nil` (default) for all events.
  ///   - offset: Number of events to skip before yielding. Defaults to `0`.
  /// - Returns: An `AsyncStream<SpatialEvent>` yielding decrypted events chronologically.
  public func eventStream(
    limit: Int? = nil,
    offset: Int = 0
  ) async -> AsyncStream<SpatialEvent> {
    // Fetch key and nodes within the actor's isolation domain
    // BEFORE entering the AsyncStream closure (which is non-async).
    let nodes: [RawMemoryNode]
    let key: SymmetricKey

    do {
      key = try await keyManager.symmetricKey()

      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      if let limit {
        descriptor.fetchLimit = limit
      }
      descriptor.fetchOffset = offset

      nodes = try modelContext.fetch(descriptor)
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Stream setup failed — \(error.localizedDescription)"
      )
      // Return an immediately-finished stream on setup failure
      return AsyncStream { $0.finish() }
    }

    // Capture immutable references for the stream closure.
    let service = encryptionService
    let jsonDecoder = decoder

    return AsyncStream { continuation in
      for node in nodes {
        do {
          let plaintext = try service.decrypt(node.encryptedPayload, using: key)
          let event = try jsonDecoder.decode(SpatialEvent.self, from: plaintext)
          continuation.yield(event)
        } catch {
          Self.logger.error(
            "[AuraKit] EncryptedMemoryStore: Stream decrypt failed for node \(node.id) — \(error.localizedDescription)"
          )
          // Continue to next node — don't terminate the stream
        }
      }

      continuation.finish()
    }
  }
}
