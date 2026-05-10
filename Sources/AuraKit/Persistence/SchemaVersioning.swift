// SchemaVersioning.swift
// AuraKit — Persistence Layer
//
// Schema versioning infrastructure for SwiftData migration support.
// When model schema changes are needed (e.g., Phase 3 Survival Index fields),
// add a new VersionedSchema enum and a corresponding MigrationStage.

import Foundation
import SwiftData

// MARK: - Schema V1

/// AuraKit Schema V1 — Phase 1+2 baseline.
///
/// This is the initial schema containing:
/// - ``RawMemoryNode``: Encrypted spatial event storage with recall tracking
/// - ``MemoryArchiveNode``: Compressed semantic archive for cognitive compression
///
/// ## Adding a New Schema Version
///
/// 1. Define `AuraKitSchemaV2` with the updated model definitions
/// 2. Add a `MigrationStage` from V1 → V2 in ``AuraKitMigrationPlan/stages``
/// 3. `PersistenceController` already passes the migration plan to `ModelContainer`
///
/// ```swift
/// enum AuraKitSchemaV2: VersionedSchema {
///     static var versionIdentifier = Schema.Version(2, 0, 0)
///     static var models: [any PersistentModel.Type] {
///         [RawMemoryNodeV2.self, MemoryArchiveNode.self]
///     }
/// }
/// ```
public enum AuraKitSchemaV1: VersionedSchema {

  public static let versionIdentifier: Schema.Version = Schema.Version(1, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [RawMemoryNode.self, MemoryArchiveNode.self]
  }
}

// MARK: - Migration Plan

/// The master migration plan for AuraKit's SwiftData schema.
///
/// Currently contains only V1 (no migrations needed). When V2 is introduced,
/// add a lightweight or custom migration stage here.
///
/// ## Example — Adding a V1 → V2 Lightweight Migration
///
/// ```swift
/// static var stages: [MigrationStage] {
///     [
///         .lightweight(
///             fromVersion: AuraKitSchemaV1.self,
///             toVersion: AuraKitSchemaV2.self
///         )
///     ]
/// }
/// ```
///
/// ## Example — Adding a V1 → V2 Custom Migration
///
/// ```swift
/// static var stages: [MigrationStage] {
///     [
///         .custom(
///             fromVersion: AuraKitSchemaV1.self,
///             toVersion: AuraKitSchemaV2.self,
///             willMigrate: { context in
///                 // Pre-migration logic
///             },
///             didMigrate: { context in
///                 // Post-migration logic
///                 try context.save()
///             }
///         )
///     ]
/// }
/// ```
public enum AuraKitMigrationPlan: SchemaMigrationPlan {

  public static var schemas: [any VersionedSchema.Type] {
    [AuraKitSchemaV1.self]
  }

  public static var stages: [MigrationStage] {
    // No migrations yet — V1 is the initial schema.
    // Future migrations will be appended here in chronological order.
    []
  }
}
