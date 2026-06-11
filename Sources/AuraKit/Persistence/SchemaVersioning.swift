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

  public static let versionIdentifier = Schema.Version(1, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [RawMemoryNode.self, MemoryArchiveNode.self]
  }
}

// MARK: - Schema V2

/// AuraKit Schema V2 — Key Version Tracking.
///
/// Adds ``RawMemoryNode/keyVersion`` to track which encryption key version
/// was used for each node's payload. This enables partial key rotation
/// migration — after ``KeyManager/rotateKey()``, nodes encrypted with the
/// previous key can be identified and re-encrypted without a full-table scan.
///
/// This is a lightweight migration from V1 — the new field has a default
/// value of `0`, so SwiftData can perform the migration automatically without
/// custom data transformation logic.
public enum AuraKitSchemaV2: VersionedSchema {

  public static let versionIdentifier = Schema.Version(2, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [RawMemoryNode.self, MemoryArchiveNode.self]
  }
}

// MARK: - Migration Plan

/// The master migration plan for AuraKit's SwiftData schema.
///
/// Contains the V1 → V2 lightweight migration (adding `keyVersion` to
/// `RawMemoryNode`). When future schema changes are needed, add new
/// `VersionedSchema` enums and corresponding migration stages.
///
/// ## Example — Adding a V2 → V3 Custom Migration
///
/// ```swift
/// static var stages: [MigrationStage] {
///     [
///         .lightweight(fromVersion: AuraKitSchemaV1.self, toVersion: AuraKitSchemaV2.self),
///         .custom(
///             fromVersion: AuraKitSchemaV2.self,
///             toVersion: AuraKitSchemaV3.self,
///             willMigrate: { context in },
///             didMigrate: { context in try context.save() }
///         )
///     ]
/// }
/// ```
public enum AuraKitMigrationPlan: SchemaMigrationPlan {

  public static var schemas: [any VersionedSchema.Type] {
    [AuraKitSchemaV1.self, AuraKitSchemaV2.self]
  }

  public static var stages: [MigrationStage] {
    [
      // V1 → V2: Adding keyVersion field to RawMemoryNode.
      // Lightweight migration — the new field has a default value (0),
      // so no custom data transformation is required.
      .lightweight(
        fromVersion: AuraKitSchemaV1.self,
        toVersion: AuraKitSchemaV2.self
      ),
    ]
  }
}

