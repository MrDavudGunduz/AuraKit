// EncryptionService.swift
// AuraKit — Security Layer
//
// Stateless AES-GCM encryption and decryption primitives.
// All operations use CryptoKit and never persist key material to disk.
// The combined ciphertext format is: nonce (12 bytes) || ciphertext || tag (16 bytes).

import CryptoKit
import Foundation

// MARK: - EncryptionService

/// A stateless, `Sendable` service that encrypts and decrypts `Data` payloads
/// using AES-GCM authenticated encryption.
///
/// `EncryptionService` is the **lowest-level** cryptographic primitive in AuraKit's
/// security stack. It performs raw seal/open operations and is consumed by
/// ``KeyManager`` and ``EncryptedMemoryStore`` — never called directly by
/// host applications.
///
/// ## Ciphertext Format
///
/// The combined output from ``encrypt(_:using:)`` is a contiguous `Data` blob:
///
/// ```
/// ┌─────────┬────────────┬─────────┐
/// │ Nonce   │ Ciphertext │ Auth Tag│
/// │ 12 bytes│ N bytes    │ 16 bytes│
/// └─────────┴────────────┴─────────┘
/// ```
///
/// This matches the layout of `AES.GCM.SealedBox.combined` and is the format
/// stored in ``RawMemoryNode/encryptedPayload`` and
/// ``MemoryArchiveNode/encryptedSummary``.
///
/// ## Thread Safety
///
/// `EncryptionService` has no mutable state and is `Sendable`. It can be
/// captured and called from any actor or task without synchronisation.
public struct EncryptionService: Sendable {

  // MARK: - Init

  /// Creates an `EncryptionService`. No configuration is required —
  /// the service is fully stateless.
  public init() {}

  // MARK: - Encrypt

  /// Encrypts a plaintext payload using AES-GCM with a fresh random nonce.
  ///
  /// - Parameters:
  ///   - plaintext: The raw data to encrypt.
  ///   - key: A 256-bit symmetric key (typically derived from the Secure Enclave via HKDF).
  /// - Returns: Combined ciphertext containing nonce, encrypted data, and
  ///   authentication tag.
  /// - Throws: ``AuraError/encryptionFailed(reason:)`` if the seal operation fails.
  public func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
    do {
      let sealedBox = try AES.GCM.seal(plaintext, using: key)
      guard let combined = sealedBox.combined else {
        throw AuraError.encryptionFailed(
          reason: "AES.GCM.seal succeeded but combined representation is nil."
        )
      }
      return combined
    } catch let error as AuraError {
      throw error
    } catch {
      throw AuraError.encryptionFailed(reason: error.localizedDescription)
    }
  }

  // MARK: - Decrypt

  /// Decrypts an AES-GCM combined ciphertext payload.
  ///
  /// - Parameters:
  ///   - combined: The combined ciphertext (nonce + ciphertext + tag) produced by
  ///     ``encrypt(_:using:)``.
  ///   - key: The same 256-bit symmetric key used during encryption.
  /// - Returns: The original plaintext data.
  /// - Throws: ``AuraError/decryptionFailed(reason:)`` if the ciphertext is
  ///   corrupted, the key is wrong, or the authentication tag fails verification.
  public func decrypt(_ combined: Data, using key: SymmetricKey) throws -> Data {
    do {
      let sealedBox = try AES.GCM.SealedBox(combined: combined)
      return try AES.GCM.open(sealedBox, using: key)
    } catch {
      throw AuraError.decryptionFailed(reason: error.localizedDescription)
    }
  }
}
