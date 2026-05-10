// EncryptionServiceTests.swift
// AuraKitTests — Phase 2: Security Layer
//
// Validates AES-GCM encrypt/decrypt round-trips, key mismatch detection,
// ciphertext integrity verification, and error propagation.

import CryptoKit
import Foundation
import Testing

@testable import AuraKit

// MARK: - EncryptionServiceTests

@Suite("EncryptionService — AES-GCM Operations")
struct EncryptionServiceTests {

  private let service = EncryptionService()

  /// Generate a fresh 256-bit test key.
  private func makeKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  // MARK: - Round-Trip

  @Test("Encrypt then decrypt returns original plaintext")
  func encryptDecryptRoundTrip() throws {
    let key = makeKey()
    let plaintext = Data("Hello, AuraKit — Phase 2!".utf8)

    let ciphertext = try service.encrypt(plaintext, using: key)
    let decrypted = try service.decrypt(ciphertext, using: key)

    #expect(decrypted == plaintext)
  }

  @Test("Round-trip preserves binary data with all byte values")
  func roundTripBinaryData() throws {
    let key = makeKey()
    let plaintext = Data(0...255)

    let ciphertext = try service.encrypt(plaintext, using: key)
    let decrypted = try service.decrypt(ciphertext, using: key)

    #expect(decrypted == plaintext)
  }

  @Test("Round-trip works for empty data")
  func roundTripEmptyData() throws {
    let key = makeKey()
    let plaintext = Data()

    let ciphertext = try service.encrypt(plaintext, using: key)
    let decrypted = try service.decrypt(ciphertext, using: key)

    #expect(decrypted == plaintext)
  }

  @Test("Round-trip works for large payload (1 MB)")
  func roundTripLargePayload() throws {
    let key = makeKey()
    let plaintext = Data(repeating: 0xAB, count: 1_000_000)

    let ciphertext = try service.encrypt(plaintext, using: key)
    let decrypted = try service.decrypt(ciphertext, using: key)

    #expect(decrypted == plaintext)
  }

  // MARK: - Ciphertext Properties

  @Test("Ciphertext is larger than plaintext by exactly nonce + tag overhead")
  func ciphertextSizeOverhead() throws {
    let key = makeKey()
    let plaintext = Data("Test payload".utf8)

    let ciphertext = try service.encrypt(plaintext, using: key)

    // AES-GCM combined: 12 (nonce) + plaintext.count + 16 (tag)
    let expectedSize = 12 + plaintext.count + 16
    #expect(ciphertext.count == expectedSize)
  }

  @Test("Ciphertext is NOT equal to plaintext")
  func ciphertextDiffersFromPlaintext() throws {
    let key = makeKey()
    let plaintext = Data("Sensitive spatial memory data".utf8)

    let ciphertext = try service.encrypt(plaintext, using: key)

    #expect(ciphertext != plaintext)
  }

  @Test("Two encryptions of same plaintext produce different ciphertexts (unique nonces)")
  func uniqueNoncesPerEncryption() throws {
    let key = makeKey()
    let plaintext = Data("Same input".utf8)

    let ciphertext1 = try service.encrypt(plaintext, using: key)
    let ciphertext2 = try service.encrypt(plaintext, using: key)

    #expect(ciphertext1 != ciphertext2, "Each encryption must use a unique nonce")
  }

  // MARK: - Key Mismatch

  @Test("Decryption with wrong key throws decryptionFailed")
  func wrongKeyThrows() throws {
    let encryptionKey = makeKey()
    let wrongKey = makeKey()
    let plaintext = Data("Secret".utf8)

    let ciphertext = try service.encrypt(plaintext, using: encryptionKey)

    #expect(throws: AuraError.self) {
      _ = try service.decrypt(ciphertext, using: wrongKey)
    }
  }

  // MARK: - Tampered Ciphertext

  @Test("Tampered ciphertext throws decryptionFailed")
  func tamperedCiphertextThrows() throws {
    let key = makeKey()
    let plaintext = Data("Integrity check".utf8)

    var ciphertext = try service.encrypt(plaintext, using: key)

    // Flip a byte in the ciphertext body (after the 12-byte nonce)
    if ciphertext.count > 14 {
      ciphertext[14] ^= 0xFF
    }

    #expect(throws: AuraError.self) {
      _ = try service.decrypt(ciphertext, using: key)
    }
  }

  @Test("Truncated ciphertext throws decryptionFailed")
  func truncatedCiphertextThrows() throws {
    let key = makeKey()
    let plaintext = Data("Truncation test".utf8)

    let ciphertext = try service.encrypt(plaintext, using: key)

    // Truncate to less than nonce + tag minimum
    let truncated = ciphertext.prefix(10)

    #expect(throws: AuraError.self) {
      _ = try service.decrypt(truncated, using: key)
    }
  }

  // MARK: - SpatialEvent Round-Trip

  @Test("SpatialEvent survives JSON + encryption round-trip")
  func spatialEventRoundTrip() throws {
    let key = makeKey()
    let event = SpatialEvent.touchFixture()

    let encoded = try JSONEncoder().encode(event)
    let ciphertext = try service.encrypt(encoded, using: key)
    let decrypted = try service.decrypt(ciphertext, using: key)
    let decoded = try JSONDecoder().decode(SpatialEvent.self, from: decrypted)

    #expect(decoded.id == event.id)
    #expect(decoded.kind == event.kind)
    #expect(decoded.score == event.score)
  }
}
