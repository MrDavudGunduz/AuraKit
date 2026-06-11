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
/// ## Access Group Support
///
/// All methods accept an optional `accessGroup` parameter for App Extension
/// and multi-target Keychain sharing. When `nil` (default), the Keychain item
/// belongs to the calling app's default access group — matching the original
/// pre-access-group behaviour.
///
/// This is intentionally a minimal enum, not a general-purpose Keychain library.
/// It covers exactly the use cases AuraKit needs: salt storage and SE key references.
enum KeychainHelper {

  /// Logger for Keychain diagnostic output.
  private static let logger = Logger(
    subsystem: "com.aurakit.framework",
    category: "KeychainHelper"
  )

  // MARK: - Store

  /// Stores data in the Keychain, replacing any existing item with the same
  /// service/account pair.
  ///
  /// - Parameters:
  ///   - data: The data to store.
  ///   - service: The Keychain service identifier.
  ///   - account: The Keychain account identifier.
  ///   - accessGroup: Optional Keychain access group for App Extension sharing.
  ///     Pass `nil` (default) to use the app's default access group.
  /// - Returns: `true` if the item was stored successfully; `false` if
  ///   `SecItemAdd` returned an error status (logged at error level).
  @discardableResult
  static func store(
    data: Data,
    service: String,
    account: String,
    accessGroup: String? = nil
  ) -> Bool {
    // Delete any existing item first (idempotent)
    var deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup {
      deleteQuery[kSecAttrAccessGroup as String] = group
    }
    SecItemDelete(deleteQuery as CFDictionary)

    // Add the new item — uses Swift Bool literals instead of force-unwrapped
    // CFBoolean constants for safety and SwiftLint compliance.
    var addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    if let group = accessGroup {
      addQuery[kSecAttrAccessGroup as String] = group
    }
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status != errSecSuccess {
      KeychainHelper.logger.error(
        "[AuraKit] KeychainHelper: SecItemAdd failed — OSStatus \(status) for account '\(account)'."
      )
    }
    return status == errSecSuccess
  }

  /// Throwing variant of ``store(data:service:account:accessGroup:)`` that
  /// propagates the Security framework `OSStatus` via ``AuraError``.
  ///
  /// Use this in contexts where the Keychain write is critical and the caller
  /// needs precise failure diagnostics (e.g., ``KeyManager`` key persistence).
  ///
  /// - Parameters:
  ///   - data: The data to store.
  ///   - service: The Keychain service identifier.
  ///   - account: The Keychain account identifier.
  ///   - accessGroup: Optional Keychain access group for App Extension sharing.
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if
  ///   `SecItemAdd` returns a non-success status.
  static func storeOrThrow(
    data: Data,
    service: String,
    account: String,
    accessGroup: String? = nil
  ) throws {
    var deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup {
      deleteQuery[kSecAttrAccessGroup as String] = group
    }
    SecItemDelete(deleteQuery as CFDictionary)

    var addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    if let group = accessGroup {
      addQuery[kSecAttrAccessGroup as String] = group
    }
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      KeychainHelper.logger.error(
        "[AuraKit] KeychainHelper: SecItemAdd failed — OSStatus \(status) for account '\(account)'."
      )
      throw AuraError.keychainOperationFailed(
        operation: "store",
        status: Int(status)
      )
    }
  }

  // MARK: - Retrieve

  /// Retrieves data from the Keychain, or returns `nil` if no matching item exists.
  ///
  /// - Parameters:
  ///   - service: The Keychain service identifier.
  ///   - account: The Keychain account identifier.
  ///   - accessGroup: Optional Keychain access group for App Extension sharing.
  ///     Pass `nil` (default) to use the app's default access group.
  /// - Returns: The stored data, or `nil` if no matching item exists.
  static func retrieve(
    service: String,
    account: String,
    accessGroup: String? = nil
  ) -> Data? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let group = accessGroup {
      query[kSecAttrAccessGroup as String] = group
    }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  // MARK: - Delete

  /// Deletes a specific item from the Keychain.
  ///
  /// - Parameters:
  ///   - service: The Keychain service identifier.
  ///   - account: The Keychain account identifier.
  ///   - accessGroup: Optional Keychain access group for App Extension sharing.
  ///     Pass `nil` (default) to use the app's default access group.
  /// - Returns: `true` if the item was deleted successfully.
  @discardableResult
  static func delete(
    service: String,
    account: String,
    accessGroup: String? = nil
  ) -> Bool {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup {
      query[kSecAttrAccessGroup as String] = group
    }
    return SecItemDelete(query as CFDictionary) == errSecSuccess
  }

  /// Throwing variant of ``delete(service:account:accessGroup:)`` that
  /// propagates the Security framework `OSStatus` via ``AuraError``.
  ///
  /// - Parameters:
  ///   - service: The Keychain service identifier.
  ///   - account: The Keychain account identifier.
  ///   - accessGroup: Optional Keychain access group for App Extension sharing.
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if
  ///   `SecItemDelete` returns a non-success status.
  static func deleteOrThrow(
    service: String,
    account: String,
    accessGroup: String? = nil
  ) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup {
      query[kSecAttrAccessGroup as String] = group
    }
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess else {
      throw AuraError.keychainOperationFailed(
        operation: "delete",
        status: Int(status)
      )
    }
  }
}
