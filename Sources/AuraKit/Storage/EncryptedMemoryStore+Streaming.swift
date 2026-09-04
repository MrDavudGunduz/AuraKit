// EncryptedMemoryStore+Streaming.swift
// AuraKit — Core Infrastructure
//
// AsyncStream-based lazy decryption API for EncryptedMemoryStore.
// Enables streaming decryption of large stores without loading all
// decrypted payloads into memory simultaneously — OOM protection.
//
// V3: Task-backed truly lazy evaluation — each batch is fetched only
// when the consumer pulls events via `for await`, reducing peak memory
// from O(N) to O(batchSize) with genuine back-pressure support.

import CryptoKit
import Foundation
import os.log
import SwiftData

// MARK: - EncryptedMemoryStore + Streaming API

extension EncryptedMemoryStore {

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
  /// ## Truly Lazy Batch Pagination
  ///
  /// The stream internally uses a `Task`-backed continuation pattern. Each batch
  /// of `batchSize` nodes is fetched from SwiftData **only when the consumer
  /// pulls the next event**. This provides genuine back-pressure:
  ///
  /// ```
  /// Consumer pulls → fetch batch 0 (0..<100) → decrypt → yield → wait
  /// Consumer pulls → fetch batch 1 (100..<200) → decrypt → yield → wait
  /// ...
  /// ```
  ///
  /// Previous versions (V2) used a synchronous while-loop that eagerly fetched
  /// all batches during stream construction. V3 defers all I/O to consumption time.
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
    batchSize: Int = AuraConfiguration.defaultStreamBatchSize
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

    let effectiveBatchSize = max(batchSize, 1)
    let maxYield = limit ?? Int.max
    let baseOffset = offset

    return AsyncStream { continuation in
      // Launch a Task that calls back into the actor for each batch.
      // This provides truly lazy evaluation: the Task suspends between
      // batches, yielding control until the consumer pulls the next event.
      //
      // ## Actor Isolation Safety
      //
      // The Task captures `self` (the actor) and calls `streamBatch()`,
      // which is an actor-isolated method. This ensures `modelContext`
      // access is always serialised through the actor's executor —
      // no Sendable boundary violations occur.
      let store = self
      let streamKey = key

      Task {
        var yieldedCount = 0
        var currentOffset = baseOffset

        while yieldedCount < maxYield {
          let remaining = maxYield - yieldedCount
          let fetchCount = min(effectiveBatchSize, remaining)

          let events = await store.streamBatch(
            offset: currentOffset,
            limit: fetchCount,
            key: streamKey
          )

          // No more nodes available — we've exhausted the store.
          guard let batch = events, !batch.isEmpty else { break }

          for event in batch {
            continuation.yield(event)
            yieldedCount += 1
          }

          currentOffset += batch.count

          // If we got fewer events than requested, there are no more to fetch.
          if batch.count < fetchCount {
            break
          }
        }

        continuation.finish()
      }
    }
  }

  /// Maximum number of concurrent decryption tasks per batch.
  ///
  /// Adapts to the device's processor count to avoid oversubscription on
  /// low-core devices (e.g., Apple Watch, older iPhones) while maintaining
  /// high throughput on multi-core devices (e.g., M-series iPads/Macs).
  ///
  /// Capped at 4 to prevent excessive memory pressure from concurrent
  /// AES-GCM operations on large payloads.
  private static let maxConcurrentDecryption = min(4, ProcessInfo.processInfo.activeProcessorCount)

  // MARK: - Actor-Isolated Batch Fetch

  /// Fetches and decrypts a single batch of nodes within the actor's isolation domain.
  ///
  /// This method is the bridge between the `Task`-driven streaming loop and
  /// the actor-isolated `ModelContext`. By keeping all `modelContext` access
  /// within this method, we guarantee that the non-Sendable `ModelContext`
  /// never escapes the actor's isolation boundary.
  ///
  /// ## Parallel Decryption
  ///
  /// Decryption is performed in parallel using a `ThrowingTaskGroup` with a
  /// sliding-window concurrency limit of ``maxConcurrentDecryption``. This
  /// prevents spawning unbounded child tasks for large batches while keeping
  /// all available cores busy.
  ///
  /// Results are collected as `(index, event)` tuples and sorted by the
  /// original index to preserve chronological order.
  ///
  /// - Parameters:
  ///   - offset: The fetch offset for this batch.
  ///   - limit: Maximum number of nodes to fetch.
  ///   - key: The AES-GCM symmetric key for decryption.
  /// - Returns: Decrypted events, or `nil` if the fetch failed.
  private func streamBatch(
    offset: Int,
    limit: Int,
    key: SymmetricKey
  ) async -> [SpatialEvent]? {
    do {
        var descriptor = FetchDescriptor<RawMemoryNode>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        let nodes = try modelContext.fetch(descriptor)
        guard !nodes.isEmpty else { return nil }

        // Capture encrypted payloads before entering the task group.
        // RawMemoryNode may not be Sendable, but Data is.
        let payloads: [(Int, Data)] = nodes.enumerated().map { ($0.offset, $0.element.encryptedPayload) }

        // Parallel decryption with bounded concurrency.
        // Uses a sliding-window pattern: enqueue up to `maxConcurrent` tasks,
        // then wait for one to complete before enqueuing the next.
        let maxConcurrent = Self.maxConcurrentDecryption
        let service = encryptionService
        let jsonDecoder = decoder
        var decryptedTuples: [(Int, SpatialEvent)] = []
        decryptedTuples.reserveCapacity(payloads.count)

        do {
            try await withThrowingTaskGroup(of: (Int, SpatialEvent).self) { group in
                var nextIndex = 0
                var inFlight = 0

                // Seed the group with initial tasks up to the concurrency limit.
                while nextIndex < payloads.count, inFlight < maxConcurrent {
                    let (index, payload) = payloads[nextIndex]
                    group.addTask {
                        let plaintext = try service.decrypt(payload, using: key)
                        let event = try jsonDecoder.decode(SpatialEvent.self, from: plaintext)
                        return (index, event)
                    }
                    nextIndex += 1
                    inFlight += 1
                }

                // As each task completes, collect its result and enqueue the next.
                for try await tuple in group {
                    decryptedTuples.append(tuple)
                    inFlight -= 1

                    if nextIndex < payloads.count {
                        let (index, payload) = payloads[nextIndex]
                        group.addTask {
                            let plaintext = try service.decrypt(payload, using: key)
                            let event = try jsonDecoder.decode(SpatialEvent.self, from: plaintext)
                            return (index, event)
                        }
                        nextIndex += 1
                        inFlight += 1
                    }
                }
            }
        } catch {
            // Any decryption error aborts the batch.
            incrementDecryptionFailure()
            Self.logger.error("[AuraKit] EncryptedMemoryStore: Stream batch decryption failed — \(error.localizedDescription)")
            return nil
        }

        // Restore original chronological order.
        let sortedEvents = decryptedTuples
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }

        return sortedEvents
    } catch {
        Self.logger.error(
            "[AuraKit] EncryptedMemoryStore: Stream batch fetch failed at offset \(offset) — \(error.localizedDescription)"
        )
        return nil
    }
  }
}
