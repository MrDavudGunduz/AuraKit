// ZeroTrustTests.swift
// AuraKitTests — Phase 2: Zero-Trust Encryption Verification
//
// Validates the core zero-trust contract: data encrypted with one key
// cannot be recovered using a different key, and ciphertext stored in
// SwiftData is never decodable as plaintext.

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - Zero-Trust Encryption

@Suite("Zero-Trust Encryption")
struct ZeroTrustTests {

  /// Creates a mismatched store pair sharing the same SwiftData container
  /// but using independently generated encryption keys.
  private func makePair() throws -> (
    writer: EncryptedMemoryStore,
    reader: EncryptedMemoryStore
  ) {
    let container = try PersistenceController.makeInMemoryContainer()
    let writer = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: SymmetricKey(size: .bits256))
    )
    let reader = EncryptedMemoryStore(
      container: container,
      keyManager: KeyManager(staticKey: SymmetricKey(size: .bits256))
    )
    return (writer, reader)
  }

  @Test("Wrong key yields zero decryptable events")
  func wrongKeyEmpty() async throws {
    let (writer, reader) = try makePair()
    await writer.append(SpatialEvent.touchFixture())

    let events = await reader.allEvents()
    #expect(events.isEmpty)
  }

  @Test("Ciphertext is not decodable as plaintext JSON")
  func ciphertextNotJSON() async throws {
    let store = try makeTestEncryptedStore()
    let event = SpatialEvent.touchFixture()
    await store.append(event)

    let ct = await store.rawCiphertext(for: event.id)
    #expect(ct != nil)
    if let data = ct {
      let decoded = try? JSONDecoder().decode(SpatialEvent.self, from: data)
      #expect(decoded == nil, "Raw ciphertext must NOT decode as JSON")
    }
  }

  @Test("Metadata count works regardless of key")
  func countIgnoresKey() async throws {
    let (writer, reader) = try makePair()
    await writer.append(SpatialEvent.touchFixture())
    await writer.append(SpatialEvent.gazeFixture())

    let count = await reader.count
    #expect(count == 2)
  }

  @Test("Wrong key with recallAndFetchAll yields zero events")
  func wrongKeyRecallEmpty() async throws {
    let (writer, reader) = try makePair()
    await writer.append(SpatialEvent.touchFixture())

    let events = await reader.recallAndFetchAll()
    #expect(events.isEmpty)
  }
}
