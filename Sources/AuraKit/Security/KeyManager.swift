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
///    using HKDF-SHA256, with a **per-key-version** salt stored in the Keychain.
/// 3. **Key Retrieval** — Caches derived symmetric keys in-memory. The Secure Enclave
///    private key is never extracted into process memory.
/// 4. **Key Rotation** — Generates a salt for a **new** key version. Salts of previous
///    versions are retained, so existing ciphertext stays decryptable across app
///    restarts until it has been re-encrypted and the retired material is purged
///    explicitly via ``purgeRetiredKeyMaterial(olderThan:)``.
///
/// ## Versioned Key Material
///
/// Every key version `v` has its own HKDF salt (Keychain account `hkdf-salt.v{v}`).
/// The AES key for version `v` is `HKDF(SE-ECDH secret, salt_v)`. Each encrypted
/// record stores the version it was sealed with, so readers always select the
/// correct key — rotation never strands existing data.
///
/// ```swift
/// try await keyManager.rotateKey()                       // v → v+1, old salt retained
/// try await store.reencryptStaleNodes()                  // migrate records to v+1
/// try await store.completeKeyRotationMigration()         // purge retired salts
/// ```
///
/// ## Threat Model
///
/// | Threat                           | Mitigation                                              |
/// |----------------------------------|---------------------------------------------------------|
/// | Offline copy of the database     | Payloads are AES-GCM ciphertext; key never on disk       |
/// | Keychain backup exfiltration     | `.whenUnlockedThisDeviceOnly` prevents backup/migration  |
/// | Salt guessing                    | Salts are 32 random bytes, stored in Keychain            |
/// | Long-lived single key            | ``rotateKey()`` + store re-encryption migration          |
/// | Record swapping / relabelling    | Ciphertext is bound to record metadata via AES-GCM AAD   |
///
/// - Important: The derived AES key is cached in **process memory** while in use.
///   Code executing inside the app process can always ask the Secure Enclave to
///   re-derive it, so the Secure Enclave protects key material *at rest* and
///   against offline extraction — **not** against a compromised app process.
///   ``clearCachedKeyForBackground()`` minimises the in-memory exposure window.
///
/// ## Thread Safety
///
/// All operations are actor-isolated. Concurrent callers serialise automatically.
/// Use ``currentKeyAndVersion()`` when a caller needs the key **and** its version:
/// two separate `await`s could straddle a concurrent ``rotateKey()``.
///
/// ## Security Design: No Raw Key Persistence
///
/// Derived AES-256 keys are **never written to the Keychain**. Only the
/// non-extractable Secure Enclave key reference, the per-version HKDF salts, and the
/// current version counter are persisted. Re-deriving costs ~2–5ms per version.
public actor KeyManager {

  // MARK: - Internal Logger

  /// Shared logger for all `KeyManager` extension files.
  static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "KeyManager"
  )

  // MARK: - Constants

  /// Keychain service identifier for AuraKit's encryption material.
  static let keychainService = "com.aurakit.encryption"

  /// Legacy (pre-versioning) Keychain account for the single HKDF salt.
  ///
  /// Installations created before versioned salts stored exactly one salt here,
  /// which always belonged to the then-current key version. It is migrated to
  /// ``saltKeychainAccount(forVersion:)`` on first access and deleted by
  /// ``purgeRetiredKeyMaterial(olderThan:)``.
  static let saltKeychainAccount = "hkdf-salt"

  /// Keychain account identifier for the Secure Enclave key reference.
  static let keyRefKeychainAccount = "se-key-ref"

  /// Keychain account identifier for the persisted key version counter.
  ///
  /// Stored as a UTF-8 encoded integer string so the version survives restarts —
  /// records are decrypted with the key matching their stored version.
  static let keyVersionKeychainAccount = "key-version"

  /// HKDF shared info — domain separation for AuraKit v1 key derivation.
  static let hkdfSharedInfo = Data("AuraKit.v1".utf8)

  /// HKDF shared info for static-key (test mode) rotation.
  static let staticRotationSharedInfo = Data("AuraKit.v1.static-rotation".utf8)

  /// Symmetric key output size in bytes (256-bit AES).
  static let symmetricKeyByteCount = 32

  /// Salt size in bytes.
  static let saltByteCount = 32

  /// Keychain account for the HKDF salt of a specific key version.
  static func saltKeychainAccount(forVersion version: Int) -> String {
    "hkdf-salt.v\(version)"
  }

  // MARK: - State

  /// Cached symmetric key for the **current** key version.
  var cachedKey: SymmetricKey?

  /// The previous symmetric key, preserved after rotation for convenience.
  /// Cleared by ``clearPreviousKey()`` or overwritten by the next ``rotateKey()``.
  var _previousKey: SymmetricKey?

  /// Current key version. Only meaningful once ``isVersionBootstrapped`` is `true`.
  var _keyVersion: Int = 0

  /// Whether ``_keyVersion`` has been loaded from the Keychain.
  ///
  /// Bootstrapping is lazy and **throwing**: reading the Keychain while the device
  /// is locked must surface an error instead of silently defaulting to version `0`
  /// (which would mislabel new records and select the wrong key).
  var isVersionBootstrapped: Bool = false

  /// Cache of derived keys for **retired** (non-current) versions.
  var retiredKeyCache: [Int: SymmetricKey] = [:]

  /// Root key for static (test) mode. `nil` in production mode.
  var staticRootKey: SymmetricKey?

  /// In-memory per-version salts for static (test) mode rotation.
  var staticSalts: [Int: Data] = [:]

  /// `true` when this manager was created with ``init(staticKey:)``.
  let isStaticMode: Bool

  // MARK: - Init

  /// The process-wide production key manager.
  ///
  /// All production `KeyManager` instances share the same Keychain items, but
  /// each caches the current key version **in memory**. Two instances in one
  /// process can therefore diverge: after `rotateKey()` + purge on one, the
  /// other keeps sealing with a retired version whose material is gone after
  /// the next launch. ``EncryptedMemoryStore`` uses this shared instance by
  /// default; inject a separate manager only for tests (``init(staticKey:)``).
  public static let shared = KeyManager()

  /// Creates a production `KeyManager`.
  ///
  /// Key generation, derivation, and version bootstrapping are deferred until
  /// first use, so constructing a manager never touches the Keychain (which may
  /// be unavailable while the device is locked).
  ///
  /// - Important: Prefer ``shared``. Multiple production instances in one
  ///   process do not observe each other's key rotations.
  public init() {
    self.isStaticMode = false
  }

  /// Creates a hermetic `KeyManager` backed by a pre-generated symmetric key.
  ///
  /// Static mode never touches the Secure Enclave or the Keychain. Version `0`
  /// uses `staticKey` directly; rotated versions are derived in memory via
  /// HKDF from `staticKey` with random per-version salts.
  ///
  /// - Parameter staticKey: A pre-generated 256-bit symmetric key.
  ///
  /// - Warning: **For unit testing only.** Using a static key in production defeats
  ///   the purpose of Secure Enclave–derived key management.
  public init(staticKey: SymmetricKey) {
    self.isStaticMode = true
    self.cachedKey = staticKey
    self.staticRootKey = staticKey
    self.isVersionBootstrapped = true
  }

  // MARK: - Public API

  /// Returns the AES-256 symmetric key for the **current** key version.
  ///
  /// - Returns: A 256-bit ``SymmetricKey`` suitable for AES-GCM encryption.
  /// - Throws: ``AuraError/secureEnclaveUnavailable(reason:)`` or
  ///   ``AuraError/keychainOperationFailed(operation:status:)`` if key material
  ///   cannot be read or derived (e.g., device locked).
  ///
  /// - Note: `internal` by design. Raw key material never crosses AuraKit's
  ///   public API — host apps encrypt through ``EncryptedMemoryStore``.
  func symmetricKey() throws -> SymmetricKey {
    try currentKeyAndVersion().key
  }

  /// Returns the current key **and** its version in a single actor hop.
  ///
  /// Always use this when sealing data: reading ``symmetricKey()`` and
  /// ``keyVersion`` with two separate `await`s allows a concurrent
  /// ``rotateKey()`` to run in between, producing ciphertext sealed with key
  /// `N` but labelled `N+1` — permanently undecryptable.
  func currentKeyAndVersion() throws -> (key: SymmetricKey, version: Int) {
    try ensureVersionBootstrapped()

    if let cached = cachedKey {
      return (cached, _keyVersion)
    }

    let key = try deriveKey(forVersion: _keyVersion, createSaltIfMissing: true)
    cachedKey = key
    KeyManager.logger.info(
      "[AuraKit] KeyManager: Symmetric key v\(self._keyVersion) derived (not persisted)."
    )
    return (key, _keyVersion)
  }

  /// Returns the symmetric key for an arbitrary key version.
  ///
  /// Used to decrypt records sealed before the most recent rotation(s).
  ///
  /// - Parameter version: The key version recorded on the ciphertext.
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if the key material for
  ///   `version` was purged or never existed.
  func symmetricKey(forVersion version: Int) throws -> SymmetricKey {
    try ensureVersionBootstrapped()

    if version == _keyVersion {
      return try currentKeyAndVersion().key
    }
    guard version >= 0, version < _keyVersion else {
      throw AuraError.keyRotationFailed(
        reason: "Key version \(version) does not exist (current version: \(_keyVersion))."
      )
    }
    if let cached = retiredKeyCache[version] {
      return cached
    }

    let key = try deriveKey(forVersion: version, createSaltIfMissing: false)
    retiredKeyCache[version] = key
    return key
  }

  /// Resolves the keys for a set of versions in one actor hop.
  ///
  /// The current key is required (its failure throws); retired versions whose
  /// material is unavailable are omitted so callers can count those records as
  /// decryption failures instead of aborting the whole read.
  func keyRing(for versions: Set<Int>) throws -> KeyRing {
    let current = try currentKeyAndVersion()
    var keys: [Int: SymmetricKey] = [current.version: current.key]

    for version in versions where version != current.version {
      do {
        keys[version] = try symmetricKey(forVersion: version)
      } catch {
        KeyManager.logger.error(
          "[AuraKit] KeyManager: Key material for v\(version) unavailable — \(error.localizedDescription)"
        )
      }
    }
    return KeyRing(currentVersion: current.version, keys: keys)
  }

  // MARK: - Version Bootstrap

  /// Loads the persisted key version from the Keychain exactly once.
  ///
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if the
  ///   Keychain is unreadable (e.g., device locked). The manager stays
  ///   un-bootstrapped and retries on the next call.
  func ensureVersionBootstrapped() throws {
    guard !isVersionBootstrapped else { return }

    guard let data = try KeychainHelper.retrieveOrThrow(
      service: KeyManager.keychainService,
      account: KeyManager.keyVersionKeychainAccount
    ) else {
      KeyManager.logger.debug(
        "[AuraKit] KeyManager: No persisted keyVersion found (first launch). Defaulting to 0."
      )
      _keyVersion = 0
      isVersionBootstrapped = true
      return
    }

    guard let string = String(data: data, encoding: .utf8), let version = Int(string), version >= 0 else {
      // Refuse to guess: defaulting to 0 would select the wrong key for new writes.
      KeyManager.logger.fault(
        "[AuraKit] KeyManager: Persisted keyVersion is malformed — refusing to guess a key version."
      )
      throw AuraError.secureEnclaveUnavailable(
        reason: "Persisted key version in Keychain is malformed; key material cannot be selected safely."
      )
    }

    _keyVersion = version
    isVersionBootstrapped = true
    KeyManager.logger.debug("[AuraKit] KeyManager: Bootstrapped keyVersion from Keychain: \(version).")
  }

  /// Persists the given key version to the Keychain (production mode only).
  ///
  /// - Throws: ``AuraError/keyRotationFailed(reason:)`` if Keychain persistence fails.
  func persistKeyVersion(_ version: Int) throws {
    guard !isStaticMode else { return }

    do {
      try KeychainHelper.storeOrThrow(
        data: Data(String(version).utf8),
        service: KeyManager.keychainService,
        account: KeyManager.keyVersionKeychainAccount
      )
    } catch {
      KeyManager.logger.fault("[AuraKit] KeyManager: Failed to persist keyVersion \(version) to Keychain.")
      throw AuraError.keyRotationFailed(
        reason: "Failed to persist keyVersion \(version) to Keychain: \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Cache Management

  /// Clears **all** cached key material from memory.
  ///
  /// In production mode the next call re-derives from the Secure Enclave.
  /// In static (test) mode the static root key is dropped as well, so subsequent
  /// key requests throw — a cleared static key is never silently recovered.
  public func clearCachedKey() {
    cachedKey = nil
    retiredKeyCache.removeAll()
    if isStaticMode {
      staticRootKey = nil
      staticSalts.removeAll()
    }
    KeyManager.logger.info("[AuraKit] KeyManager: Cached key material cleared.")
  }

  /// Clears cached symmetric keys to reduce in-memory key exposure while the
  /// application is in the background.
  ///
  /// The ``previousKey`` is intentionally **not** cleared — migrations may span
  /// several foreground/background transitions. The next foreground call to
  /// ``symmetricKey()`` transparently re-derives the key (~2–5ms).
  ///
  /// ```swift
  /// .onChange(of: scenePhase) { _, newPhase in
  ///     if newPhase == .background {
  ///         Task { await keyManager.clearCachedKeyForBackground() }
  ///     }
  /// }
  /// ```
  public func clearCachedKeyForBackground() {
    // In static (test) mode the root key is intentionally retained — it cannot
    // be re-derived from hardware — but all derived caches are dropped.
    cachedKey = nil
    retiredKeyCache.removeAll()
    KeyManager.logger.info(
      "[AuraKit] KeyManager: Cached keys cleared for background transition; re-derived on next access."
    )
  }
}

// MARK: - KeyRing

/// An immutable, `Sendable` set of symmetric keys indexed by key version.
///
/// Resolved once per read operation via ``KeyManager/keyRing(for:)`` so that
/// records sealed with different key versions can be decrypted in a single pass
/// without repeated actor hops.
struct KeyRing: Sendable {

  /// The key version used for new writes at the time the ring was resolved.
  let currentVersion: Int

  /// Available keys by version.
  let keys: [Int: SymmetricKey]

  /// Returns the key for `version`, or `nil` if its material is unavailable.
  func key(for version: Int) -> SymmetricKey? {
    keys[version]
  }
}
