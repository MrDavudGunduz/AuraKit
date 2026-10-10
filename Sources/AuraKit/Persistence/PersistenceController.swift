// PersistenceController.swift
// AuraKit — Persistence Layer
//
// Factory for ModelContainer. Provides production (on-disk SQLite, local-only)
// and in-memory (testing) configurations.
//
// CloudKit sync is intentionally NOT supported: AuraKit's AES key is derived
// from a device-bound Secure Enclave key, so ciphertext synced to another
// device could never be decrypted. See ``PersistenceController/makeContainer(cloudKitContainerIdentifier:)``.

import Foundation
import os.log
import SwiftData

// MARK: - PersistenceController

/// Factory and configuration hub for AuraKit's SwiftData `ModelContainer`.
///
/// `PersistenceController` provides two container configurations:
///
/// | Mode          | Backing Store  | CloudKit Sync | Use Case             |
/// |---------------|----------------|---------------|----------------------|
/// | `.production` | On-disk SQLite | Unsupported   | Ship builds          |
/// | `.inMemory`   | In-memory      | Disabled      | Unit tests, previews |
///
/// ## Why CloudKit Sync Is Unsupported
///
/// - The AES-256 key is derived from a **non-exportable Secure Enclave key**
///   stored in a `ThisDeviceOnly` Keychain item. Another device cannot derive
///   the same key, so synced ciphertext would be permanently unreadable there.
/// - CloudKit-backed SwiftData also requires every non-optional attribute to
///   declare a default value, which the current `@Model` types do not.
///
/// Silently enabling sync would therefore produce undecryptable data, so the
/// CloudKit entry points fail fast with ``AuraError/invalidConfiguration(reason:)``.
/// Multi-device sync requires a dedicated key-sharing design (e.g. a wrapped key
/// in iCloud Keychain) and is tracked on the roadmap.
///
/// ## Thread Safety
///
/// `PersistenceController` is a `Sendable` value type. `ModelContainer` itself
/// is thread-safe and can be shared across actors.
public struct PersistenceController: Sendable {

  // MARK: - Internal Logger

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "PersistenceController"
  )

  // MARK: - Schema

  /// The complete SwiftData schema for AuraKit's memory hierarchy.
  ///
  /// Contains all `@Model` types that form the encrypted vector store.
  /// This schema is versioned — migration support will be added in Phase 5.
  public static let schema = Schema([
    RawMemoryNode.self,
    MemoryArchiveNode.self,
  ])

  // MARK: - Container Factory

  /// Creates a production `ModelContainer` backed by on-disk, local-only SQLite storage.
  ///
  /// - Parameter cloudKitContainerIdentifier: **Unsupported.** Must be `nil`.
  ///   Passing a non-`nil` value throws, because CloudKit sync would replicate
  ///   ciphertext that other devices cannot decrypt (see the type documentation).
  /// - Returns: A configured `ModelContainer` ready for use.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` if a CloudKit identifier
  ///   is supplied; otherwise any error from `ModelContainer` creation.
  public static func makeContainer(
    cloudKitContainerIdentifier: String? = nil
  ) throws -> ModelContainer {
    if cloudKitContainerIdentifier != nil {
      throw cloudKitUnsupportedError()
    }
    return try makeLocalContainer()
  }

  /// Creates a production `ModelContainer` with a ``CloudKitConfiguration``.
  ///
  /// - Important: CloudKit sync is **unsupported**; this overload always throws
  ///   ``AuraError/invalidConfiguration(reason:)``. It is retained only for
  ///   source compatibility.
  /// - Parameter cloudKit: Ignored.
  /// - Throws: ``AuraError/invalidConfiguration(reason:)`` — always.
  @available(
    *, deprecated,
    message: "CloudKit sync is unsupported: the encryption key is device-bound. Use makeContainer() for local storage."
  )
  public static func makeContainer(
    cloudKit config: CloudKitConfiguration
  ) throws -> ModelContainer {
    throw cloudKitUnsupportedError()
  }

  /// Builds the local-only (no CloudKit) on-disk container.
  private static func makeLocalContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(
      "AuraKit",
      schema: schema,
      isStoredInMemoryOnly: false,
      allowsSave: true,
      groupContainer: .automatic,
      cloudKitDatabase: .none
    )

    let container = try ModelContainer(
      for: schema,
      migrationPlan: AuraKitMigrationPlan.self,
      configurations: [configuration]
    )

    PersistenceController.logger.info(
      "[AuraKit] PersistenceController: Production container created (local-only, CloudKit disabled)."
    )

    return container
  }

  /// The error thrown by every CloudKit entry point.
  private static func cloudKitUnsupportedError() -> AuraError {
    AuraError.invalidConfiguration(
      reason: "CloudKit sync is not supported. AuraKit's AES key is derived from a "
        + "device-bound Secure Enclave key, so data synced to another device could "
        + "never be decrypted. Pass nil / use makeContainer() for local-only storage."
    )
  }

  /// Creates an in-memory `ModelContainer` for unit testing and SwiftUI previews.
  ///
  /// The store exists only for the lifetime of the returned container.
  /// CloudKit sync is always disabled in this mode.
  ///
  /// - Returns: A transient `ModelContainer` with no on-disk persistence.
  /// - Throws: If the container cannot be created.
  public static func makeInMemoryContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(
      "AuraKit-InMemory-\(UUID().uuidString)",
      schema: schema,
      isStoredInMemoryOnly: true,
      allowsSave: true
    )

    let container = try ModelContainer(
      for: schema,
      migrationPlan: AuraKitMigrationPlan.self,
      configurations: [configuration]
    )

    PersistenceController.logger.debug(
      "[AuraKit] PersistenceController: In-memory container created (test/preview mode)."
    )

    return container
  }
}

// MARK: - CloudKitConfiguration

/// Configuration placeholder for a future CloudKit sync implementation.
///
/// - Important: CloudKit sync is **currently unsupported**. The only consumer,
///   ``PersistenceController/makeContainer(cloudKit:)``, throws
///   ``AuraError/invalidConfiguration(reason:)``. The type is retained for
///   source compatibility until a device-independent key-sharing design lands.
///
/// ## Thread Safety
///
/// `CloudKitConfiguration` is an immutable value type conforming to `Sendable`.
/// It can be shared freely across concurrency domains.
public struct CloudKitConfiguration: Sendable, Equatable {

  /// The CloudKit container identifier (e.g., `"iCloud.com.yourcompany.AuraKit"`).
  ///
  /// This must match the CloudKit container configured in your app's
  /// entitlements file and the CloudKit Dashboard.
  public let containerIdentifier: String

  /// Creates a CloudKit configuration with the given container identifier.
  ///
  /// - Parameter containerIdentifier: The CloudKit container ID matching
  ///   your app's entitlements (e.g., `"iCloud.com.yourcompany.AuraKit"`).
  public init(containerIdentifier: String) {
    self.containerIdentifier = containerIdentifier
  }
}

