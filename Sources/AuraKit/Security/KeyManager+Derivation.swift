// KeyManager+Derivation.swift
// AuraKit — Security Layer
//
// ECDH key derivation pipeline for KeyManager.
// Contains the Secure Enclave (physical device) and software P256 (simulator)
// derivation paths. Extracted from KeyManager.swift for single-responsibility
// compliance while maintaining logical cohesion within the actor's isolation domain.

import CryptoKit
import Foundation
import os.log

// MARK: - KeyManager + Key Derivation Pipeline

extension KeyManager {

  /// Derives the symmetric key for a specific key version.
  ///
  /// This is the top-level derivation entry point. In static (test) mode the key
  /// is derived in memory from the static root key; in production mode the
  /// version's HKDF salt is loaded (or, for the current version on first
  /// launch, created) and combined with the Secure Enclave ECDH secret.
  ///
  /// ## Performance Telemetry
  ///
  /// Instrumented with `os_signpost` via ``SignpostLogger`` (~2–5ms on device),
  /// visible in **Instruments → Time Profiler** under `KeyDerivation`.
  ///
  /// - Parameters:
  ///   - version: The key version to derive.
  ///   - createSaltIfMissing: Whether a missing salt may be generated. Only `true`
  ///     for the current version — retired versions must never get new salts.
  func deriveKey(forVersion version: Int, createSaltIfMissing: Bool) throws -> SymmetricKey {
    let signpostID = SignpostLogger.beginKeyDerivation()
    defer { SignpostLogger.endKeyDerivation(signpostID) }

    if isStaticMode {
      return try deriveStaticKey(forVersion: version, createSaltIfMissing: createSaltIfMissing)
    }

    let salt = try salt(forVersion: version, createIfMissing: createSaltIfMissing)
    return try deriveKeyWithSalt(salt)
  }

  /// Derives a symmetric key using a specific salt.
  ///
  /// Routes to Secure Enclave on physical devices or software P256 on simulators.
  func deriveKeyWithSalt(_ salt: Data) throws -> SymmetricKey {
    #if targetEnvironment(simulator)
    return try deriveKeyUsingSoftwareP256(salt: salt)
    #else
    return try deriveKeyUsingSecureEnclave(salt: salt)
    #endif
  }

  // MARK: - Static Mode (Tests)

