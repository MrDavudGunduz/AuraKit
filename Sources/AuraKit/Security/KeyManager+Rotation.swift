// KeyManager+Rotation.swift
// AuraKit — Security Layer
//
// Key rotation lifecycle for KeyManager.
// Extracted from KeyManager.swift for single-responsibility compliance
// while maintaining logical cohesion within the actor's isolation domain.

import CryptoKit
import Foundation

// MARK: - KeyManager + Key Rotation

extension KeyManager {

  // MARK: - Rotate

  /// Rotates the encryption key by creating key material for a **new** key version.
  ///
  /// The rotation process is ordered so that every failure leaves the manager in
  /// its previous, fully consistent state:
  ///
  /// 1. Resolve the current key (preserved as ``previousKey`` and in the retired cache)
  /// 2. Generate a fresh 32-byte salt and store it under the **new** version's account
  /// 3. Derive the new symmetric key
  /// 4. Persist the new version counter — the commit point
  /// 5. Swap in-memory state
  ///
  /// Salts of earlier versions are **retained**, so records sealed with them stay
  /// decryptable across app restarts. Re-encrypt them with
  /// ``EncryptedMemoryStore/reencryptStaleNodes(batchSize:)`` and then call
  /// ``purgeRetiredKeyMaterial(olderThan:)`` (or
  /// ``EncryptedMemoryStore/completeKeyRotationMigration()``) to retire them.
  ///
  /// ```swift
  /// try await keyManager.rotateKey()
  /// try await store.reencryptStaleNodes()
  /// try await store.completeKeyRotationMigration()
  /// ```
  ///
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if salt generation, key
  ///   derivation, or version persistence fails. State is unchanged on failure.
  public func rotateKey() throws {
    try rotateKeyReturningPrevious()
  }

  /// Internal variant of ``rotateKey()`` that returns the previous key.
  ///
  /// Raw key material never crosses AuraKit's public API.
  ///
  /// - Returns: The **previous** symmetric key (before rotation), or `nil` if it
  ///   could not be resolved.
  @discardableResult
  func rotateKeyReturningPrevious() throws -> SymmetricKey? {
    try ensureVersionBootstrapped()

    let oldVersion = _keyVersion
    let newVersion = oldVersion + 1
    let oldKey = try? currentKeyAndVersion().key

    do {
      // Steps 2–3: new material for the new version only. Nothing that existing
      // ciphertext depends on is modified.
      let newKey = try deriveKey(forVersion: newVersion, createSaltIfMissing: true)

      // Step 4: commit point. Until the version counter is persisted, a crash
      // leaves the old version current and the new salt merely orphaned.
      try persistKeyVersion(newVersion)

      // Step 5: in-memory swap.
      if let oldKey {
        retiredKeyCache[oldVersion] = oldKey
      }
      _previousKey = oldKey
      cachedKey = newKey
      _keyVersion = newVersion

      KeyManager.logger.info("[AuraKit] KeyManager: Key rotated successfully. Version: \(newVersion).")
      return oldKey
    } catch {
      // Best-effort cleanup of the orphaned salt. Never touches older versions.
      discardOrphanedSalt(forVersion: newVersion)

      if let auraError = error as? AuraError { throw auraError }
      throw AuraError.keyRotationFailed(reason: "Key rotation failed: \(error.localizedDescription)")
    }
  }

  /// Removes salt material created for a version that never became current.
  private func discardOrphanedSalt(forVersion version: Int) {
    if isStaticMode {
      staticSalts[version] = nil
    } else {
      KeychainHelper.delete(
        service: KeyManager.keychainService,
        account: KeyManager.saltKeychainAccount(forVersion: version)
      )
    }
  }

  // MARK: - Retirement

  /// Permanently deletes key material for every version **older** than `minimumVersion`.
  ///
  /// Call this only after all records sealed with those versions have been
  /// re-encrypted — afterwards they can never be decrypted again. Prefer
  /// ``EncryptedMemoryStore/completeKeyRotationMigration()``, which verifies that
  /// no stale records remain before purging.
  ///
  /// - Parameter minimumVersion: The oldest version to keep. Clamped to the
  ///   current version (the current key can never be purged).
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if a
  ///   Keychain deletion fails.
  public func purgeRetiredKeyMaterial(olderThan minimumVersion: Int) throws {
    try ensureVersionBootstrapped()
    let cutoff = min(minimumVersion, _keyVersion)
    guard cutoff > 0 else { return }

    for version in 0..<cutoff {
      retiredKeyCache[version] = nil
      if isStaticMode {
        staticSalts[version] = nil
      } else {
        try KeychainHelper.deleteOrThrow(
          service: KeyManager.keychainService,
          account: KeyManager.saltKeychainAccount(forVersion: version)
        )
      }
    }

    if !isStaticMode {
      // The legacy single salt always belonged to some version < current once a
      // versioned salt for the current version exists.
      try KeychainHelper.deleteOrThrow(
        service: KeyManager.keychainService,
        account: KeyManager.saltKeychainAccount
      )
    }

    if cutoff >= _keyVersion {
      _previousKey = nil
    }

    KeyManager.logger.info("[AuraKit] KeyManager: Purged retired key material for versions < \(cutoff).")
  }

  // MARK: - Previous Key Access

  /// The previous symmetric key, preserved after the most recent ``rotateKey()`` call.
  ///
  /// Returns `nil` if no rotation has occurred in this process or if
  /// ``clearPreviousKey()`` has been called. Records sealed with older versions
  /// remain decryptable through ``symmetricKey(forVersion:)`` regardless.
  ///
  /// `internal` by design — raw key material never crosses the public API.
  var previousKey: SymmetricKey? { _previousKey }

  /// Clears the preserved previous key from memory.
  ///
  /// This affects only the convenience in-memory copy; retired key material in
  /// the Keychain is removed by ``purgeRetiredKeyMaterial(olderThan:)``.
  public func clearPreviousKey() {
    _previousKey = nil
    if _keyVersion > 0 {
      retiredKeyCache[_keyVersion - 1] = nil
    }
    KeyManager.logger.info("[AuraKit] KeyManager: Previous key cleared.")
  }

  // MARK: - Version Tracking

  /// The current key version, incremented on each ``rotateKey()`` call.
  ///
  /// Starts at `0` and monotonically increases. If the Keychain cannot be read
  /// yet (e.g., device locked before first unlock), this returns the last known
  /// value; sealing operations use ``currentKeyAndVersion()``, which throws instead.
  public var keyVersion: Int {
    try? ensureVersionBootstrapped()
    return _keyVersion
  }
}
