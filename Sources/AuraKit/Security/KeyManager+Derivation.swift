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

  /// Derives a symmetric key from the Secure Enclave private key using the stored salt.
  ///
  /// This is the top-level derivation entry point called by ``symmetricKey()``.
  /// It retrieves (or generates) the HKDF salt, then delegates to the
  /// platform-appropriate derivation method.
  ///
  /// ## Performance Telemetry
  ///
  /// This method is instrumented with `os_signpost` via ``SignpostLogger``.
  /// The key derivation interval (~2–5ms on physical devices) is visible in
  /// **Instruments → Time Profiler** under the `KeyDerivation` signpost name.
  func deriveKey() throws -> SymmetricKey {
    let signpostID = SignpostLogger.beginKeyDerivation()
    defer { SignpostLogger.endKeyDerivation(signpostID) }

    let salt = try retrieveOrGenerateSalt()
    return try deriveKeyWithSalt(salt)
  }

  /// Derives a symmetric key using a specific salt.
  ///
  /// Routes to Secure Enclave on physical devices or software P256 on simulators.
  /// Called by both ``deriveKey()`` (initial derivation) and ``rotateKey()``
  /// (post-rotation derivation with the fresh salt).
  func deriveKeyWithSalt(_ salt: Data) throws -> SymmetricKey {
    #if targetEnvironment(simulator)
    return try deriveKeyUsingSoftwareP256(salt: salt)
    #else
    return try deriveKeyUsingSecureEnclave(salt: salt)
    #endif
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

      // SECURITY AUDIT: ECDH Self-Agreement
      //
      // This performs ECDH key agreement with the key's own public key (self-agreement).
      // While unconventional (standard ECDH uses two distinct parties), this is
      // cryptographically safe in this context because:
      //
      // 1. The shared secret is never used directly — it passes through HKDF-SHA256
      //    with a per-installation random salt and domain-separated shared info.
      // 2. The HKDF output is computationally independent of the raw ECDH output
      //    due to the salt entropy (32 random bytes from SecRandomCopyBytes).
      // 3. The Secure Enclave private key is hardware-bound and non-exportable,
      //    providing the primary security guarantee.
      //
      // This pattern is used because CryptoKit's SecureEnclave.P256.KeyAgreement
      // requires an ECDH operation to produce a SharedSecret — there is no direct
      // "derive symmetric key" API for Secure Enclave keys.
      //
      // RECOMMENDATION: Have this derivation path reviewed by an independent
      // cryptography auditor before deploying in high-sensitivity production
      // environments (e.g., healthcare, financial, or government applications).
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
