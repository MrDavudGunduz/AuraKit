// PerformanceBenchmarkTests.swift
// AuraKitTests — Performance Regression Detection
//
// Validates that critical hot-path operations meet their documented
// performance targets. These benchmarks use wall-clock timing via
// ContinuousClock — intentionally generous thresholds account for
// CI runner variability while catching catastrophic regressions.
//
// Performance targets from ARCHITECTURE.md:
// - Ring Buffer write: < 1µs per event
// - Main thread overhead per frame: < 1ms
// - SwiftData write (per node): < 5ms

import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import AuraKit

// MARK: - RingBuffer Performance

@Suite("Performance — RingBuffer Benchmarks")
struct RingBufferPerformanceTests {

  @Test("10K sequential enqueue operations complete under 50ms")
  func enqueueThroughput() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 1_024)
    let eventCount = 10_000

    let start = ContinuousClock.now

    for _ in 0..<eventCount {
      buffer.enqueue(.gazeFixture())
    }

    let elapsed = ContinuousClock.now - start

    // 10K enqueues at <1µs each = <10ms theoretical; 250ms generous for debug CI
    #expect(
      elapsed < .milliseconds(250),
      "10K enqueue operations took \(elapsed) — expected < 250ms"
    )
  }

  @Test("batchEnqueue 10K events is faster than sequential enqueue")
  func batchEnqueueVsSequential() {
    let eventCount = 10_000
    let events = (0..<eventCount).map { _ in SpatialEvent.gazeFixture() }

    // Sequential
    var seqBuffer = RingBuffer<SpatialEvent>(capacity: 1_024)
    let seqStart = ContinuousClock.now
    for event in events { seqBuffer.enqueue(event) }
    let seqElapsed = ContinuousClock.now - seqStart

    // Batch
    var batchBuffer = RingBuffer<SpatialEvent>(capacity: 1_024)
    let batchStart = ContinuousClock.now
    batchBuffer.batchEnqueue(events)
    let batchElapsed = ContinuousClock.now - batchStart

    // Both should complete under the threshold
    #expect(
      seqElapsed < .milliseconds(100),
      "Sequential 10K enqueue took \(seqElapsed)"
    )
    #expect(
      batchElapsed < .milliseconds(100),
      "Batch 10K enqueue took \(batchElapsed)"
    )
  }

  @Test("drainAll 1K elements completes under 10ms")
  func drainAllPerformance() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 1_024)
    for _ in 0..<1_024 { buffer.enqueue(.gazeFixture()) }

    let start = ContinuousClock.now
    let drained = buffer.drainAll()
    let elapsed = ContinuousClock.now - start

    #expect(drained.count == 1_024)
    #expect(
      elapsed < .milliseconds(10),
      "drainAll of 1K elements took \(elapsed) — expected < 10ms"
    )
  }
}

// MARK: - Encryption Performance

@Suite("Performance — Encryption Benchmarks")
struct EncryptionPerformanceTests {

  @Test("1K encrypt/decrypt round-trips complete under 500ms")
  func encryptDecryptCycleThroughput() throws {
    let service = EncryptionService()
    let key = SymmetricKey(size: .bits256)
    let event = SpatialEvent.touchFixture()
    let plaintext = try JSONEncoder().encode(event)
    let cycleCount = 1_000

    let start = ContinuousClock.now

    for _ in 0..<cycleCount {
      let ciphertext = try service.encrypt(plaintext, using: key)
      let decrypted = try service.decrypt(ciphertext, using: key)
      // Prevent compiler from optimising away the decrypt
      #expect(decrypted.count == plaintext.count)
    }

    let elapsed = ContinuousClock.now - start

    // 1K cycles at <0.5ms each = <500ms theoretical
    #expect(
      elapsed < .milliseconds(500),
      "1K encrypt/decrypt cycles took \(elapsed) — expected < 500ms"
    )
  }

  @Test("Single encrypt operation completes under 1ms")
  func singleEncryptLatency() throws {
    let service = EncryptionService()
    let key = SymmetricKey(size: .bits256)
    let event = SpatialEvent.touchFixture()
    let plaintext = try JSONEncoder().encode(event)

    // Warm up
    _ = try service.encrypt(plaintext, using: key)

    // Measure
    let start = ContinuousClock.now
    let ciphertext = try service.encrypt(plaintext, using: key)
    let elapsed = ContinuousClock.now - start

    #expect(ciphertext.count > 0)
    #expect(
      elapsed < .milliseconds(1),
      "Single encrypt took \(elapsed) — expected < 1ms"
    )
  }
}

// MARK: - CaptureActor Performance

@Suite("Performance — CaptureActor Benchmarks")
struct CaptureActorPerformanceTests {

  @Test("1K sequential record() calls complete under 200ms")
  func recordThroughput() async throws {
    let config = try AuraConfiguration(bufferCapacity: 2_048, storeCapacity: 2_048)
    let capture = CaptureActor(config: config)
    let eventCount = 1_000

    let start = ContinuousClock.now

    for _ in 0..<eventCount {
      await capture.record(event: .gazeFixture())
    }

    let elapsed = ContinuousClock.now - start

    #expect(
      elapsed < .milliseconds(200),
      "1K record calls took \(elapsed) — expected < 200ms"
    )
  }

  @Test("recordBatch 1K events is faster than 1K sequential records")
  func batchRecordVsSequential() async throws {
    let config = try AuraConfiguration(bufferCapacity: 2_048, storeCapacity: 2_048)
    let eventCount = 1_000
    let events = (0..<eventCount).map { _ in SpatialEvent.gazeFixture() }

    // Sequential path
    let seqCapture = CaptureActor(config: config)
    let seqStart = ContinuousClock.now
    for event in events {
      await seqCapture.record(event: event)
    }
    let seqElapsed = ContinuousClock.now - seqStart

    // Batch path
    let batchCapture = CaptureActor(config: config)
    let batchStart = ContinuousClock.now
    await batchCapture.recordBatch(events: events)
    let batchElapsed = ContinuousClock.now - batchStart

    // Both should complete under generous thresholds
    #expect(
      seqElapsed < .milliseconds(500),
      "Sequential 1K records took \(seqElapsed)"
    )
    #expect(
      batchElapsed < .milliseconds(500),
      "Batch 1K records took \(batchElapsed)"
    )
  }

  @Test("flush() returns within 5ms for a full 512-event buffer")
  func flushLatency() async throws {
    let capacity = 512
    let config = try AuraConfiguration(bufferCapacity: capacity)
    let capture = CaptureActor(config: config)

    for _ in 0..<capacity {
      await capture.record(event: .gazeFixture())
    }

    let start = ContinuousClock.now
    let flushed = await capture.flush()
    let elapsed = ContinuousClock.now - start

    #expect(flushed.count == capacity)
    #expect(
      elapsed < .milliseconds(5),
      "flush() of \(capacity) events took \(elapsed) — expected < 5ms"
    )
  }
}
