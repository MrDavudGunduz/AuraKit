// KeyManager+Keychain.swift
// AuraKit — Security Layer
//
// Symmetric key Keychain persistence for KeyManager.
// Stores and retrieves the derived AES-256 key material in the Keychain
// to avoid repeated Secure Enclave derivation on each app launch.
//
// The key is stored as a `kSecClassGenericPassword` item under the
// `symmetric-key` account with `.whenUnlockedThisDeviceOnly` protection.
// This ensures the key is device-local, non-iCloud-synced, and accessible
// only when the device is unlocked.

import CryptoKit
import Foundation
import os.log

// MARK: - KeyManager + Symmetric Key Keychain Persistence

extension KeyManager {

  // MARK: - Retrieve

  /// Attempts to load a previously persisted symmetric key from the Keychain.
  ///
  /// If the Keychain contains valid 32-byte key data under the `symmetric-key`
  /// account, a `SymmetricKey` is reconstructed from the raw material and returned.
  ///
  /// Invalid data (wrong byte count) is treated as corruption — the corrupted
  /// entry is deleted and the method returns `nil`, triggering a fresh derivation
  /// in the caller.
  ///
  /// ## Security Considerations
  ///
  /// - The raw key material is held in process memory for the duration of the
  ///   `Data → SymmetricKey` conversion. CryptoKit's `SymmetricKey` internally
  ///   manages the key material's lifetime.
  /// - Keychain items use `.whenUnlockedThisDeviceOnly` — not backed up to iCloud.
  ///
  /// - Returns: The stored ``SymmetricKey``, or `nil` if no valid key exists.
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if the
  ///   Keychain query fails with an unexpected error (not `errSecItemNotFound`).
  func retrieveSymmetricKeyFromKeychain() throws -> SymmetricKey? {
    guard let keyData = KeychainHelper.retrieve(
      service: KeyManager.keychainService,
      account: KeyManager.symmetricKeyKeychainAccount
    ) else {
      // No persisted key — expected on first launch or after rotation invalidation.
      KeyManager.logger.debug(
        """
        [AuraKit] KeyManager: No persisted symmetric key found in Keychain. \
        Will derive from Secure Enclave.
        """
      )
      return nil
    }

    // Validate key length — must be exactly 32 bytes (256 bits).
    guard keyData.count == KeyManager.symmetricKeyByteCount else {
      KeyManager.logger.warning(
        """
        [AuraKit] KeyManager: Persisted symmetric key has invalid byte count \
        (\(keyData.count) bytes, expected \(KeyManager.symmetricKeyByteCount)). \
        Deleting corrupted entry and re-deriving.
        """
      )
      // Remove the corrupted entry so the next launch doesn't hit the same path.
      KeychainHelper.delete(
        service: KeyManager.keychainService,
        account: KeyManager.symmetricKeyKeychainAccount
      )
      return nil
    }

    return SymmetricKey(data: keyData)
  }

  // MARK: - Store

  /// Persists the derived symmetric key's raw material to the Keychain.
  ///
  /// Uses ``KeychainHelper/storeOrThrow(data:service:account:accessGroup:)``
  /// to ensure precise error propagation — a Keychain write failure during
  /// key persistence is a critical event that must not be silently swallowed.
  ///
  /// The key data is stored under:
  /// - **Service:** `com.aurakit.encryption`
  /// - **Account:** `symmetric-key`
  /// - **Accessibility:** `.whenUnlockedThisDeviceOnly`
  ///
  /// ## Crash Safety
  ///
  /// This method uses the atomic update pattern implemented in `KeychainHelper`:
  /// `SecItemUpdate` first, `SecItemAdd` only if the item doesn't exist yet.
  /// If the process is terminated mid-write, the previous key data is preserved.
  ///
  /// - Parameter key: The AES-256 symmetric key to persist.
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if
  ///   the Keychain write fails.
  func storeSymmetricKeyInKeychain(_ key: SymmetricKey) throws {
    let keyData = key.withUnsafeBytes { Data($0) }

    do {
      try KeychainHelper.storeOrThrow(
        data: keyData,
        service: KeyManager.keychainService,
        account: KeyManager.symmetricKeyKeychainAccount
      )
    } catch {
      KeyManager.logger.fault(
        """
        [AuraKit] KeyManager: Failed to persist symmetric key to Keychain. \
        Key will need to be re-derived on next app launch.
        """
      )
      throw error
    }
  }

  // MARK: - Invalidate

  /// Removes the persisted symmetric key from the Keychain.
  ///
  /// Called during key rotation to ensure the stale key is not loaded on the
  /// next `symmetricKey()` call. The newly derived key is persisted after
  /// successful rotation via ``storeSymmetricKeyInKeychain(_:)``.
  ///
  /// This operation is idempotent — calling it when no key is stored has no
  /// effect (no error is thrown).
  ///
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if the
  ///   Keychain delete fails with an unexpected error.
  func invalidateStoredSymmetricKey() throws {
    try KeychainHelper.deleteOrThrow(
      service: KeyManager.keychainService,
      account: KeyManager.symmetricKeyKeychainAccount
    )
    KeyManager.logger.info(
      "[AuraKit] KeyManager: Persisted symmetric key invalidated from Keychain."
    )
  }
}
