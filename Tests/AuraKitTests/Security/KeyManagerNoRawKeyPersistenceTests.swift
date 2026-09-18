// KeyManagerNoRawKeyPersistenceTests.swift
// AuraKitTests — Security Hardening Regression Guard
//
// Regression tests for the "raw AES key must never be persisted to Keychain"
// invariant. See KeyManager.swift doc comment for the full rationale.
//
// These tests lock in the *contract* that clearing the in-memory cache must
// force a fresh derivation rather than a disk-backed short-circuit, and that
// independent managers never share cached state.

import CryptoKit
import Foundation
import Testing

@testable import AuraKit

@Suite("KeyManager — No Raw Key Persistence (Security Regression Guard)")
struct KeyManagerNoRawKeyPersistenceTests {

  /// After `clearCachedKey()`, a `KeyManager` backed by a static key must
  /// NOT silently return the same key from a disk cache. On simulator,
  /// `deriveKey()` succeeds via the software P256 path (producing a
  /// *different* key); on environments without Keychain access, it throws.
  /// Both outcomes prove the static key was not recovered from disk.
  @Test("clearCachedKey() fully drops static key — no disk-backed fallback")
  func clearedStaticKeyIsNotRecoverableFromDisk() async throws {
    let staticKey = SymmetricKey(size: .bits256)
    let manager = KeyManager(staticKey: staticKey)

    let keyBefore = try await manager.symmetricKey()
    staticKey.withUnsafeBytes { expected in
      keyBefore.withUnsafeBytes { actual in
        #expect(expected.elementsEqual(actual), "Before clear, cached key matches static key")
      }
    }

    await manager.clearCachedKey()

    // After clearing, symmetricKey() falls through to deriveKey().
    // On simulator: succeeds with a different key (software P256 derivation).
    // Without Keychain entitlements: may throw.
    // In neither case should the original static key be returned — that
    // would prove a Keychain-cached copy leaked through.
    if let keyAfter = try? await manager.symmetricKey() {
      keyAfter.withUnsafeBytes { afterBytes in
        staticKey.withUnsafeBytes { staticBytes in
          // The derived key should differ from the static key,
          // proving no disk-backed shortcut was used.
          #expect(
            !afterBytes.elementsEqual(staticBytes),
            "After clearCachedKey(), the returned key must not match the original static key."
          )
        }
      }
    }
    // If symmetricKey() threw, the cache was successfully invalidated
    // and no fallback source exists — test passes.
  }

  /// Two independently constructed `KeyManager` instances sharing no state
  /// must not coincidentally agree on a key. Guards against a regression
  /// where a process-wide or disk-cached key leaks across manager instances.
  @Test("Independent staticKey managers never share cached state")
  func independentManagersDoNotShareCache() async throws {
    let keyA = SymmetricKey(size: .bits256)
    let keyB = SymmetricKey(size: .bits256)

    let managerA = KeyManager(staticKey: keyA)
    let managerB = KeyManager(staticKey: keyB)

    let resolvedA = try await managerA.symmetricKey()
    let resolvedB = try await managerB.symmetricKey()

    resolvedA.withUnsafeBytes { a in
      resolvedB.withUnsafeBytes { b in
        #expect(
          !a.elementsEqual(b),
          "Two managers with distinct static keys must never resolve to the same bytes."
        )
      }
    }
  }
}
