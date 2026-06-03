// KeyManager.swift
// AuraKit — Security Layer
//
// Core actor definition and primary public API for symmetric key management.
// The key lifecycle is distributed across focused extension files:
//
// Rotation    → KeyManager+Rotation.swift
// Derivation  → KeyManager+Derivation.swift
// Salt mgmt   → KeyManager+Salt.swift

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
///
/// ## File Organisation
///
/// `KeyManager` is split across multiple files for single-responsibility compliance:
///
/// | File                          | Responsibility                              |
/// |-------------------------------|---------------------------------------------|
/// | `KeyManager.swift`            | Core definition, state, init, public API    |
/// | `KeyManager+Rotation.swift`   | Key rotation lifecycle and migration API    |
/// | `KeyManager+Derivation.swift` | ECDH derivation (Secure Enclave + fallback) |
/// | `KeyManager+Salt.swift`       | HKDF salt generation and persistence        |
public actor KeyManager {

  // MARK: - Internal Logger

  /// Shared logger for all `KeyManager` extension files.
  static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "KeyManager"
  )

  // MARK: - Constants

  /// Keychain service identifier for AuraKit's encryption salt.
  static let keychainService = "com.aurakit.encryption"

  /// Keychain account identifier for the HKDF salt.
  static let saltKeychainAccount = "hkdf-salt"

  /// Keychain account identifier for the Secure Enclave key reference.
  static let keyRefKeychainAccount = "se-key-ref"

  /// HKDF shared info — domain separation for AuraKit v1 key derivation.
  static let hkdfSharedInfo = Data("AuraKit.v1".utf8)

  /// Symmetric key output size in bytes (256-bit AES).
  static let symmetricKeyByteCount = 32

  /// Salt size in bytes.
  static let saltByteCount = 32

  // MARK: - State

  /// Cached symmetric key. Derived once per actor lifetime (or until rotated).
  /// Accessed by `KeyManager+Rotation.swift` for key rotation fail-safe logic.
  var cachedKey: SymmetricKey?

  /// The previous symmetric key, preserved after rotation for re-encryption migration.
  /// Cleared by ``clearPreviousKey()`` or overwritten by the next ``rotateKey()`` call.
  /// Accessed by `KeyManager+Rotation.swift`.
  var _previousKey: SymmetricKey?

  /// Monotonically increasing key version counter.
  /// Incremented each time ``rotateKey()`` is called.
  /// Accessed by `KeyManager+Rotation.swift`.
  var _keyVersion: Int = 0

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
}
