// KeyManager.swift
// AuraKit — Security Layer
//
// Manages the full lifecycle of Secure Enclave–derived symmetric keys:
// generation, derivation (HKDF-SHA256), Keychain persistence, rotation,
// and runtime retrieval. Keys never leave the Secure Enclave.
//
// On simulator builds (no Secure Enclave hardware), a software P256
// key is used as a transparent fallback for development and CI.

import CryptoKit
import Foundation
import os.log

// MARK: - KeyManager

/// An actor-isolated manager for Secure Enclave key generation, symmetric
/// key derivation, and key rotation.
///
/// `KeyManager` is the **single point of key management** in AuraKit's security
/// architecture. It handles:
///
/// 1. **Key Generation** — Creates a P256 key agreement key pair in the Secure Enclave
///    (hardware-bound, non-exportable on physical devices; software fallback on simulators).
/// 2. **Key Derivation** — Derives a 256-bit AES key from the Secure Enclave private key
///    using HKDF-SHA256, with a per-installation salt stored in the Keychain.
/// 3. **Key Retrieval** — Caches the derived symmetric key in-memory for the lifetime of
///    the actor. The Secure Enclave private key is never extracted into process memory.
/// 4. **Key Rotation** — Generates a new salt and derives a fresh symmetric key, while
///    preserving the previous key for data re-encryption migration.
///
/// ## Key Rotation
///
/// Key rotation replaces the HKDF salt used for key derivation, producing a new
/// symmetric key from the same Secure Enclave private key. The previous key is
/// preserved in memory until the next rotation or until ``clearPreviousKey()``
/// is called, enabling batch re-encryption of existing ciphertext.
///
/// ```swift
/// let previousKey = try await keyManager.rotateKey()
/// // Re-encrypt existing data: decrypt with previousKey, encrypt with new key
/// let newKey = try await keyManager.symmetricKey()
/// ```
///
/// ## Threat Model
///
/// | Threat                           | Mitigation                                              |
/// |----------------------------------|---------------------------------------------------------|
/// | Key extraction via memory dump   | Private key stays in Secure Enclave hardware             |
/// | Salt guessing                    | Salt is 32 random bytes, stored in Keychain              |
/// | Keychain backup exfiltration     | `.whenUnlockedThisDeviceOnly` prevents cloud backup      |
/// | Simulator key weakness           | Software fallback is DEBUG-only; CI tests remain valid   |
/// | Long-lived single key            | ``rotateKey()`` enables periodic key rotation            |
///
/// ## Thread Safety
///
/// All operations are actor-isolated. Concurrent callers serialise automatically.
public actor KeyManager {

  // MARK: - Internal Logger

  private static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "KeyManager"
  )

  // MARK: - Constants

  /// Keychain service identifier for AuraKit's encryption salt.
  private static let keychainService = "com.aurakit.encryption"

  /// Keychain account identifier for the HKDF salt.
  private static let saltKeychainAccount = "hkdf-salt"

  /// Keychain account identifier for the Secure Enclave key reference.
  private static let keyRefKeychainAccount = "se-key-ref"

  /// HKDF shared info — domain separation for AuraKit v1 key derivation.
  private static let hkdfSharedInfo = Data("AuraKit.v1".utf8)

  /// Symmetric key output size in bytes (256-bit AES).
  private static let symmetricKeyByteCount = 32

  /// Salt size in bytes.
  private static let saltByteCount = 32

  // MARK: - State

  /// Cached symmetric key. Derived once per actor lifetime (or until rotated).
  private var cachedKey: SymmetricKey?

  /// The previous symmetric key, preserved after rotation for re-encryption migration.
  /// Cleared by ``clearPreviousKey()`` or overwritten by the next ``rotateKey()`` call.
  private var _previousKey: SymmetricKey?

  /// Monotonically increasing key version counter.
  /// Incremented each time ``rotateKey()`` is called.
  private var _keyVersion: Int = 0

  // MARK: - Init

  /// Creates a `KeyManager`. Key generation and derivation are deferred until
  /// the first call to ``symmetricKey()``.
  public init() {}

  /// Creates a `KeyManager` with a pre-generated symmetric key.
  ///
  /// This initialiser bypasses Secure Enclave key generation and Keychain access
  /// entirely. The provided key is cached immediately and returned by all subsequent
  /// calls to ``symmetricKey()``.
  ///
  /// - Parameter staticKey: A pre-generated 256-bit symmetric key.
  ///
  /// - Warning: **For unit testing only.** Using a static key in production defeats
  ///   the purpose of Secure Enclave–derived key management. This initialiser is
  ///   intentionally public to support `@testable import AuraKit` in the test target.
  public init(staticKey: SymmetricKey) {
    self.cachedKey = staticKey
  }

  // MARK: - Public API

  /// Returns the AES-256 symmetric key, generating it if necessary.
  ///
  /// On first call:
  /// 1. Retrieves or generates a Secure Enclave P256 key pair
  /// 2. Retrieves or generates a 32-byte HKDF salt from the Keychain
  /// 3. Performs ECDH self-agreement → HKDF-SHA256 derivation
  /// 4. Caches the result for subsequent calls
  ///
  /// - Returns: A 256-bit ``SymmetricKey`` suitable for AES-GCM encryption.
  /// - Throws: ``AuraError/secureEnclaveUnavailable(reason:)`` if key generation
  ///   or derivation fails.
  public func symmetricKey() throws -> SymmetricKey {
    if let cached = cachedKey {
      return cached
    }

    let key = try deriveKey()
    cachedKey = key
    KeyManager.logger.info("[AuraKit] KeyManager: Symmetric key derived successfully.")
    return key
  }

  /// Clears the cached symmetric key from memory.
  ///
  /// The next call to ``symmetricKey()`` will re-derive from the Secure Enclave.
  /// Use this for key rotation or test teardown.
  public func clearCachedKey() {
    cachedKey = nil
    KeyManager.logger.info("[AuraKit] KeyManager: Cached key cleared.")
  }

  // MARK: - Key Rotation

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

  /// The current key version, incremented on each ``rotateKey()`` call.
  ///
  /// Starts at `0` and monotonically increases. Useful for tracking
  /// which version of the key was used to encrypt a given record.
  public var keyVersion: Int { _keyVersion }

  // MARK: - Key Derivation Pipeline

  /// Derives a symmetric key from the Secure Enclave private key using the stored salt.
  private func deriveKey() throws -> SymmetricKey {
    let salt = try retrieveOrGenerateSalt()
    return try deriveKeyWithSalt(salt)
  }

  /// Derives a symmetric key using a specific salt.
  private func deriveKeyWithSalt(_ salt: Data) throws -> SymmetricKey {
    #if targetEnvironment(simulator)
    return try deriveKeyUsingSoftwareP256(salt: salt)
    #else
    return try deriveKeyUsingSecureEnclave(salt: salt)
    #endif
  }

  // MARK: - Secure Enclave (Physical Device)

  #if !targetEnvironment(simulator)
  /// Derives a symmetric key using a Secure Enclave P256 key.
  private func deriveKeyUsingSecureEnclave(salt: Data) throws -> SymmetricKey {
    do {
      let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

      // Attempt to retrieve existing key from Keychain
      if let existingKeyData = KeychainHelper.retrieve(
        service: KeyManager.keychainService,
        account: KeyManager.keyRefKeychainAccount
      ) {
        privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
          dataRepresentation: existingKeyData
        )
        KeyManager.logger.debug("[AuraKit] KeyManager: Retrieved existing SE key.")
      } else {
        // Generate a new Secure Enclave key
        privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()

        // Persist the key reference in Keychain
        let stored = KeychainHelper.store(
          data: privateKey.dataRepresentation,
          service: KeyManager.keychainService,
          account: KeyManager.keyRefKeychainAccount
        )
        if !stored {
          KeyManager.logger.fault(
            "[AuraKit] KeyManager: Failed to persist SE key reference in Keychain."
          )
        }
        KeyManager.logger.info("[AuraKit] KeyManager: Generated new SE key pair.")
      }

      // Self-agreement: ECDH with own public key → shared secret
      let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
        with: privateKey.publicKey
      )

      return sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: KeyManager.hkdfSharedInfo,
        outputByteCount: KeyManager.symmetricKeyByteCount
      )
    } catch let error as AuraError {
      throw error
    } catch {
      throw AuraError.secureEnclaveUnavailable(
        reason: "Secure Enclave key operation failed: \(error.localizedDescription)"
      )
    }
  }
  #endif

  // MARK: - Software Fallback (Simulator)

  /// Derives a symmetric key using a software P256 key (simulator-only fallback).
  ///
  /// - Important: This path is intentionally limited to `targetEnvironment(simulator)`.
  ///   On physical devices, the Secure Enclave is always used.
  private func deriveKeyUsingSoftwareP256(salt: Data) throws -> SymmetricKey {
    do {
      let privateKey: P256.KeyAgreement.PrivateKey

      if let existingKeyData = KeychainHelper.retrieve(
        service: KeyManager.keychainService,
        account: KeyManager.keyRefKeychainAccount
      ) {
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: existingKeyData)
        KeyManager.logger.debug(
          "[AuraKit] KeyManager: Retrieved existing software P256 key (simulator)."
        )
      } else {
        privateKey = P256.KeyAgreement.PrivateKey()

        let stored = KeychainHelper.store(
          data: privateKey.rawRepresentation,
          service: KeyManager.keychainService,
          account: KeyManager.keyRefKeychainAccount
        )
        if !stored {
          KeyManager.logger.fault(
            "[AuraKit] KeyManager: Failed to persist software P256 key in Keychain."
          )
        }
        KeyManager.logger.info(
          "[AuraKit] KeyManager: Generated new software P256 key (simulator fallback)."
        )
      }

      let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
        with: privateKey.publicKey
      )

      return sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: KeyManager.hkdfSharedInfo,
        outputByteCount: KeyManager.symmetricKeyByteCount
      )
    } catch let error as AuraError {
      throw error
    } catch {
      throw AuraError.secureEnclaveUnavailable(
        reason: "Software P256 key derivation failed (simulator): \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Salt Management

  /// Retrieves the HKDF salt from the Keychain, or generates and stores a new one.
  private func retrieveOrGenerateSalt() throws -> Data {
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
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if random byte generation fails.
  private func generateAndStoreSalt() throws -> Data {
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

    let stored = KeychainHelper.store(
      data: salt,
      service: KeyManager.keychainService,
      account: KeyManager.saltKeychainAccount
    )
    if !stored {
      KeyManager.logger.fault(
        "[AuraKit] KeyManager: Failed to persist HKDF salt in Keychain. Salt may not survive app relaunch."
      )
    }

    KeyManager.logger.info("[AuraKit] KeyManager: Generated and stored new HKDF salt.")
    return salt
  }
}
