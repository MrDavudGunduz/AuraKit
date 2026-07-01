// SchemaVersioning.swift
// AuraKit — Persistence Layer
//
// Schema versioning infrastructure for SwiftData migration support.
// When model schema changes are needed, add a new VersionedSchema enum
// and a corresponding MigrationStage.
//
// ## History
//
// V1 (removed): Initial schema without keyVersion on RawMemoryNode.
//   Removed because both V1 and V2 referenced the same live model types,
//   which caused NSLightweightMigrationStage to crash — SwiftData requires
//   fully duplicated @Model classes per version to compute schema diffs.
//   Since AuraKit is pre-release with no production data to migrate,
//   the broken V1→V2 migration was removed entirely.

import Foundation
import SwiftData

// MARK: - Current Schema

/// AuraKit Schema V2 — Current baseline.
///
/// Contains:
/// - ``RawMemoryNode``: Encrypted spatial event storage with recall tracking
///   and key version tracking for partial rotation migration.
/// - ``MemoryArchiveNode``: Compressed semantic archive for cognitive compression
///
/// ## Adding a New Schema Version
///
/// 1. Rename this to `AuraKitSchemaV2` (freeze the model definitions inline)
/// 2. Define `AuraKitSchemaV3` with the updated model definitions
/// 3. Add a `MigrationStage` from V2 → V3 in ``AuraKitMigrationPlan/stages``
/// 4. Update ``AuraKitMigrationPlan/schemas`` to include both versions
///
/// - Important: Each `VersionedSchema` must contain its own **copy** of the
///   `@Model` types — do NOT share the same live type across versions.
///   SwiftData requires distinct model definitions to compute schema diffs.
public enum AuraKitSchemaV2: VersionedSchema {

  public static let versionIdentifier = Schema.Version(2, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [RawMemoryNode.self, MemoryArchiveNode.self]
  }
}

// MARK: - Migration Plan

/// The master migration plan for AuraKit's SwiftData schema.
///
/// Currently contains a single schema version (V2) with no migration stages.
/// When future schema changes are needed:
///
/// 1. Freeze the current schema as `AuraKitSchemaV2` with inline model copies
/// 2. Add the new `AuraKitSchemaV3` referencing the live model types
/// 3. Add a migration stage to ``stages``
///
/// ## Example — Adding a V2 → V3 Migration
///
/// ```swift
/// static var schemas: [any VersionedSchema.Type] {
///     [AuraKitSchemaV2.self, AuraKitSchemaV3.self]
/// }
///
/// static var stages: [MigrationStage] {
///     [
///         .lightweight(
///             fromVersion: AuraKitSchemaV2.self,
///             toVersion: AuraKitSchemaV3.self
///         )
///     ]
/// }
/// ```
public enum AuraKitMigrationPlan: SchemaMigrationPlan {

  public static var schemas: [any VersionedSchema.Type] {
    [AuraKitSchemaV2.self]
  }

  public static var stages: [MigrationStage] {
    []
  }
}

