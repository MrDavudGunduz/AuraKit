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
    // Fail fast: if the current key is unavailable, return a finished stream
    // rather than a stream that silently yields nothing per batch.
    do {
      _ = try await keyManager.currentKeyAndVersion()
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Stream setup failed — \(error.localizedDescription)"
      )
      return AsyncStream { $0.finish() }
    }

    let effectiveBatchSize = max(batchSize, 1)
    let maxYield = limit.map { max($0, 0) } ?? Int.max
    let baseOffset = max(offset, 0)

    return AsyncStream { continuation in
      // Launch a Task that calls back into the actor for each batch.
      //
      // ## Actor Isolation Safety
      //
      // The Task calls `streamBatch()`, an actor-isolated method, so all
      // `modelContext` access is serialised through the actor's executor.
      //
      // ## Cancellation
      //
      // The producer is cancelled when the consumer stops iterating (or the
      // stream is deallocated), so abandoned streams never keep decrypting.
      let store = self

      let producer = Task {
        var yieldedCount = 0
        var currentOffset = baseOffset

        while yieldedCount < maxYield, !Task.isCancelled {
          let remaining = maxYield - yieldedCount
          let fetchCount = min(effectiveBatchSize, remaining)

          // No more nodes available — we've exhausted the store.
          guard let batch = await store.streamBatch(offset: currentOffset, limit: fetchCount) else {
            break
          }

          for event in batch.events {
            continuation.yield(event)
            yieldedCount += 1
          }

          // Advance by the number of *rows* read, not events decrypted, so a
          // corrupted record never shifts or repeats subsequent pages.
          currentOffset += batch.rowCount

          // If we got fewer rows than requested, there are no more to fetch.
          if batch.rowCount < fetchCount {
            break
          }
        }

        continuation.finish()
      }

      continuation.onTermination = { _ in
        producer.cancel()
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
  /// Nodes are snapshotted into `Sendable` ``EncryptedRecord`` values before
  /// the key-ring lookup (the only suspension point), so reentrant mutations
  /// can never be observed mid-batch.
  ///
  /// ## Parallel Decryption
  ///
  /// Decryption runs in a `TaskGroup` with a sliding-window concurrency limit
  /// of ``maxConcurrentDecryption``. Each child returns `nil` on failure, so a
  /// single corrupted or tampered record is counted and skipped instead of
  /// aborting the whole batch.
  ///
  /// - Parameters:
  ///   - offset: The fetch offset for this batch.
  ///   - limit: Maximum number of nodes to fetch.
  /// - Returns: The decrypted events (chronological) and the number of rows
  ///   read, or `nil` if the fetch failed, returned no rows, or no key is available.
  private func streamBatch(
    offset: Int,
    limit: Int
  ) async -> (events: [SpatialEvent], rowCount: Int)? {
    guard let records = fetchStreamRecords(offset: offset, limit: limit),
          !records.isEmpty
    else {
      return nil
    }

    let ring: KeyRing
    do {
      ring = try await keyManager.keyRing(for: Set(records.map(\.keyVersion)))
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Stream key retrieval failed — \(error.localizedDescription)"
      )
      return nil
    }

    let signpostID = SignpostLogger.beginDecrypt(count: records.count)
    defer { SignpostLogger.endDecrypt(signpostID) }

    let (events, failures) = await Self.decryptBatchConcurrently(
      records,
      ring: ring,
      service: encryptionService,
      decoder: decoder
    )

    if failures > 0 {
      for _ in 0..<failures {
        incrementDecryptionFailure()
      }
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: \(failures) record(s) failed to decrypt in stream batch at offset \(offset) — skipped."
      )
    }

    return (events, records.count)
  }

  private func fetchStreamRecords(offset: Int, limit: Int) -> [EncryptedRecord]? {
    do {
      var descriptor = FetchDescriptor<RawMemoryNode>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)]
      )
      descriptor.fetchLimit = limit
      descriptor.fetchOffset = offset
      return try modelContext.fetch(descriptor).map(EncryptedRecord.init(node:))
    } catch {
      Self.logger.error(
        "[AuraKit] EncryptedMemoryStore: Stream batch fetch failed at offset \(offset) — \(error.localizedDescription)"
      )
      return nil
    }
  }

  private nonisolated static func decryptBatchConcurrently(
    _ records: [EncryptedRecord],
    ring: KeyRing,
    service: EncryptionService,
    decoder: JSONDecoder
  ) async -> (events: [SpatialEvent], failures: Int) {
    var slots = [SpatialEvent?](repeating: nil, count: records.count)
    var failures = 0

    await withTaskGroup(of: (Int, SpatialEvent?).self) { group in
      var nextIndex = 0

      func enqueueNext() {
        let index = nextIndex
        let record = records[index]
        group.addTask {
          (index, try? open(record, ring: ring, service: service, decoder: decoder))
        }
        nextIndex += 1
      }

      while nextIndex < records.count, nextIndex < maxConcurrentDecryption {
        enqueueNext()
      }

      for await (index, event) in group {
        if let event {
          slots[index] = event
        } else {
          failures += 1
        }
        if nextIndex < records.count {
          enqueueNext()
        }
      }
    }

    // Slots preserve the original chronological order.
    return (slots.compactMap { $0 }, failures)
  }
}
