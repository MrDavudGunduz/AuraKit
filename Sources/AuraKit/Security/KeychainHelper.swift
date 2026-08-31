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
    subsystem: AuraKitConstants.subsystem,
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
    // SECURITY: Atomic update pattern.
    //
    // Previous implementation used Delete + Add, which is NOT crash-safe:
    // if the process is killed between SecItemDelete and SecItemAdd, the
    // existing item is lost and the new item is never written — causing
    // permanent data loss for encryption keys and HKDF salts.
    //
    // New approach: SecItemUpdate first (atomic in-place replacement),
    // falling back to SecItemAdd only when the item doesn't exist yet.
    // This ensures the existing item is never deleted without being replaced.

    var matchQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup {
      matchQuery[kSecAttrAccessGroup as String] = group
    }

    // Attempt atomic in-place update first.
    let updateAttributes: [String: Any] = [
      kSecValueData as String: data,
    ]
    let updateStatus = SecItemUpdate(
      matchQuery as CFDictionary,
      updateAttributes as CFDictionary
    )

    if updateStatus == errSecSuccess {
      return true
    }

    // Item does not exist yet — perform initial add with full attributes.
    if updateStatus == errSecItemNotFound {
      var addQuery = matchQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      addQuery[kSecAttrSynchronizable as String] = false

      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      if addStatus != errSecSuccess {
        KeychainHelper.logger.error(
          "[AuraKit] KeychainHelper: SecItemAdd failed — OSStatus \(addStatus) for account '\(account)'."
        )
      }
      return addStatus == errSecSuccess
    }

    // Unexpected error during update
    KeychainHelper.logger.error(
      "[AuraKit] KeychainHelper: SecItemUpdate failed — OSStatus \(updateStatus) for account '\(account)'."
    )
    return false
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
    // Atomic update pattern — same crash-safety rationale as `store()`.
    var matchQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup {
      matchQuery[kSecAttrAccessGroup as String] = group
    }

    let updateAttributes: [String: Any] = [
      kSecValueData as String: data,
    ]
    let updateStatus = SecItemUpdate(
      matchQuery as CFDictionary,
      updateAttributes as CFDictionary
    )

    if updateStatus == errSecSuccess {
      return
    }

    // Item does not exist yet — perform initial add with full attributes.
    if updateStatus == errSecItemNotFound {
      var addQuery = matchQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      addQuery[kSecAttrSynchronizable as String] = false

      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        KeychainHelper.logger.error(
          "[AuraKit] KeychainHelper: SecItemAdd failed — OSStatus \(addStatus) for account '\(account)'."
        )
        throw AuraError.keychainOperationFailed(
          operation: "store",
          status: Int(addStatus)
        )
      }
      return
    }

    // Unexpected error during update
    KeychainHelper.logger.error(
      "[AuraKit] KeychainHelper: SecItemUpdate failed — OSStatus \(updateStatus) for account '\(account)'."
    )
    throw AuraError.keychainOperationFailed(
      operation: "store",
      status: Int(updateStatus)
    )
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
  /// This operation is **idempotent**: if the item does not exist (`errSecItemNotFound`),
  /// the call succeeds without throwing, ensuring robust cleanup routines.
  ///
  /// - Parameters:
  ///   - service: The Keychain service identifier.
  ///   - account: The Keychain account identifier.
  ///   - accessGroup: Optional Keychain access group for App Extension sharing.
  /// - Throws: ``AuraError/keychainOperationFailed(operation:status:)`` if
  ///   `SecItemDelete` returns an unexpected error status (other than success or not found).
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
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AuraError.keychainOperationFailed(
        operation: "delete",
        status: Int(status)
      )
    }
  }
}
