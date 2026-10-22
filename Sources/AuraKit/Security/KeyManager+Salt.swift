// KeyManager+Salt.swift
// AuraKit — Security Layer
//
// Per-version HKDF salt generation and Keychain persistence for KeyManager.
// Extracted from KeyManager.swift for single-responsibility compliance
// while maintaining logical cohesion within the actor's isolation domain.

import Foundation
import os.log

// MARK: - KeyManager + Salt Management

extension KeyManager {

  /// Returns the HKDF salt for a key version.
  ///
  /// Lookup order:
  /// 1. The versioned account `hkdf-salt.v{version}`.
  /// 2. For the **current** version only: the legacy single-salt account
  ///    (`hkdf-salt`) from pre-versioning installations. It is copied into the
  ///    versioned account so future lookups are direct.
  /// 3. If `createIfMissing` is `true` (current version, first launch only), a new
  ///    random salt is generated and persisted.
  ///
  /// Keychain read failures (e.g., `errSecInteractionNotAllowed` on a locked
  /// device) are **thrown**, never treated as "missing" — generating a new salt
  /// in that situation would orphan every existing record.
  ///
  /// - Parameters:
  ///   - version: The key version whose salt is requested.
  ///   - createIfMissing: Whether a missing salt may be generated.
  /// - Returns: The 32-byte HKDF salt.
  func salt(forVersion version: Int, createIfMissing: Bool) throws -> Data {
    let account = KeyManager.saltKeychainAccount(forVersion: version)

    if let existing = try KeychainHelper.retrieveOrThrow(
      service: KeyManager.keychainService,
      account: account
    ) {
      return existing
    }

    if version == _keyVersion,
      let legacy = try KeychainHelper.retrieveOrThrow(
        service: KeyManager.keychainService,
        account: KeyManager.saltKeychainAccount
      )
    {
      // Migrate the legacy salt into the versioned slot. A failure here is not
      // fatal: the legacy item remains the source of truth until purged.
      do {
        try KeychainHelper.storeOrThrow(data: legacy, service: KeyManager.keychainService, account: account)
        KeyManager.logger.info("[AuraKit] KeyManager: Migrated legacy HKDF salt to key version \(version).")
      } catch {
        KeyManager.logger.error(
          "[AuraKit] KeyManager: Could not migrate legacy HKDF salt — \(error.localizedDescription)"
        )
      }
      return legacy
    }

    guard createIfMissing else {
      throw AuraError.keyRotationFailed(
        reason: "HKDF salt for key version \(version) is unavailable (purged or never created)."
      )
    }

    return try generateAndStoreSalt(forVersion: version)
  }

  /// Generates a cryptographically random salt and stores it in the Keychain
  /// under the account for `version`.
  ///
  /// Salts of other versions are never touched, so rotation cannot strand
  /// existing ciphertext.
  ///
  /// - Parameter version: The key version the salt belongs to.
  /// - Returns: The newly generated 32-byte salt.
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if random byte generation
  ///   or Keychain persistence fails.
  func generateAndStoreSalt(forVersion version: Int) throws -> Data {
    let salt = try Self.randomSalt()

    // Fail-fast: if the salt cannot be persisted, the derived key could not be
    // reproduced after relaunch, making new ciphertext permanently inaccessible.
    do {
      try KeychainHelper.storeOrThrow(
        data: salt,
        service: KeyManager.keychainService,
        account: KeyManager.saltKeychainAccount(forVersion: version)
      )
    } catch {
      KeyManager.logger.fault(
        "[AuraKit] KeyManager: Failed to persist HKDF salt for v\(version) — refusing to use unpersisted key material."
      )
      throw AuraError.keyRotationFailed(
        reason: "Failed to persist HKDF salt for key version \(version): \(error.localizedDescription)"
      )
    }

    KeyManager.logger.info("[AuraKit] KeyManager: Generated and stored HKDF salt for key version \(version).")
    return salt
  }

  /// Produces 32 cryptographically random bytes.
  static func randomSalt() throws -> Data {
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
    return salt
  }
}
