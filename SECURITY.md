# AuraKit — Security Architecture

## Philosophy: Zero-Trust, Privacy-First

AuraKit operates on the principle that **user data should never need to be trusted to any party — including AuraKit itself**. All sensitive information is encrypted before it reaches storage, keys are generated and protected by dedicated hardware, and no data ever traverses an external network.

> **TL;DR:** Your users' memories stay on their devices. Period.

---

## Threat Model

| Threat                  | Mitigation                                                        |
| ----------------------- | ----------------------------------------------------------------- |
| Physical device seizure | AES-GCM encryption at rest (Secure Enclave key)                   |
| Cloud server breach     | CloudKit E2EE — Apple cannot read ciphertext                      |
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

### Key Storage

The derived `SymmetricKey` is stored in the **iOS Keychain** with:

- `kSecAttrAccessible`: `.whenUnlockedThisDeviceOnly` — key not available when device is locked or backed up to iCloud (unencrypted)
- `kSecAttrAccessControl` with `.biometryCurrentSet` for high-sensitivity deployments

---

## Data in Transit — CloudKit End-to-End Encryption

AuraKit uses `NSPersistentCloudKitContainer` with Apple's built-in E2EE capabilities introduced in iOS 15+.

### What E2EE means in CloudKit context

| Party                                      | Can read the data?                    |
| ------------------------------------------ | ------------------------------------- |
| AuraKit framework                          | ✅ (holds the local key)              |
| The user (same Apple ID, different device) | ✅ (key derived from iCloud Keychain) |
| Apple's CloudKit servers                   | ❌ (see encrypted blob only)          |
| AuraKit Inc.                               | ❌ (no server, no telemetry)          |
| Law enforcement (with Apple warrant)       | ❌ (Apple holds no plaintext)         |

### Implementation Notes

```swift
let container = NSPersistentCloudKitContainer(name: "AuraKit")
let description = container.persistentStoreDescriptions.first!

// Enable CloudKit sync
description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
    containerIdentifier: "iCloud.com.yourcompany.AuraKit"
)

// Opt into E2EE zone (CKDatabase.privateCloudDatabase with encrypted zone)
// Records in this zone are encrypted client-side before leaving the device
description.setOption(true as NSNumber,
                      forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
```

All `encryptedPayload` and `encryptedSummary` fields are **already encrypted** before being written to the SwiftData store — so even if CloudKit's own encryption layer were bypassed, the data remains unreadable.

---

## On-Device LLM — Network Isolation (Enterprise)

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
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string> <!-- Framework configuration storage -->
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### Validating the Manifest

```bash
# Validate before App Store submission (Xcode 15+)
xcodebuild -validatePrivacyManifest \
    -scheme AuraKit \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

---

## Security Checklist for Integrators

Before shipping an app that uses AuraKit, verify:

- [ ] `AuraConfiguration` does not expose raw symmetric keys to the host app
- [ ] `RawMemoryNode.encryptedPayload` is never logged (ensure `os_log` categories are private)
- [ ] SwiftData store file is excluded from iCloud backup unless CloudKit E2EE is configured
- [ ] App entitlements do not include `com.apple.security.network.client` in the Intelligence extension if using Enterprise tier
- [ ] Keychain item accessibility is set to `.whenUnlockedThisDeviceOnly` (not `.always`)
- [ ] Instruments → Leaks run confirms no symmetric key material is retained beyond `MemoryActor` closure scope

---

## Reporting a Vulnerability

If you discover a security vulnerability in AuraKit Core (OSS), please **do not** open a public GitHub issue. Instead, use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories) or email the maintainers directly. We commit to acknowledging reports within **48 hours** and publishing a CVE + patch within **14 days** for confirmed critical vulnerabilities.