  /// Derives a version key from the static root key without touching the
  /// Keychain or Secure Enclave.
  ///
  /// Version `0` is the static key itself; version `n > 0` is
  /// `HKDF(staticKey, salt_n)` with an in-memory random salt.
  private func deriveStaticKey(forVersion version: Int, createSaltIfMissing: Bool) throws -> SymmetricKey {
    guard let root = staticRootKey else {
      throw AuraError.secureEnclaveUnavailable(
        reason: "Static key was cleared via clearCachedKey(); no key material is available."
      )
    }
    if version == 0 {
      return root
    }

    let salt: Data
    if let existing = staticSalts[version] {
      salt = existing
    } else if createSaltIfMissing {
      salt = try Self.randomSalt()
      staticSalts[version] = salt
    } else {
      throw AuraError.keyRotationFailed(reason: "Static key material for version \(version) is unavailable.")
    }

    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: root,
      salt: salt,
      info: KeyManager.staticRotationSharedInfo,
      outputByteCount: KeyManager.symmetricKeyByteCount
    )
  }

  // MARK: - Secure Enclave (Physical Device)

  #if !targetEnvironment(simulator)
  /// Derives a symmetric key using a Secure Enclave P256 key.
  ///
  /// On first invocation, generates a new P256 key pair in the Secure Enclave
  /// and persists the key reference in the Keychain. Subsequent calls retrieve
  /// the existing key. The private key never leaves the Secure Enclave hardware.
  ///
  /// The derivation path:
  /// ```
  /// SE Private Key + Own Public Key → ECDH → Shared Secret → HKDF-SHA256 → AES-256 Key
  /// ```
  ///
  /// - Parameter salt: The 32-byte HKDF salt for domain separation.
  /// - Returns: A 256-bit ``SymmetricKey`` suitable for AES-GCM.
  /// - Throws: ``AuraError/secureEnclaveUnavailable(reason:)`` if key generation,
  ///   Keychain persistence, or ECDH agreement fails.
  private func deriveKeyUsingSecureEnclave(salt: Data) throws -> SymmetricKey {
    do {
      let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

      // Attempt to retrieve existing key from Keychain. A read *failure*
      // (e.g., device locked) throws — it must never be mistaken for "no key".
      if let existingKeyData = try KeychainHelper.retrieveOrThrow(
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

        // Persist the key reference in Keychain.
        // Fail-fast: if this write fails, the key will be lost on app restart
        // and all encrypted data becomes permanently inaccessible.
        let stored = KeychainHelper.store(
          data: privateKey.dataRepresentation,
          service: KeyManager.keychainService,
          account: KeyManager.keyRefKeychainAccount
        )
        guard stored else {
          KeyManager.logger.fault(
            "[AuraKit] KeyManager: Failed to persist SE key reference in Keychain."
          )
          throw AuraError.secureEnclaveUnavailable(
            reason: "Failed to persist Secure Enclave key reference in Keychain. "
              + "Key would be lost on app restart, causing permanent data loss."
          )
        }
        KeyManager.logger.info("[AuraKit] KeyManager: Generated new SE key pair.")
      }

      // ECDH Self-Agreement — see SECURITY.md for full rationale.
      //
      // Performs ECDH with the key's own public key to extract usable
      // symmetric key material from a non-extractable Secure Enclave key.
      // The raw shared secret is never used directly — it passes through
      // HKDF-SHA256 with a per-installation random salt and domain-separated
      // info, so the structural properties of self-agreement don't propagate
      // to the output key. Determinism is intentional: same SE key + same
      // salt must always yield the same AES key for existing ciphertext.
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
  /// This path is intentionally limited to `targetEnvironment(simulator)`.
  /// On physical devices, the Secure Enclave is always used.
  ///
  /// The derivation path mirrors the Secure Enclave version:
  /// ```
  /// Software P256 Key + Own Public Key → ECDH → Shared Secret → HKDF-SHA256 → AES-256 Key
  /// ```
  ///
  /// - Important: This fallback exists solely for development and CI testing.
  ///   It provides the same API surface and key format as the Secure Enclave path,
  ///   but offers no hardware-backed key protection.
  ///
  /// - Parameter salt: The 32-byte HKDF salt for domain separation.
  /// - Returns: A 256-bit ``SymmetricKey`` suitable for AES-GCM.
  /// - Throws: ``AuraError/secureEnclaveUnavailable(reason:)`` if key generation,
  ///   Keychain persistence, or ECDH agreement fails.
  private func deriveKeyUsingSoftwareP256(salt: Data) throws -> SymmetricKey {
    do {
      let privateKey: P256.KeyAgreement.PrivateKey

      if let existingKeyData = try KeychainHelper.retrieveOrThrow(
        service: KeyManager.keychainService,
        account: KeyManager.keyRefKeychainAccount
      ) {
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: existingKeyData)
        KeyManager.logger.debug(
          "[AuraKit] KeyManager: Retrieved existing software P256 key (simulator)."
        )
      } else {
        privateKey = P256.KeyAgreement.PrivateKey()

        // Fail-fast: if this write fails, the key will be lost on app restart
        // and all encrypted data becomes permanently inaccessible.
        let stored = KeychainHelper.store(
          data: privateKey.rawRepresentation,
          service: KeyManager.keychainService,
          account: KeyManager.keyRefKeychainAccount
        )
        guard stored else {
          KeyManager.logger.fault(
            "[AuraKit] KeyManager: Failed to persist software P256 key in Keychain."
          )
          throw AuraError.secureEnclaveUnavailable(
            reason: "Failed to persist software P256 key in Keychain (simulator). "
              + "Key would be lost on app restart, causing permanent data loss."
          )
        }
        KeyManager.logger.info(
          "[AuraKit] KeyManager: Generated new software P256 key (simulator fallback)."
        )
      }

      // SECURITY AUDIT: ECDH Self-Agreement (simulator fallback)
      // Same cryptographic rationale as the Secure Enclave path above.
      // See the detailed audit comment in `deriveKeyUsingSecureEnclave(salt:)`.
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
}
