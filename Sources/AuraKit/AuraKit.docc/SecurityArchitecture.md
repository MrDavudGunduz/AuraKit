# Security Architecture

Understand AuraKit's zero-trust, defense-in-depth encryption pipeline.

## Overview

AuraKit follows a **Zero-Trust, Privacy-First** security model. Every spatial event is encrypted before touching disk, using keys derived from the device's Secure Enclave hardware. No plaintext spatial data is ever written to persistent storage.

## Cryptographic Pipeline

The encryption pipeline transforms a ``SpatialEvent`` into an encrypted ``RawMemoryNode`` through the following stages:

```
SpatialEvent
    │
    ▼
JSONEncoder.encode()
    │
    ▼
AES-256-GCM Encryption
    │  key ← HKDF-SHA256(
    │           sharedSecret: ECDH(SE_privkey, SE_pubkey),
    │           salt: Keychain[32 random bytes],
    │           info: "AuraKit.v1"
    │         )
    ▼
nonce(12 bytes) || ciphertext || auth_tag(16 bytes)
    │
    ▼
RawMemoryNode.encryptedPayload → SwiftData (SQLite)
```

## Key Management

### Secure Enclave Integration

``KeyManager`` generates a P256 key agreement key pair in the Secure Enclave. The private key is **hardware-bound and non-exportable** — it never enters process memory.

On simulators (where Secure Enclave hardware is unavailable), a software P256 fallback is used. This is safe for CI testing but should never be used in production.

### Key Derivation

The symmetric encryption key is derived through:

1. **ECDH Self-Agreement**: The Secure Enclave private key performs key agreement with its own public key, producing a `SharedSecret`.
2. **HKDF-SHA256**: The shared secret is expanded with a 32-byte random salt and domain separator `"AuraKit.v1"`, producing a 256-bit AES key.

The salt is persisted in the Keychain with `.whenUnlockedThisDeviceOnly` protection — it is never included in iCloud backups.

### Key Rotation

``KeyManager/rotateKey()`` enables periodic key rotation without data loss:

1. The current key is preserved as ``KeyManager/previousKey``
2. A new 32-byte salt is generated and stored in the Keychain
3. A fresh symmetric key is derived from the same Secure Enclave private key + new salt
4. ``KeyManager/keyVersion`` is incremented and persisted to the Keychain

After rotation, existing records can be identified by their ``RawMemoryNode/keyVersion`` field and re-encrypted without a full-table scan:

```swift
let oldKey = try await keyManager.rotateKey()
let newKey = try await keyManager.symmetricKey()

// Re-encrypt: decrypt with oldKey, encrypt with newKey
```

## Threat Model

| Threat Vector | Mitigation | Status |
|--------------|-----------|--------|
| Data at rest (disk access) | AES-256-GCM encryption before SwiftData write | ✅ |
| Key extraction via memory dump | Private key in Secure Enclave hardware | ✅ |
| Keychain backup exfiltration | `.whenUnlockedThisDeviceOnly` protection | ✅ |
| CloudKit transit exposure | Double encryption: AuraKit AES-GCM + CloudKit E2EE | ✅ |
| Stale encryption key | ``KeyManager/rotateKey()`` with version tracking | ✅ |
| Tampered ciphertext | AES-GCM authentication tag verification | ✅ |
| Partial write corruption | `ModelContext.rollback()` on save failure | ✅ |

## CloudKit End-to-End Encryption

When configured with a CloudKit container identifier, ``PersistenceController`` creates a **double-encrypted** sync path:

```
SpatialEvent → AES-GCM (AuraKit) → SwiftData → CloudKit E2EE → iCloud
```

Neither Apple nor any third party can read the plaintext at any point in the sync chain.

## Keychain Layout

AuraKit stores the following items in the Keychain under the service `com.aurakit.encryption`:

| Account | Content | Protection |
|---------|---------|-----------|
| `hkdf-salt` | 32-byte HKDF salt | `.whenUnlockedThisDeviceOnly` |
| `se-key-ref` | Secure Enclave key reference | `.whenUnlockedThisDeviceOnly` |
| `key-version` | Key version counter (UTF-8 integer) | `.whenUnlockedThisDeviceOnly` |

## Topics

### Security Types

- ``KeyManager``
- ``EncryptionService``
- ``AuraError``
