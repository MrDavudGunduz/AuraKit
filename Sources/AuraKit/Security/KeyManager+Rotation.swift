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

  /// Rotates the encryption key by generating a new HKDF salt and deriving a fresh key.
  ///
  /// The rotation process:
  /// 1. Preserves the current symmetric key as ``previousKey`` for re-encryption migration
  /// 2. Generates a new cryptographically random 32-byte salt
  /// 3. Replaces the existing salt in the Keychain
  /// 4. Derives a new symmetric key from the same Secure Enclave private key + new salt
  /// 5. Increments ``keyVersion``
  ///
  /// After rotation, use the returned previous key to decrypt existing ciphertext,
  /// then re-encrypt with the new key obtained from ``symmetricKey()``.
  ///
  /// ```swift
  /// let oldKey = try await keyManager.rotateKey()
  /// let newKey = try await keyManager.symmetricKey()
  /// // Decrypt with oldKey, re-encrypt with newKey
  /// ```
  ///
  /// - Returns: The **previous** symmetric key (before rotation), for re-encryption migration.
  ///   Returns `nil` if no key was previously derived (first-time rotation on an unconfigured
  ///   manager).
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if salt generation or key
  ///   derivation fails during rotation.
  @discardableResult
  public func rotateKey() throws -> SymmetricKey? {
    // Preserve current key for migration
    let oldKey = cachedKey
    _previousKey = oldKey

    do {
      // Generate a fresh salt, replacing the old one in Keychain
      let newSalt = try generateAndStoreSalt()

      // Clear cached key so deriveKey uses the new salt
      cachedKey = nil

      // Derive new key with the fresh salt
      let newKey = try deriveKeyWithSalt(newSalt)
      cachedKey = newKey
      _keyVersion += 1

      KeyManager.logger.info(
        "[AuraKit] KeyManager: Key rotated successfully. Version: \(self._keyVersion)."
      )

      return oldKey
    } catch let error as AuraError {
      // Restore the old key if rotation fails — fail-safe
      cachedKey = oldKey
      _previousKey = nil
      throw error
    } catch {
      // Restore the old key if rotation fails — fail-safe
      cachedKey = oldKey
      _previousKey = nil
      throw AuraError.keyRotationFailed(
        reason: "Key rotation failed: \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Previous Key Access

  /// The previous symmetric key, preserved after the most recent ``rotateKey()`` call.
  ///
  /// Use this to decrypt existing ciphertext during a re-encryption migration.
  /// Returns `nil` if no rotation has occurred or if ``clearPreviousKey()``
  /// has been called.
  public var previousKey: SymmetricKey? { _previousKey }

  /// Clears the preserved previous key from memory.
  ///
  /// Call this after completing a re-encryption migration to reduce the
  /// in-memory key surface. After this call, ``previousKey`` returns `nil`.
  public func clearPreviousKey() {
    _previousKey = nil
    KeyManager.logger.info("[AuraKit] KeyManager: Previous key cleared.")
  }

  // MARK: - Version Tracking

  /// The current key version, incremented on each ``rotateKey()`` call.
  ///
  /// Starts at `0` and monotonically increases. Useful for tracking
  /// which version of the key was used to encrypt a given record.
  public var keyVersion: Int { _keyVersion }
}
