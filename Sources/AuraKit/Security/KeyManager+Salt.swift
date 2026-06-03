// KeyManager+Salt.swift
// AuraKit — Security Layer
//
// HKDF salt generation and Keychain persistence for KeyManager.
// Extracted from KeyManager.swift for single-responsibility compliance
// while maintaining logical cohesion within the actor's isolation domain.

import Foundation
import os.log

// MARK: - KeyManager + Salt Management

extension KeyManager {

  /// Retrieves the HKDF salt from the Keychain, or generates and stores a new one.
  ///
  /// This is the primary salt entry point called by ``deriveKey()``. On first
  /// launch, no salt exists in the Keychain, so a new one is generated and stored.
  /// On subsequent launches, the existing salt is retrieved to reproduce the same
  /// derived key.
  ///
  /// - Returns: The 32-byte HKDF salt.
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if salt generation fails.
  func retrieveOrGenerateSalt() throws -> Data {
    if let existingSalt = KeychainHelper.retrieve(
      service: KeyManager.keychainService,
      account: KeyManager.saltKeychainAccount
    ) {
      return existingSalt
    }

    return try generateAndStoreSalt()
  }

  /// Generates a cryptographically random salt and stores it in the Keychain,
  /// replacing any existing salt.
  ///
  /// Used by both initial key derivation (when no salt exists) and key rotation
  /// (to replace the existing salt with a fresh one).
  ///
  /// - Returns: The newly generated 32-byte salt.
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if random byte generation
  ///   or Keychain persistence fails.
  func generateAndStoreSalt() throws -> Data {
    var salt = Data(count: KeyManager.saltByteCount)
    let result = salt.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return errSecParam
      }
      return SecRandomCopyBytes(kSecRandomDefault, KeyManager.saltByteCount, baseAddress)
    }

    guard result == errSecSuccess else {
      throw AuraError.keyRotationFailed(
        reason: "Failed to generate cryptographic random salt (SecRandomCopyBytes error: \(result))."
      )
    }

    // Fail-fast: if the salt cannot be persisted, the derived key will differ
    // on the next app launch, making all previously encrypted data inaccessible.
    let stored = KeychainHelper.store(
      data: salt,
      service: KeyManager.keychainService,
      account: KeyManager.saltKeychainAccount
    )
    guard stored else {
      KeyManager.logger.fault(
        "[AuraKit] KeyManager: Failed to persist HKDF salt in Keychain. "
          + "Salt would not survive app relaunch, causing permanent data loss."
      )
      throw AuraError.keyRotationFailed(
        reason: "Failed to persist HKDF salt in Keychain. "
          + "Without persisted salt, the derived key cannot be reproduced after app restart."
      )
    }

    KeyManager.logger.info("[AuraKit] KeyManager: Generated and stored new HKDF salt.")
    return salt
  }
}
