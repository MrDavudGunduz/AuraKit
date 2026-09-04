// KeyManager.swift
// AuraKit — Security Layer
//
// Core actor definition and primary public API for symmetric key management.
// The key lifecycle is distributed across focused extension files:
//
// Rotation    → KeyManager+Rotation.swift
// Derivation  → KeyManager+Derivation.swift
// Salt mgmt   → KeyManager+Salt.swift
// Keychain    → KeyManager+Keychain.swift

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
/// | `KeyManager+Keychain.swift`   | Symmetric key Keychain persistence          |
public actor KeyManager {

  // MARK: - Internal Logger

  /// Shared logger for all `KeyManager` extension files.
  static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "KeyManager"
  )

  // MARK: - Constants

  /// Keychain service identifier for AuraKit's encryption salt.
  static let keychainService = "com.aurakit.encryption"

  /// Keychain account identifier for the HKDF salt.
  static let saltKeychainAccount = "hkdf-salt"

  /// Keychain account identifier for the Secure Enclave key reference.
  static let keyRefKeychainAccount = "se-key-ref"

  /// Keychain account identifier for the persisted key version counter.
  ///
  /// The key version is stored as a UTF-8 encoded integer string in the Keychain.
  /// This ensures the version counter survives app restarts and crashes,
  /// preventing `keyVersion` from resetting to `0` after relaunch — which
  /// would break partial re-encryption migration logic that relies on
  /// matching `RawMemoryNode.keyVersion` against the current version.
  static let keyVersionKeychainAccount = "key-version"

  /// Keychain account identifier for the persisted symmetric key.
  /// Stored as raw key data (32 bytes) under the same service.
  static let symmetricKeyKeychainAccount = "symmetric-key"

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
  /// Persisted to Keychain to survive app restarts.
  /// Accessed by `KeyManager+Rotation.swift`.
  var _keyVersion: Int = 0

  // MARK: - Init

  /// Creates a `KeyManager`. Key generation and derivation are deferred until
  /// the first call to ``symmetricKey()``.
  ///
  /// The ``keyVersion`` counter is bootstrapped from the Keychain on init.
  /// If no persisted version exists (first launch), it defaults to `0`.
  public init() {
    self._keyVersion = Self.bootstrapKeyVersion()
  }

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

    // Attempt to load persisted key from Keychain
    if let storedKey = try retrieveSymmetricKeyFromKeychain() {
      cachedKey = storedKey
      KeyManager.logger.info("[AuraKit] KeyManager: Loaded symmetric key from Keychain.")
      return storedKey
    }

    // Derive new key and persist it
    let key = try deriveKey()
    cachedKey = key
    try storeSymmetricKeyInKeychain(key)
    KeyManager.logger.info("[AuraKit] KeyManager: Symmetric key derived and persisted to Keychain.")
    return key
  }

  // MARK: - Key Version Bootstrap

  /// Reads the persisted key version from the Keychain.
  ///
  /// Called during `init()` to restore the version counter across app restarts.
  /// Returns `0` if no version has been persisted yet (first launch).
  ///
  /// - Note: This is a `static` method (not `nonisolated`) so it can be called
  ///   from the actor's synchronous `init` without requiring an actor hop.
  private static func bootstrapKeyVersion() -> Int {
    guard let data = KeychainHelper.retrieve(
      service: keychainService,
      account: keyVersionKeychainAccount
    ) else {
      // No persisted version — this is expected on first launch.
      logger.debug(
        "[AuraKit] KeyManager: No persisted keyVersion found in Keychain (first launch). Defaulting to 0."
      )
      return 0
    }

    guard let string = String(data: data, encoding: .utf8),
      let version = Int(string)
    else {
      // Data exists but is malformed — this is unexpected and may indicate
      // Keychain corruption or a schema change between versions.
      logger.warning(
        """
        [AuraKit] KeyManager: Persisted keyVersion data exists in Keychain but \
        could not be parsed as UTF-8 integer. Defaulting to 0. \
        This may indicate Keychain corruption — monitor for key version mismatches.
        """
      )
      return 0
    }

    logger.debug(
      "[AuraKit] KeyManager: Bootstrapped keyVersion from Keychain: \(version)."
    )
    return version
  }

  /// Persists the current key version to the Keychain.
  ///
  /// Called after each successful ``rotateKey()`` to ensure the version
  /// counter survives app restarts.
  ///
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if Keychain persistence fails.
  func persistKeyVersion() throws {
    let data = Data(String(_keyVersion).utf8)
    do {
      try KeychainHelper.storeOrThrow(
        data: data,
        service: KeyManager.keychainService,
        account: KeyManager.keyVersionKeychainAccount
      )
    } catch {
      KeyManager.logger.fault(
        "[AuraKit] KeyManager: Failed to persist keyVersion \(self._keyVersion) to Keychain."
      )
      throw AuraError.keyRotationFailed(
        reason: "Failed to persist keyVersion \(_keyVersion) to Keychain: \(error.localizedDescription)"
      )
    }
  }

  /// Clears the cached symmetric key from memory.
  ///
  /// The next call to ``symmetricKey()`` will re-derive from the Secure Enclave.
  /// Use this for key rotation or test teardown.
  ///
  /// - Note: This clears only the primary cached key. The ``previousKey``
  ///   (preserved after rotation for migration) is **not** affected.
  ///   Call ``clearPreviousKey()`` separately to clear both.
  public func clearCachedKey() {
    cachedKey = nil
    KeyManager.logger.info("[AuraKit] KeyManager: Cached key cleared.")
  }

  /// Clears the cached symmetric key to reduce in-memory key exposure
  /// during background or inactive application states.
  ///
  /// This method is designed for **app lifecycle integration**. Call it when
  /// the application transitions to the background to minimise the window
  /// during which a derived symmetric key is held in process memory.
  ///
  /// The ``previousKey`` (used for key rotation migration) is intentionally
  /// **not** cleared — rotation migrations may span multiple foreground/background
  /// transitions and must not lose the old key mid-migration.
  ///
  /// The next foreground call to ``symmetricKey()`` will transparently
  /// re-derive the key from the Secure Enclave with no user-visible impact.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// // In your App's scenePhase handler:
  /// .onChange(of: scenePhase) { _, newPhase in
  ///     if newPhase == .background {
  ///         Task {
  ///             await keyManager.clearCachedKeyForBackground()
  ///         }
  ///     }
  /// }
  /// ```
  ///
  /// ## Performance
  ///
  /// Re-derivation on return to foreground takes ~2–5ms (ECDH + HKDF).
  /// This is imperceptible to users and occurs before any encrypt/decrypt
  /// operation is needed.
  public func clearCachedKeyForBackground() {
    cachedKey = nil
    KeyManager.logger.info(
      """
      [AuraKit] KeyManager: Cached key cleared for background transition. \
      Key will be re-derived on next foreground access.
      """
    )
  }
}
