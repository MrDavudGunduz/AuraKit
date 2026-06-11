// RawMemoryNode.swift
// AuraKit — Persistence Layer
//
// SwiftData model representing a single encrypted spatial memory.
// The encryptedPayload contains the AES-GCM ciphertext of the serialised
// SpatialEvent — the plaintext is NEVER stored in the database.

import Foundation
import SwiftData

// MARK: - RawMemoryNode

/// A single encrypted spatial memory record persisted via SwiftData.
///
/// `RawMemoryNode` is the primary storage unit in AuraKit's memory hierarchy.
/// Each node corresponds to one ``SpatialEvent`` captured by the ``CaptureActor``,
/// encrypted at rest using AES-GCM with a Secure Enclave–derived key.
///
/// ## Security
///
/// The ``encryptedPayload`` field stores the complete `SpatialEvent` as ciphertext
/// in AES-GCM combined format (nonce + ciphertext + auth tag). The only
/// unencrypted metadata stored alongside are:
/// - ``score`` — needed for Survival Index queries without decryption
/// - ``eventType`` — needed for filtered fetch predicates
/// - ``timestamp`` — needed for time-based pruning queries
/// - ``recalled`` — needed for Survival Index `Rⁿ` computation
///
/// ## CloudKit Sync
///
/// When `NSPersistentCloudKitContainer` is configured with E2EE, the
/// `encryptedPayload` is **double-encrypted**: once by AuraKit (AES-GCM)
/// and once by CloudKit's own encryption layer. This ensures that even
/// Apple's CloudKit servers see only opaque ciphertext.
///
/// ## Survival Index
///
/// The ``score`` and ``recalled`` fields are consumed by the Phase 3
/// `IntelligenceActor` to compute:
///
/// ```
/// SI(t) = S₀ · Rⁿ · e^(-λt)
/// ```
///
/// where `S₀` = ``score``, `n` = ``recalled``, and `t` = age since ``timestamp``.
@Model
public final class RawMemoryNode {

  // MARK: - Properties

  /// Unique identifier for this memory node.
  ///
  /// Enforced as unique at the SwiftData layer to prevent duplicate writes
  /// from concurrent capture paths.
  @Attribute(.unique)
  public var id: UUID

  /// AES-GCM encrypted payload containing the serialised ``SpatialEvent``.
  ///
  /// Format: `nonce (12 bytes) || ciphertext || auth tag (16 bytes)`.
  /// Decryption requires the symmetric key derived from the Secure Enclave.
  ///
  /// - Important: This field **must never** be logged, printed, or exposed
  ///   to the host application's UI layer without decryption.
  public var encryptedPayload: Data

  /// Heuristic importance score assigned by ``HeuristicRouter``.
  ///
  /// Stored unencrypted to enable efficient SwiftData sort descriptors
  /// and Survival Index calculations without decrypting the payload.
  /// Range: `[0.0, 1.0]`.
  public var score: Double

  /// Wall-clock timestamp of the original ``SpatialEvent``.
  ///
  /// Stored unencrypted for time-based pruning queries.
  public var timestamp: Date

  /// The spatial event classification (gaze, touch, move, pinch, drag).
  ///
  /// Stored as a raw `String` value of ``SpatialEventType`` for SwiftData
  /// compatibility. Use ``spatialEventType`` for typed access.
  public var eventType: String

  /// Number of times this memory has been recalled (queried).
  ///
  /// Used in the Survival Index formula as the recall multiplier exponent `n`.
  /// Incremented by ``EncryptedMemoryStore`` on each query hit.
  public var recalled: Int

  /// The encryption key version used to encrypt this node's payload.
  ///
  /// Corresponds to ``KeyManager/keyVersion`` at the time of encryption.
  /// Enables partial key rotation migration — after ``KeyManager/rotateKey()``,
  /// nodes with `keyVersion < currentVersion` can be identified and re-encrypted
  /// without a full-table scan.
  ///
  /// Defaults to `0` for backward compatibility with V1 schema records that
  /// predate the key version tracking feature.
  public var keyVersion: Int

  // MARK: - Init

  /// Creates a new `RawMemoryNode` with the given encrypted payload and metadata.
  ///
  /// - Parameters:
  ///   - id: Unique identifier. Defaults to a new `UUID()`.
  ///   - encryptedPayload: AES-GCM combined ciphertext of the serialised `SpatialEvent`.
  ///   - score: Heuristic score from the router.
  ///   - timestamp: Event timestamp.
  ///   - eventType: Flat classification for indexed queries.
  ///   - recalled: Initial recall count. Defaults to `0`.
  ///   - keyVersion: The encryption key version. Defaults to `0`.
  public init(
    id: UUID = UUID(),
    encryptedPayload: Data,
    score: Double,
    timestamp: Date,
    eventType: SpatialEventType,
    recalled: Int = 0,
    keyVersion: Int = 0
  ) {
    self.id = id
    self.encryptedPayload = encryptedPayload
    self.score = score
    self.timestamp = timestamp
    self.eventType = eventType.rawValue
    self.recalled = recalled
    self.keyVersion = keyVersion
  }
}

// MARK: - Convenience Accessors

extension RawMemoryNode {

  /// Typed accessor for the stored event type.
  ///
  /// Returns `nil` if the stored raw value does not match any ``SpatialEventType`` case
  /// (should not occur under normal operation; indicates data corruption if it does).
  public var spatialEventType: SpatialEventType? {
    SpatialEventType(rawValue: eventType)
  }
}
