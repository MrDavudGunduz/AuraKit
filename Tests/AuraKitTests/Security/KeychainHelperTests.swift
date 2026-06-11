// KeychainHelperTests.swift
// AuraKitTests — Security Layer
//
// Direct unit tests for KeychainHelper's store, retrieve, delete, and
// throwing variant methods. Validates Keychain round-trip behaviour and
// error propagation via AuraError.keychainOperationFailed.

import Foundation
import Testing

@testable import AuraKit

// MARK: - KeychainHelper Tests

@Suite("Security — KeychainHelper")
struct KeychainHelperTests {

  /// Unique service/account pair per test to prevent cross-test interference.
  private static let testService = "com.aurakit.tests.keychainhelper"

  /// Returns a unique account identifier to isolate test state.
  private func uniqueAccount() -> String {
    "test-\(UUID().uuidString)"
  }

  // MARK: - Store / Retrieve Round-Trip

  @Test("Store and retrieve round-trip returns identical data")
  func storeRetrieveRoundTrip() {
    let account = uniqueAccount()
    let testData = Data("AuraKit-KeychainTest-\(UUID())".utf8)

    let stored = KeychainHelper.store(
      data: testData,
      service: Self.testService,
      account: account
    )
    #expect(stored, "Store should succeed")

    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == testData, "Retrieved data should match stored data")

    // Cleanup
    KeychainHelper.delete(service: Self.testService, account: account)
  }

  // MARK: - Overwrite (Upsert) Behaviour

  @Test("Store overwrites existing item with same service/account")
  func storeOverwritesExisting() {
    let account = uniqueAccount()
    let firstData = Data("first-value".utf8)
    let secondData = Data("second-value".utf8)

    KeychainHelper.store(data: firstData, service: Self.testService, account: account)
    KeychainHelper.store(data: secondData, service: Self.testService, account: account)

    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == secondData, "Second store should overwrite the first")

    // Cleanup
    KeychainHelper.delete(service: Self.testService, account: account)
  }

  // MARK: - Retrieve Non-Existent Key

  @Test("Retrieve returns nil for non-existent key")
  func retrieveNonExistentReturnsNil() {
    let result = KeychainHelper.retrieve(
      service: Self.testService,
      account: "non-existent-\(UUID())"
    )
    #expect(result == nil, "Non-existent key should return nil")
  }

  // MARK: - Delete

  @Test("Delete removes stored item")
  func deleteRemovesStoredItem() {
    let account = uniqueAccount()
    let testData = Data("to-be-deleted".utf8)

    KeychainHelper.store(data: testData, service: Self.testService, account: account)

    let deleted = KeychainHelper.delete(
      service: Self.testService,
      account: account
    )
    #expect(deleted, "Delete should succeed for existing item")

    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == nil, "Deleted item should not be retrievable")
  }

  @Test("Delete non-existent key returns false")
  func deleteNonExistentReturnsFalse() {
    let result = KeychainHelper.delete(
      service: Self.testService,
      account: "non-existent-\(UUID())"
    )
    #expect(!result, "Delete of non-existent item should return false")
  }

  // MARK: - Throwing Variants

  @Test("storeOrThrow succeeds for valid data")
  func storeOrThrowSucceeds() throws {
    let account = uniqueAccount()
    let testData = Data("throwing-test".utf8)

    try KeychainHelper.storeOrThrow(
      data: testData,
      service: Self.testService,
      account: account
    )

    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == testData)

    // Cleanup
    KeychainHelper.delete(service: Self.testService, account: account)
  }

  @Test("deleteOrThrow throws keychainOperationFailed for non-existent item")
  func deleteOrThrowThrowsForNonExistent() {
    let account = "non-existent-\(UUID())"

    #expect(throws: AuraError.self) {
      try KeychainHelper.deleteOrThrow(
        service: Self.testService,
        account: account
      )
    }
  }
}
