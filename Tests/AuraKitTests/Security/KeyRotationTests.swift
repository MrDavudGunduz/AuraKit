// KeyRotationTests.swift
// AuraKitTests — Phase 2.1: Key Rotation
//
// Validates key rotation lifecycle: new key derivation, previous key
// preservation, version tracking, concurrent rotation safety, and
// fail-safe rollback behaviour.

import CryptoKit
import Foundation
import Testing

@testable import AuraKit

@Suite("KeyManager — Key Rotation")
struct KeyRotationTests {

  // MARK: - Helpers

  private func makeStaticKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  private func keysAreEqual(_ a: SymmetricKey, _ b: SymmetricKey) -> Bool {
    a.withUnsafeBytes { aBytes in
      b.withUnsafeBytes { bBytes in
        aBytes.elementsEqual(bBytes)
      }
    }
  }

  // MARK: - Basic Rotation

  @Test("rotateKey() returns the previous key")
  func rotateKeyReturnsPreviousKey() async throws {
    let original = makeStaticKey()
    let manager = KeyManager(staticKey: original)

    // Ensure original key is cached
    let keyBefore = try await manager.symmetricKey()
    #expect(keysAreEqual(keyBefore, original))

    // Rotate — should return the original key
    let previousKey = try await manager.rotateKey()
    #expect(previousKey != nil)
    #expect(keysAreEqual(previousKey!, original))
  }

  @Test("rotateKey() produces a different key than the original")
  func rotateKeyProducesDifferentKey() async throws {
    let original = makeStaticKey()
    let manager = KeyManager(staticKey: original)

    // Cache the original
    _ = try await manager.symmetricKey()

    // Rotate
    _ = try await manager.rotateKey()
    let newKey = try await manager.symmetricKey()

    // New key should differ from the original (derived from new salt)
    #expect(!keysAreEqual(newKey, original))
  }

  // MARK: - Previous Key Access

  @Test("previousKey is accessible after rotation")
  func previousKeyAvailableAfterRotation() async throws {
    let original = makeStaticKey()
    let manager = KeyManager(staticKey: original)

    // Cache and rotate
    _ = try await manager.symmetricKey()
    _ = try await manager.rotateKey()

    let previous = await manager.previousKey
    #expect(previous != nil)
    #expect(keysAreEqual(previous!, original))
  }

  @Test("previousKey is nil before any rotation")
  func previousKeyNilBeforeRotation() async throws {
    let manager = KeyManager(staticKey: makeStaticKey())
    let previous = await manager.previousKey
    #expect(previous == nil)
  }

  @Test("clearPreviousKey() removes the preserved key")
  func clearPreviousKeyRemovesKey() async throws {
    let manager = KeyManager(staticKey: makeStaticKey())
    _ = try await manager.symmetricKey()
    _ = try await manager.rotateKey()

    // Previous key should exist
    #expect(await manager.previousKey != nil)

    // Clear it
    await manager.clearPreviousKey()
    #expect(await manager.previousKey == nil)
  }

  // MARK: - Key Version

  @Test("keyVersion starts at 0")
  func keyVersionStartsAtZero() async {
    let manager = KeyManager(staticKey: makeStaticKey())
    #expect(await manager.keyVersion == 0)
  }

  @Test("keyVersion increments on each rotation")
  func keyVersionIncrements() async throws {
    let manager = KeyManager(staticKey: makeStaticKey())
    _ = try await manager.symmetricKey()

    #expect(await manager.keyVersion == 0)

    _ = try await manager.rotateKey()
    #expect(await manager.keyVersion == 1)

    _ = try await manager.rotateKey()
    #expect(await manager.keyVersion == 2)
  }

  // MARK: - Encryption Round-Trip After Rotation

  @Test("Data encrypted with old key can be decrypted after rotation using previousKey")
  func reEncryptionMigrationRoundTrip() async throws {
    let manager = KeyManager(staticKey: makeStaticKey())
    let service = EncryptionService()

    // Encrypt with original key
    let originalKey = try await manager.symmetricKey()
    let plaintext = Data("sensitive spatial data".utf8)
    let ciphertext = try service.encrypt(plaintext, using: originalKey)

    // Rotate
    _ = try await manager.rotateKey()

    // Decrypt with previous key (migration path)
    let previousKey = await manager.previousKey
    #expect(previousKey != nil)
    let decrypted = try service.decrypt(ciphertext, using: previousKey!)
    #expect(decrypted == plaintext)

    // Re-encrypt with new key
    let newKey = try await manager.symmetricKey()
    let reEncrypted = try service.encrypt(decrypted, using: newKey)
    let finalDecrypted = try service.decrypt(reEncrypted, using: newKey)
    #expect(finalDecrypted == plaintext)
  }

  // MARK: - Concurrent Rotation Safety

  @Test("Concurrent rotateKey() calls are serialised (actor safety)")
  func concurrentRotationSafety() async throws {
    let manager = KeyManager(staticKey: makeStaticKey())
    _ = try await manager.symmetricKey()

    // Fire multiple concurrent rotations — actor serialises them
    try await withThrowingTaskGroup(of: SymmetricKey?.self) { group in
      for _ in 0..<5 {
        group.addTask { try await manager.rotateKey() }
      }
      for try await _ in group {
        // All rotations should complete without crash or data race
      }
    }

    // Version should be 5 after 5 rotations
    #expect(await manager.keyVersion == 5)
  }

  // MARK: - Double Rotation

  @Test("Second rotation overwrites previousKey with the first rotation's key")
  func doubleRotationOverwritesPreviousKey() async throws {
    let original = makeStaticKey()
    let manager = KeyManager(staticKey: original)
    _ = try await manager.symmetricKey()

    // First rotation: previousKey = original
    _ = try await manager.rotateKey()
    let keyAfterFirstRotation = try await manager.symmetricKey()

    // Second rotation: previousKey = keyAfterFirstRotation (not original)
    _ = try await manager.rotateKey()
    let previousAfterSecond = await manager.previousKey
    #expect(previousAfterSecond != nil)
    #expect(keysAreEqual(previousAfterSecond!, keyAfterFirstRotation))
    #expect(!keysAreEqual(previousAfterSecond!, original))
  }
}
