# AuraKit — Security Architecture

## Philosophy: Zero-Trust, Privacy-First

AuraKit operates on the principle that **user data should never need to be trusted to any party — including AuraKit itself**. All sensitive information is encrypted before it reaches storage, keys are generated and protected by dedicated hardware, and no data ever traverses an external network.

> **TL;DR:** Your users' memories stay on their devices. Period.

---

## Threat Model

| Threat                  | Mitigation                                                        |
| ----------------------- | ----------------------------------------------------------------- |
| Physical device seizure | AES-GCM encryption at rest (Secure Enclave key)                   |
| Cloud server breach     | N/A — no data is sent to any server (CloudKit sync unsupported)  |
| LLM data exfiltration   | Network entitlements blocked; MLX runs offline                    |
| App binary tampering    | Signed Swift Package; no remote code loading                      |
| App Store rejection     | `PrivacyInfo.xcprivacy` manifest, reviewed by Apple at submission |
| Memory scraping         | Keys never stored in process memory beyond key agreement          |

---

## Data at Rest — AES-GCM + Secure Enclave

### Key Generation

Keys are generated inside the **Secure Enclave** — Apple's dedicated security coprocessor that is physically isolated from the main CPU. The key material **never enters application memory**.

```swift
import CryptoKit

// Generate a Secure Enclave private key (hardware-bound, non-exportable)
let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()

// Derive a symmetric key using HKDF-SHA256
// (performed in-process using the public key material only)
func deriveSymmetricKey(from privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey,
                         salt: Data) throws -> SymmetricKey {
    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
        with: privateKey.publicKey  // Self-agreement for local derivation
    )
    return sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: "AuraKit.v1".data(using: .utf8)!,
        outputByteCount: 32
    )
}
```

### Encryption (Write Path)

Every `RawMemoryNode` payload is encrypted with AES-GCM before being handed to SwiftData:

```swift
func encrypt(_ payload: Data, using key: SymmetricKey) throws -> Data {
    let sealedBox = try AES.GCM.seal(payload, using: key)
    // Returns: nonce (12 bytes) || ciphertext || tag (16 bytes)
    return sealedBox.combined!
}
```

**AES-GCM provides:**

- **Confidentiality** — Data is unreadable without the key
- **Integrity** — Authentication tag detects any modification
- **Nonce** — Unique per-message; prevents IV reuse attacks

### Decryption (Read Path)

```swift
func decrypt(_ combined: Data, using key: SymmetricKey) throws -> Data {
    let sealedBox = try AES.GCM.SealedBox(combined: combined)
    return try AES.GCM.open(sealedBox, using: key)
}
```

### Key Storage (No Raw Key Persistence)

Derived `SymmetricKey` values are **never written to the Keychain or disk**. They exist only in actor-isolated process memory while in use and are wiped on background transitions via `AuraKitLifecycleObserver` / `KeyManager.clearCachedKeyForBackground()`.

Only the following non-secret or hardware-bound items are stored in the **Keychain**:

- `se-key-ref`: Opaque reference to the non-extractable Secure Enclave P256 private key
- `hkdf-salt.v{version}`: 32-byte random HKDF salt per key version
- `key-version`: Current monotonically increasing key version counter
- All items use `kSecAttrAccessible: .whenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable: false` — never backed up or synced to iCloud

---

## Data in Transit — CloudKit Sync Is Unsupported

AuraKit does **not** sync data through CloudKit. The AES-256 key is derived from a
non-exportable Secure Enclave key whose reference lives in a
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` Keychain item. A second device cannot
reproduce that key, so replicated ciphertext would be permanently unreadable there.

`PersistenceController.makeContainer(cloudKitContainerIdentifier:)` therefore throws
`AuraError.invalidConfiguration` when a CloudKit identifier is supplied, rather than
silently creating a container that syncs undecryptable data.

### Consequences

| Scenario                                  | Result                                                  |
| ----------------------------------------- | ------------------------------------------------------- |
| Normal use                                | Data stays on-device, encrypted at rest                 |
| Restore from device backup to a new phone | Database may restore, but the key does not → unreadable |
| App reinstall on same device              | Keychain may persist, SwiftData store is recreated      |

Multi-device sync would require a dedicated key-sharing design (for example a wrapped
key in iCloud Keychain). It is not implemented.

---

## On-Device LLM — Network Isolation

The `IntelligenceActor` executes an Apple Silicon MLX model inside the main app process with **zero network access**.

### Entitlement Configuration

```xml
<!-- AuraIntelligence.entitlements -->
<key>com.apple.security.network.client</key>
<false/>
<key>com.apple.security.network.server</key>
<false/>
```

This is enforced at the OS level via the App Sandbox. The LLM cannot make outbound connections regardless of what code it attempts to run.

### Model Distribution

| Option                                      | Trade-off                                           |
| ------------------------------------------- | --------------------------------------------------- |
| Bundled in framework (< 4GB AppStore limit) | Larger binary, instant availability                 |
| On-demand resource (Apple CDN)              | Smaller initial install, requires one-time download |
| ADP (Alternative Distribution)              | No size limit, useful for Vision Pro distribution   |

All model weight files are stored encrypted using the same `SymmetricKey` derived from the Secure Enclave. MLX loads weights into GPU memory directly; decrypted weight bytes are never written to disk unencrypted.

---

## Privacy Manifest — `PrivacyInfo.xcprivacy`

As required by App Store Review Guidelines (updated 2024), AuraKit includes a `PrivacyInfo.xcprivacy` manifest that declares all data types and usage.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>  <!-- AuraKit does NOT track users across apps or websites -->

    <key>NSPrivacyTrackingDomains</key>
    <array/>  <!-- No tracking domains -->

    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
            <!-- Spatial interaction events (gaze, touch positions) -->

            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>  <!-- Not linked to user identity -->

            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>  <!-- Not used for tracking -->

            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>

    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string> <!-- SwiftData/SQLite store management -->
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>E174.1</string> <!-- SwiftData storage capacity checks -->
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### Validating the Manifest

```bash
# Validate syntax and required keys (as run in CI)
plutil -lint Sources/AuraKit/PrivacyInfo.xcprivacy
```

---

## Security Checklist for Integrators

Before shipping an app that uses AuraKit, verify:

- [ ] `AuraConfiguration` and `KeyManager` never expose raw symmetric keys to the host app
- [ ] `RawMemoryNode.encryptedPayload` is never logged
- [ ] `AuraKit.shared.startLifecycleObserver()` is called at launch so cached keys are wiped on background transitions
- [ ] App entitlements set `com.apple.security.network.client` to `false` when running offline on-device LLM inference
- [ ] Keychain item accessibility remains `.whenUnlockedThisDeviceOnly` (enforced by `KeychainHelper`)
- [ ] Instruments → Leaks run confirms no symmetric key material is retained after `clearCachedKeyForBackground()`

---

## Reporting a Vulnerability

If you discover a security vulnerability in AuraKit Core (OSS), please **do not** open a public GitHub issue. Instead, use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories) or email the maintainers directly. We commit to acknowledging reports within **48 hours** and publishing a CVE + patch within **14 days** for confirmed critical vulnerabilities.
