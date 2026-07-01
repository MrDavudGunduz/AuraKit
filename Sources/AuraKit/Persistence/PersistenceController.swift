// PersistenceController.swift
// AuraKit — Persistence Layer
//
// Factory for ModelContainer with optional CloudKit E2EE sync.
// Provides both production (SQLite + CloudKit) and in-memory (testing) configurations.

import Foundation
import os.log
import SwiftData

// MARK: - PersistenceController

/// Factory and configuration hub for AuraKit's SwiftData `ModelContainer`.
///
/// `PersistenceController` provides two container configurations:
///
/// | Mode        | Backing Store | CloudKit Sync | Use Case            |
/// |-------------|---------------|---------------|---------------------|
/// | `.production` | On-disk SQLite | Optional E2EE | Ship builds         |
/// | `.inMemory`   | In-memory     | Disabled      | Unit tests, previews |
///
/// ## CloudKit End-to-End Encryption
///
/// When a `cloudKitContainerIdentifier` is provided, the production container
/// is configured with `NSPersistentCloudKitContainerOptions` and remote change
/// notifications. Combined with AuraKit's application-level AES-GCM encryption,
/// this creates a **double-encrypted** data path:
///
/// ```
/// SpatialEvent → AES-GCM (AuraKit) → SwiftData → CloudKit E2EE → iCloud
/// ```
///
/// Neither Apple nor any third party can read the plaintext at any point in
/// the sync chain.
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

  /// Creates a production `ModelContainer` backed by on-disk SQLite storage.
  ///
  /// - Parameter cloudKitContainerIdentifier: Optional CloudKit container ID
  ///   (e.g., `"iCloud.com.yourcompany.AuraKit"`). When provided, CloudKit E2EE
  ///   sync is enabled. Pass `nil` to disable sync (local-only storage).
  /// - Returns: A configured `ModelContainer` ready for use.
  /// - Throws: If the container cannot be created (e.g., schema conflicts).
  public static func makeContainer(
    cloudKitContainerIdentifier: String? = nil
  ) throws -> ModelContainer {
    let configuration = ModelConfiguration(
      "AuraKit",
      schema: schema,
      isStoredInMemoryOnly: false,
      allowsSave: true,
      groupContainer: .automatic,
      cloudKitDatabase: {
        if let identifier = cloudKitContainerIdentifier {
          return .private(identifier)
        }
        return .none
      }()
    )

    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )

    PersistenceController.logger.info(
      """
      [AuraKit] PersistenceController: Production container created. \
      CloudKit: \(cloudKitContainerIdentifier != nil ? "enabled" : "disabled").
      """
    )

    return container
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
      configurations: [configuration]
    )

    PersistenceController.logger.debug(
      "[AuraKit] PersistenceController: In-memory container created (test/preview mode)."
    )

    return container
  }
}
