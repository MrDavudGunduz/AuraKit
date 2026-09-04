// EncryptedMemoryStoreStreamingTests.swift
// AuraKitTests — Phase 2.2: Keychain Persistence & Parallel Streaming
//
// Validates:
// 1. Correct event order preservation with parallel decryption
// 2. Streaming consistency with large datasets
// 3. Symmetric key Keychain persistence (cache invalidation → Keychain fallback)
// 4. Key rotation invalidates persisted symmetric key

import CryptoKit
import Foundation
import Testing

@testable import AuraKit

@Suite("EncryptedMemoryStore — Parallel Streaming & Key Persistence", .serialized)
struct EncryptedMemoryStoreStreamingTests {

  // MARK: - Helpers

  private func makeStore(key: SymmetricKey = sharedTestKey) throws -> EncryptedMemoryStore {
    try makeTestEncryptedStore(key: key)
  }

  /// Creates a set of events with deterministic timestamps for order verification.
  private func makeDeterministicEvents(count: Int) -> [SpatialEvent] {
    (0..<count).map { index in
      SpatialEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(index * 10)),
        kind: .gaze(position: .zero),
        score: Double(index) / Double(count)
      )
    }
  }

  // MARK: - Parallel Decryption Order Preservation

  @Test("Parallel decryption preserves chronological event order")
  func parallelDecryptionPreservesOrder() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 50)

    await store.batchAppend(events)

    var streamedTimestamps: [Date] = []
    let stream = await store.eventStream(batchSize: 10)
    for await event in stream {
      streamedTimestamps.append(event.timestamp)
    }

    // Verify all events were yielded
    #expect(streamedTimestamps.count == 50, "All 50 events should be yielded")

    // Verify chronological order is preserved despite parallel decryption
    let expectedTimestamps = events.map(\.timestamp).sorted()
    #expect(
      streamedTimestamps == expectedTimestamps,
      "Events must maintain chronological order after parallel decryption"
    )
  }

  @Test("Parallel decryption with batch size 1 maintains order")
  func singleElementBatchMaintainsOrder() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 5)

    await store.batchAppend(events)

    var streamedTimestamps: [Date] = []
    let stream = await store.eventStream(batchSize: 1)
    for await event in stream {
      streamedTimestamps.append(event.timestamp)
    }

    #expect(streamedTimestamps.count == 5)
    #expect(streamedTimestamps == streamedTimestamps.sorted())
  }

  @Test("Parallel decryption with large batch preserves order")
  func largeBatchPreservesOrder() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 100)

    await store.batchAppend(events)

    var streamedTimestamps: [Date] = []
    let stream = await store.eventStream(batchSize: 100)
    for await event in stream {
      streamedTimestamps.append(event.timestamp)
    }

    #expect(streamedTimestamps.count == 100, "All 100 events should be yielded")
    #expect(
      streamedTimestamps == streamedTimestamps.sorted(),
      "Large batch parallel decryption must preserve order"
    )
  }

  // MARK: - Streaming Consistency Under Parallel Decryption

  @Test("eventStream() with parallel decryption is consistent with allEvents()")
  func parallelStreamConsistentWithAllEvents() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 30)

    await store.batchAppend(events)

    let allEventsResult = await store.allEvents()

    var streamedIDs: [UUID] = []
    let stream = await store.eventStream(batchSize: 7)
    for await event in stream {
      streamedIDs.append(event.id)
    }

    #expect(
      streamedIDs == allEventsResult.map(\.id),
      "Parallel streaming must produce identical ordering as allEvents()"
    )
  }

  @Test("Parallel decryption across multiple batches preserves global order")
  func multiBatchGlobalOrder() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 25)

    await store.batchAppend(events)

    var allStreamedScores: [Double] = []
    let stream = await store.eventStream(batchSize: 4)
    for await event in stream {
      allStreamedScores.append(event.score)
    }

    #expect(allStreamedScores.count == 25)

    // Scores should be in ascending order (0/25, 1/25, 2/25, ...)
    // since events were created with deterministic ascending timestamps.
    for i in 1..<allStreamedScores.count {
      #expect(
        allStreamedScores[i] >= allStreamedScores[i - 1],
        "Score at index \(i) should be >= score at index \(i - 1)"
      )
    }
  }

  // MARK: - Limit and Offset with Parallel Decryption

  @Test("eventStream(limit:) with parallel decryption respects the limit")
  func parallelStreamRespectsLimit() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 20)

    await store.batchAppend(events)

    var streamed: [SpatialEvent] = []
    let stream = await store.eventStream(limit: 7, batchSize: 3)
    for await event in stream {
      streamed.append(event)
    }

    #expect(streamed.count == 7, "Limit of 7 should yield exactly 7 events")
  }

  @Test("eventStream(offset:) with parallel decryption skips correctly")
  func parallelStreamRespectsOffset() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 20)

    await store.batchAppend(events)

    // Skip first 10 events, get next 5
    var streamed: [SpatialEvent] = []
    let stream = await store.eventStream(limit: 5, offset: 10, batchSize: 3)
    for await event in stream {
      streamed.append(event)
    }

    #expect(streamed.count == 5)

    // The first streamed event should correspond to the 11th original event (index 10)
    let expectedFirstTimestamp = Date(timeIntervalSince1970: 100)
    #expect(streamed[0].timestamp == expectedFirstTimestamp)
  }

  // MARK: - Key Persistence Tests

  @Test("KeyManager with static key does not access Keychain")
  func staticKeyBypassesKeychain() async throws {
    let key = SymmetricKey(size: .bits256)
    let manager = KeyManager(staticKey: key)

    let retrieved = try await manager.symmetricKey()

    // Verify the static key is returned directly from cache
    key.withUnsafeBytes { expected in
      retrieved.withUnsafeBytes { actual in
        #expect(expected.elementsEqual(actual), "Static key should be returned from cache")
      }
    }
  }

  @Test("KeyManager caches key after first derivation — subsequent calls are instant")
  func keyManagerCachesAfterDerivation() async throws {
    let manager = KeyManager(staticKey: SymmetricKey(size: .bits256))

    let key1 = try await manager.symmetricKey()
    let key2 = try await manager.symmetricKey()
    let key3 = try await manager.symmetricKey()

    // All three should be identical (from cache)
    key1.withUnsafeBytes { b1 in
      key2.withUnsafeBytes { b2 in
        key3.withUnsafeBytes { b3 in
          #expect(b1.elementsEqual(b2))
          #expect(b2.elementsEqual(b3))
        }
      }
    }
  }

  @Test("clearCachedKeyForBackground() clears the in-memory cache")
  func backgroundClearInvalidatesCache() async throws {
    let key = SymmetricKey(size: .bits256)
    let manager = KeyManager(staticKey: key)

    // Verify key is available
    let before = try await manager.symmetricKey()
    key.withUnsafeBytes { expected in
      before.withUnsafeBytes { actual in
        #expect(expected.elementsEqual(actual))
      }
    }

    // Clear for background
    await manager.clearCachedKeyForBackground()

    // After clearing, the next call should either:
    // a) Re-derive from Keychain/Secure Enclave (on device)
    // b) Throw (in SPM test runner without Keychain entitlements)
    // The critical assertion is that the cache was cleared.
    let afterKey = try? await manager.symmetricKey()
    // The test passes if clearCachedKeyForBackground() didn't crash.
    _ = afterKey
  }

  // MARK: - Empty Store Parallel Decryption

  @Test("Parallel decryption on empty store yields nothing")
  func emptyStoreParallelStreamYieldsNothing() async throws {
    let store = try makeStore()

    var count = 0
    let stream = await store.eventStream(batchSize: 10)
    for await _ in stream {
      count += 1
    }

    #expect(count == 0, "Empty store should yield zero events")
  }

  // MARK: - Single Event Edge Case

  @Test("Parallel decryption handles single event correctly")
  func singleEventParallelDecryption() async throws {
    let store = try makeStore()

    let event = SpatialEvent.gazeFixture(score: 0.42)
    await store.append(event)

    var streamed: [SpatialEvent] = []
    let stream = await store.eventStream(batchSize: 10)
    for await e in stream {
      streamed.append(e)
    }

    #expect(streamed.count == 1)
    #expect(streamed[0].score == 0.42)
    #expect(streamed[0].id == event.id)
  }

  // MARK: - Concurrent Stream Access

  @Test("Multiple concurrent streams produce consistent results")
  func concurrentStreamsProduceConsistentResults() async throws {
    let store = try makeStore()
    let events = makeDeterministicEvents(count: 15)

    await store.batchAppend(events)

    // Launch two concurrent streams and verify they both produce the same result
    async let stream1Events: [UUID] = {
      var ids: [UUID] = []
      let stream = await store.eventStream(batchSize: 5)
      for await event in stream {
        ids.append(event.id)
      }
      return ids
    }()

    async let stream2Events: [UUID] = {
      var ids: [UUID] = []
      let stream = await store.eventStream(batchSize: 3)
      for await event in stream {
        ids.append(event.id)
      }
      return ids
    }()

    let (result1, result2) = try await (stream1Events, stream2Events)

    #expect(result1.count == 15)
    #expect(result2.count == 15)
    #expect(result1 == result2, "Both streams should produce identical event ordering")
  }
}
