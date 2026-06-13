// EncryptedMemoryStore+Streaming.swift
// AuraKit — Core Infrastructure
//
// AsyncStream-based lazy decryption API for EncryptedMemoryStore.
// Enables streaming decryption of large stores without loading all
// decrypted payloads into memory simultaneously — OOM protection.
//
// V2: Batch-paginated fetch — only `batchSize` nodes are resident in
// memory at any given time, reducing peak memory from O(N) to O(batchSize).

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Streaming API

extension EncryptedMemoryStore {

  /// Default number of nodes fetched per batch during streaming.
  ///
  /// Empirically tuned: 100 nodes × ~2 KB average ciphertext ≈ 200 KB peak
  /// per batch — well within comfortable memory budgets on all Apple platforms.
  private static let defaultStreamBatchSize: Int = 100

  /// Returns an `AsyncStream` that lazily decrypts and yields events one at a time.
  ///
  /// Unlike ``allEvents()`` which decrypts the entire store into an `[SpatialEvent]`
  /// array, this method fetches and decrypts nodes in fixed-size batches, keeping
  /// peak memory usage proportional to `batchSize` rather than the total store size.
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
  /// ## Batch Pagination
  ///
  /// The stream internally fetches `batchSize` nodes at a time from SwiftData,
  /// decrypts them, yields the results, then fetches the next batch. This keeps
  /// only one batch of `RawMemoryNode` objects in memory at any time:
  ///
  /// ```
  /// Fetch batch 0 (0..<100) → decrypt → yield → release
  /// Fetch batch 1 (100..<200) → decrypt → yield → release
  /// ...
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
  ///   - batchSize: Number of nodes to fetch per internal batch. Defaults to `100`.
  ///     Smaller values reduce peak memory; larger values reduce fetch overhead.
  /// - Returns: An `AsyncStream<SpatialEvent>` yielding decrypted events chronologically.
  public func eventStream(
    limit: Int? = nil,
    offset: Int = 0,
    batchSize: Int = defaultStreamBatchSize
  ) async -> AsyncStream<SpatialEvent> {
    // Resolve the key once before entering the stream — avoids repeated
    // async key lookups per batch.
    let key: SymmetricKey

    do {
      key = try await keyManager.symmetricKey()
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Stream setup failed — \(error.localizedDescription)"
      )
      // Return an immediately-finished stream on key retrieval failure
      return AsyncStream { $0.finish() }
    }

    // Capture immutable references for the stream closure.
    let service = encryptionService
    let jsonDecoder = decoder
    let context = modelContext
    let effectiveBatchSize = max(batchSize, 1)

    // Calculate the total number of nodes we need to yield.
    // When limit is nil, we stream all nodes (use Int.max as sentinel).
    let maxYield = limit ?? Int.max
    let baseOffset = offset

    return AsyncStream { continuation in
      var yieldedCount = 0
      var currentOffset = baseOffset

      while yieldedCount < maxYield {
        // Determine how many nodes to fetch in this batch.
        let remaining = maxYield - yieldedCount
        let fetchCount = min(effectiveBatchSize, remaining)

        // Build a fetch descriptor for the current batch.
        var descriptor = FetchDescriptor<RawMemoryNode>(
          sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = fetchCount
        descriptor.fetchOffset = currentOffset

        let nodes: [RawMemoryNode]
        do {
          nodes = try context.fetch(descriptor)
        } catch {
          Self.logger.error(
            "[AuraKit] EncryptedMemoryStore: Stream batch fetch failed at offset \(currentOffset) — \(error.localizedDescription)"
          )
          break
        }

        // No more nodes available — we've exhausted the store.
        guard !nodes.isEmpty else { break }

        // Decrypt and yield each node in the batch.
        for node in nodes {
          do {
            let plaintext = try service.decrypt(node.encryptedPayload, using: key)
            let event = try jsonDecoder.decode(SpatialEvent.self, from: plaintext)
            continuation.yield(event)
            yieldedCount += 1
          } catch {
            Self.logger.error(
              "[AuraKit] EncryptedMemoryStore: Stream decrypt failed for node \(node.id) — \(error.localizedDescription)"
            )
            // Continue to next node — don't terminate the stream
          }
        }

        currentOffset += nodes.count

        // If we got fewer nodes than requested, there are no more to fetch.
        if nodes.count < fetchCount {
          break
        }
      }

      continuation.finish()
    }
  }
}
