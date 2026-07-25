// LargeDatasetWarningTests.swift
// AuraKitTests — Large Dataset Protection Verification
//
// Validates that EncryptedMemoryStore's allEvents() and recallAndFetchAll()
// continue to function correctly with large datasets, and that the
// configurable largeDatasetWarningThreshold is wired up correctly.

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Large Dataset Warning Tests

@Suite("EncryptedMemoryStore — Large Dataset Protection", .serialized)
struct LargeDatasetWarningTests {

  // MARK: - Helpers

  /// Creates a test store with a specific warning threshold.
  private func makeStore(
    warningThreshold: Int,
    key: SymmetricKey = SymmetricKey(size: .bits256)
  ) throws -> EncryptedMemoryStore {
    let container = try PersistenceController.makeInMemoryContainer()
    return EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: key),
      largeDatasetWarningThreshold: warningThreshold
    )
  }

  /// Populates the store with a given number of events.
  private func populateStore(
    _ store: EncryptedMemoryStore,
    count: Int
  ) async {
    let events = (0..<count).map { idx in
      SpatialEvent(
        kind: .interaction(type: .touch, position: .zero),
        score: Double(idx) * 0.001
      )
    }
    await store.batchAppend(events)
  }

  // MARK: - allEvents() Correctness Under Large Datasets

  @Test("allEvents() returns all events correctly above warning threshold")
  func allEventsCorrectAboveThreshold() async throws {
    let threshold = 50
    let eventCount = 75  // Above threshold
    let store = try makeStore(warningThreshold: threshold)

    await populateStore(store, count: eventCount)

    // allEvents() must still return ALL events — the warning is diagnostic only.
    let events = await store.allEvents()
    #expect(events.count == eventCount, "allEvents() must return all events regardless of threshold")
  }

  @Test("allEvents() works normally below warning threshold")
  func allEventsBelowThreshold() async throws {
    let threshold = 100
    let eventCount = 30  // Below threshold
    let store = try makeStore(warningThreshold: threshold)

    await populateStore(store, count: eventCount)

    let events = await store.allEvents()
    #expect(events.count == eventCount)
  }

  // MARK: - recallAndFetchAll() Correctness

  @Test("recallAndFetchAll() returns all events above threshold")
  func recallAndFetchAllAboveThreshold() async throws {
    let threshold = 20
    let eventCount = 50  // Above threshold
    let store = try makeStore(warningThreshold: threshold)

    await populateStore(store, count: eventCount)

    let events = await store.recallAndFetchAll()
    #expect(
      events.count == eventCount,
      "recallAndFetchAll() must return all events regardless of threshold"
    )
  }

  // MARK: - Threshold Configuration

  @Test("Warning threshold is configurable and stored correctly")
  func thresholdConfigurable() async throws {
    let customThreshold = 42
    let store = try makeStore(warningThreshold: customThreshold)

    #expect(
      store.largeDatasetWarningThreshold == customThreshold,
      "Stored threshold must match configured value"
    )
  }

  @Test("Warning threshold of 0 disables the warning")
  func thresholdZeroDisablesWarning() async throws {
    let store = try makeStore(warningThreshold: 0)
    await populateStore(store, count: 200)

    // allEvents() should still work — no crash, no issue
    let events = await store.allEvents()
    #expect(events.count == 200, "With threshold=0, allEvents() should work normally with no warning")
  }

  // MARK: - Default Threshold

  @Test("Default threshold matches AuraKitConstants value")
  func defaultThresholdMatchesConstant() throws {
    let container = try PersistenceController.makeInMemoryContainer()
    let store = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: SymmetricKey(size: .bits256))
    )

    #expect(
      store.largeDatasetWarningThreshold == AuraKitConstants.defaultLargeDatasetWarningThreshold,
      "Default threshold must match AuraKitConstants"
    )
  }

  // MARK: - AuraConfiguration Integration

  @Test("AuraConfiguration validates largeDatasetWarningThreshold")
  func configurationValidation() throws {
    // Valid: threshold = 0 (disabled)
    let disabledConfig = try AuraConfiguration(largeDatasetWarningThreshold: 0)
    #expect(disabledConfig.largeDatasetWarningThreshold == 0)

    // Valid: custom threshold
    let customConfig = try AuraConfiguration(largeDatasetWarningThreshold: 500)
    #expect(customConfig.largeDatasetWarningThreshold == 500)

    // Invalid: negative threshold
    #expect(throws: AuraError.self) {
      _ = try AuraConfiguration(largeDatasetWarningThreshold: -1)
    }
  }

  // MARK: - Paginated Alternative Correctness

  @Test("events(limit:offset:) avoids large dataset path")
  func paginatedAlternativeWorks() async throws {
    let store = try makeStore(warningThreshold: 20)
    await populateStore(store, count: 100)

    // Paginated fetch — no warning emitted, fetches only requested page
    let page = await store.events(limit: 10, offset: 0)
    #expect(page.count == 10, "Paginated fetch should return exactly the requested limit")

    // Verify pagination covers the full dataset
    var allPaginated: [SpatialEvent] = []
    for offset in stride(from: 0, to: 100, by: 25) {
      let chunk = await store.events(limit: 25, offset: offset)
      allPaginated.append(contentsOf: chunk)
    }
    #expect(allPaginated.count == 100, "Paginated reads should cover the full dataset")
  }

  // MARK: - Streaming Alternative Correctness

  @Test("eventStream() works as alternative to allEvents() for large datasets")
  func streamingAlternativeWorks() async throws {
    let store = try makeStore(warningThreshold: 20)
    let eventCount = 80
    await populateStore(store, count: eventCount)

    // Streaming decryption — constant peak memory
    var streamedEvents: [SpatialEvent] = []
    let stream = await store.eventStream(batchSize: 25)
    for await event in stream {
      streamedEvents.append(event)
    }

    #expect(
      streamedEvents.count == eventCount,
      "Streaming should yield all events"
    )
  }
}
