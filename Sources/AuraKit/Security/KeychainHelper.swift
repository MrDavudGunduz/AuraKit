// KeychainHelper.swift
// AuraKit — Security Layer
//
// Minimal Keychain wrapper for AuraKit's internal key storage needs.
// Covers exactly two use cases: HKDF salt storage and Secure Enclave key references.
// Extracted from KeyManager.swift for single-responsibility compliance.

import Foundation
import os.log

// MARK: - KeychainHelper

/// Minimal Keychain wrapper for AuraKit's internal key storage needs.
///
/// All items are stored with:
/// - `kSecAttrAccessible: .whenUnlockedThisDeviceOnly` — not backed up to iCloud
/// - `kSecAttrSynchronizable: false` — local-only
///
/// This is intentionally a minimal enum, not a general-purpose Keychain library.
/// It covers exactly the two use cases AuraKit needs: salt storage and SE key references.
enum KeychainHelper {

  /// Logger for Keychain diagnostic output.
  private static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "KeychainHelper"
  )

  /// Stores data in the Keychain, replacing any existing item with the same
  /// service/account pair.
  ///
  /// - Returns: `true` if the item was stored successfully; `false` if
  ///   `SecItemAdd` returned an error status (logged at error level).
  @discardableResult
  static func store(data: Data, service: String, account: String) -> Bool {
    // Delete any existing item first (idempotent)
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    // Add the new item — uses Swift Bool literals instead of force-unwrapped
    // CFBoolean constants for safety and SwiftLint compliance.
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status != errSecSuccess {
      KeychainHelper.logger.error(
        "[AuraKit] KeychainHelper: SecItemAdd failed — OSStatus \(status) for account '\(account)'."
      )
    }
    return status == errSecSuccess
  }

  /// Retrieves data from the Keychain, or returns `nil` if no matching item exists.
  static func retrieve(service: String, account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  /// Deletes a specific item from the Keychain.
  @discardableResult
  static func delete(service: String, account: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    return SecItemDelete(query as CFDictionary) == errSecSuccess
  }
}
