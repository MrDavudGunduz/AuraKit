// KeyManager.swift
// AuraKit — Security Layer
//
// Manages the full lifecycle of Secure Enclave–derived symmetric keys:
// generation, derivation (HKDF-SHA256), Keychain persistence, and
// runtime retrieval. Keys never leave the Secure Enclave.
//
// On simulator builds (no Secure Enclave hardware), a software P256
// key is used as a transparent fallback for development and CI.

import CryptoKit
import Foundation
import os.log

// MARK: - KeyManager

/// An actor-isolated manager for Secure Enclave key generation and symmetric
/// key derivation.
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
///
/// ## Threat Model
///
/// | Threat                           | Mitigation                                              |
/// |----------------------------------|---------------------------------------------------------|
/// | Key extraction via memory dump   | Private key stays in Secure Enclave hardware             |
/// | Salt guessing                    | Salt is 32 random bytes, stored in Keychain              |
/// | Keychain backup exfiltration     | `.whenUnlockedThisDeviceOnly` prevents cloud backup      |
/// | Simulator key weakness           | Software fallback is DEBUG-only; CI tests remain valid   |
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

  /// Cached symmetric key. Derived once per actor lifetime.
  private var cachedKey: SymmetricKey?

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

  // MARK: - Key Derivation Pipeline

  /// Derives a symmetric key from the Secure Enclave private key.
  private func deriveKey() throws -> SymmetricKey {
    let salt = try retrieveOrGenerateSalt()

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

    // Generate a cryptographically random 32-byte salt
    var salt = Data(count: KeyManager.saltByteCount)
    let result = salt.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return errSecParam
      }
      return SecRandomCopyBytes(kSecRandomDefault, KeyManager.saltByteCount, baseAddress)
    }

    guard result == errSecSuccess else {
      throw AuraError.secureEnclaveUnavailable(
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
