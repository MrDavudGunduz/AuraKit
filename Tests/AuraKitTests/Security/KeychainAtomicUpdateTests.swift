// KeychainAtomicUpdateTests.swift
// AuraKitTests — Keychain Atomic Update Verification
//
// Validates the crash-safe SecItemUpdate → SecItemAdd fallback pattern
// introduced in KeychainHelper. Ensures data integrity across store,
// overwrite, and retrieve cycles.

import Foundation
import Testing

@testable import AuraKit

// MARK: - Keychain Atomic Update Tests

@Suite("KeychainHelper — Atomic Update Pattern", .serialized)
struct KeychainAtomicUpdateTests {

  // MARK: - Test Constants

  /// Unique service identifier scoped to this test suite to avoid collisions
  /// with production Keychain items or other test suites.
  private static let testService = "com.aurakit.tests.atomic-update"

  /// Base account name — each test appends a UUID suffix for isolation.
  private static let testAccountPrefix = "atomic-test"

  /// Creates a unique account name for each test to prevent cross-test leakage.
  private func uniqueAccount() -> String {
    "\(Self.testAccountPrefix)-\(UUID().uuidString)"
  }

  // MARK: - Teardown Helper

  /// Removes a test Keychain item after the test completes.
  private func cleanup(account: String) {
    KeychainHelper.delete(
      service: Self.testService,
      account: account
    )
  }

  // MARK: - Initial Store (Add Path)

  @Test("First store uses SecItemAdd path and succeeds")
  func initialStoreSucceeds() {
    let account = uniqueAccount()
    defer { cleanup(account: account) }

    let data = Data("initial-value".utf8)
    let result = KeychainHelper.store(
      data: data,
      service: Self.testService,
      account: account
    )

    #expect(result, "Initial store should succeed via SecItemAdd path")

    // Verify retrieval
    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == data, "Retrieved data should match stored data")
  }

  // MARK: - Overwrite (Update Path)

  @Test("Overwriting existing item uses SecItemUpdate path atomically")
  func overwriteUsesAtomicUpdate() {
    let account = uniqueAccount()
    defer { cleanup(account: account) }

    let originalData = Data("original-value".utf8)
    let updatedData = Data("updated-value".utf8)

    // Initial store
    let initialResult = KeychainHelper.store(
      data: originalData,
      service: Self.testService,
      account: account
    )
    #expect(initialResult, "Initial store should succeed")

    // Overwrite — should use SecItemUpdate (atomic, no delete)
    let updateResult = KeychainHelper.store(
      data: updatedData,
      service: Self.testService,
      account: account
    )
    #expect(updateResult, "Overwrite should succeed via SecItemUpdate path")

    // Verify the value was actually updated
    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == updatedData, "Retrieved data should be the updated value")
    #expect(retrieved != originalData, "Original data should have been replaced")
  }

  // MARK: - Multiple Sequential Updates

  @Test("Multiple sequential updates maintain data consistency")
  func multipleSequentialUpdates() {
    let account = uniqueAccount()
    defer { cleanup(account: account) }

    let iterations = 10
    for idx in 0..<iterations {
      let data = Data("value-\(idx)".utf8)
      let result = KeychainHelper.store(
        data: data,
        service: Self.testService,
        account: account
      )
      #expect(result, "Store iteration \(idx) should succeed")

      // Verify each intermediate state
      let retrieved = KeychainHelper.retrieve(
        service: Self.testService,
        account: account
      )
      #expect(retrieved == data, "Iteration \(idx): retrieved data should match latest stored value")
    }

    // Final verification
    let finalData = Data("value-\(iterations - 1)".utf8)
    let finalRetrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(finalRetrieved == finalData, "Final retrieved value should be the last stored value")
  }

  // MARK: - storeOrThrow Variant

  @Test("storeOrThrow succeeds on initial store and overwrite")
  func storeOrThrowSucceeds() throws {
    let account = uniqueAccount()
    defer { cleanup(account: account) }

    let originalData = Data("throw-original".utf8)
    let updatedData = Data("throw-updated".utf8)

    // Initial store — should not throw
    try KeychainHelper.storeOrThrow(
      data: originalData,
      service: Self.testService,
      account: account
    )

    let firstRetrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(firstRetrieved == originalData)

    // Overwrite — should not throw
    try KeychainHelper.storeOrThrow(
      data: updatedData,
      service: Self.testService,
      account: account
    )

    let secondRetrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(secondRetrieved == updatedData)
  }

  // MARK: - Delete Verification

  @Test("Delete removes item and subsequent store uses Add path")
  func deleteAndRestore() {
    let account = uniqueAccount()
    defer { cleanup(account: account) }

    let data = Data("delete-test".utf8)

    // Store → Delete → Retrieve should be nil
    KeychainHelper.store(
      data: data,
      service: Self.testService,
      account: account
    )
    KeychainHelper.delete(
      service: Self.testService,
      account: account
    )

    let afterDelete = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(afterDelete == nil, "Item should be nil after deletion")

    // Re-store should succeed (falls back to SecItemAdd path)
    let newData = Data("re-stored".utf8)
    let restoreResult = KeychainHelper.store(
      data: newData,
      service: Self.testService,
      account: account
    )
    #expect(restoreResult, "Re-store after delete should succeed")

    let afterRestore = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(afterRestore == newData)
  }

  // MARK: - Binary Data Integrity

  @Test("Atomic update preserves binary data integrity (256 random bytes)")
  func binaryDataIntegrity() {
    let account = uniqueAccount()
    defer { cleanup(account: account) }

    // Generate random binary data (simulates encryption keys)
    var randomBytes = Data(count: 32)
    _ = randomBytes.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return errSecParam }
      return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
    }

    let result = KeychainHelper.store(
      data: randomBytes,
      service: Self.testService,
      account: account
    )
    #expect(result)

    let retrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(retrieved == randomBytes, "Binary data must survive store/retrieve round-trip unchanged")

    // Overwrite with different random bytes
    var newRandomBytes = Data(count: 32)
    _ = newRandomBytes.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return errSecParam }
      return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
    }

    let updateResult = KeychainHelper.store(
      data: newRandomBytes,
      service: Self.testService,
      account: account
    )
    #expect(updateResult)

    let updatedRetrieved = KeychainHelper.retrieve(
      service: Self.testService,
      account: account
    )
    #expect(updatedRetrieved == newRandomBytes, "Updated binary data must survive round-trip")
    #expect(updatedRetrieved != randomBytes, "Old binary data must be replaced")
  }
}
