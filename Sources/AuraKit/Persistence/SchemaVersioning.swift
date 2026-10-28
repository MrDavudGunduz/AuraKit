// SchemaVersioning.swift
// AuraKit — Persistence Layer
//
// Schema versioning infrastructure for SwiftData migration support.
//
// ## Rules
//
// 1. Every `VersionedSchema` owns **nested** copies of its `@Model` types.
//    Never list a live, top-level model type in more than one version —
//    SwiftData then cannot compute a schema diff and lightweight migration
//    crashes (this is exactly why the original V1 had to be deleted).
// 2. The public names (`RawMemoryNode`, `MemoryArchiveNode`) are typealiases
//    to the **current** version's nested types (see RawMemoryNode.swift and
//    MemoryArchiveNode.swift).
// 3. A frozen version is never edited again.
//
// ## History
//
// V1 (removed): Initial schema without keyVersion. Removed pre-release because
//   it shared live model types with V2 (see rule 1).
// V2 (frozen):  RawMemoryNode + MemoryArchiveNode without uniqueness constraints.
// V3 (current): Adds `@Attribute(.unique)` on both `id` columns.

import Foundation
import SwiftData

// MARK: - V2 (Frozen)

/// AuraKit Schema V2 — **frozen**. Kept only as the source of the V2 → V3
/// migration. Do not modify.
public enum AuraKitSchemaV2: VersionedSchema {

  public static let versionIdentifier = Schema.Version(2, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [RawMemoryNode.self, MemoryArchiveNode.self]
  }

  /// Frozen V2 definition of the encrypted raw memory record.
  @Model
  public final class RawMemoryNode {
    public var id: UUID
    public var encryptedPayload: Data
    public var score: Double
    public var timestamp: Date
    public var eventType: String
    public var recalled: Int
    public var keyVersion: Int

    public init(
      id: UUID,
      encryptedPayload: Data,
      score: Double,
      timestamp: Date,
      eventType: String,
      recalled: Int,
      keyVersion: Int
    ) {
      self.id = id
      self.encryptedPayload = encryptedPayload
      self.score = score
      self.timestamp = timestamp
      self.eventType = eventType
      self.recalled = recalled
      self.keyVersion = keyVersion
    }
  }

  /// Frozen V2 definition of the compressed archive record.
  @Model
  public final class MemoryArchiveNode {
    public var id: UUID
    public var encryptedSummary: Data
    public var createdAt: Date
    public var sourceNodeIDsData: Data

    public init(id: UUID, encryptedSummary: Data, createdAt: Date, sourceNodeIDsData: Data) {
      self.id = id
      self.encryptedSummary = encryptedSummary
      self.createdAt = createdAt
      self.sourceNodeIDsData = sourceNodeIDsData
    }
  }
}

// MARK: - V3 (Current)

/// AuraKit Schema V3 — current.
///
/// Contains:
/// - ``RawMemoryNode``: Encrypted spatial event storage with recall tracking
///   and key version tracking for partial rotation migration.
/// - ``MemoryArchiveNode``: Compressed semantic archive for cognitive compression.
///
/// Changes from V2: `id` is `@Attribute(.unique)` on both models, so a
/// duplicate insert upserts instead of creating a second row with the same
/// identity (which would break AAD row binding and recall accounting).
///
/// The model types themselves are declared in `RawMemoryNode.swift` and
/// `MemoryArchiveNode.swift` as extensions of this namespace.
///
/// ## Adding a New Schema Version
///
/// 1. Copy the V3 model declarations into `AuraKitSchemaV3` as frozen
///    nested types (like ``AuraKitSchemaV2``) and stop editing them.
/// 2. Declare `AuraKitSchemaV4` with the new model definitions and point the
///    public typealiases at it.
/// 3. Append a `MigrationStage` (V3 → V4) to ``AuraKitMigrationPlan/stages``
///    and the schema to ``AuraKitMigrationPlan/schemas``.
/// 4. Add an on-disk migration test (see `SchemaMigrationTests`).
public enum AuraKitSchemaV3: VersionedSchema {

  public static let versionIdentifier = Schema.Version(3, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [RawMemoryNode.self, MemoryArchiveNode.self]
  }
}

// MARK: - Migration Plan

/// The master migration plan for AuraKit's SwiftData schema.
///
/// `schemas` is ordered oldest → newest; `stages` contains one stage per
/// adjacent pair.
public enum AuraKitMigrationPlan: SchemaMigrationPlan {

  public static var schemas: [any VersionedSchema.Type] {
    [AuraKitSchemaV2.self, AuraKitSchemaV3.self]
  }

  public static var stages: [MigrationStage] {
    [
      // V2 → V3: adds uniqueness constraints on `id`. IDs have always been
      // random UUIDs, so V2 stores contain no duplicates and the constraint
      // can be added with a lightweight migration.
      .lightweight(fromVersion: AuraKitSchemaV2.self, toVersion: AuraKitSchemaV3.self)
    ]
  }
}
