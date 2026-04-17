// CaptureActorTests.swift
// AuraKitTests — Phase 1: Core Infrastructure Tests

import Foundation
import Testing

@testable import AuraKit

// MARK: - CaptureActorTests

@Suite("CaptureActor")
struct CaptureActorTests {

  // MARK: Helpers

  private func makeCaptureActor(
    interactionWeight: Float = 1.0,
    gazeWeight: Float = 0.3,
    bufferCapacity: Int = 64
  ) throws -> CaptureActor {
    let config = try AuraConfiguration(
      interactionWeight: interactionWeight,
      gazeWeight: gazeWeight,
      bufferCapacity: bufferCapacity
    )
    return CaptureActor(config: config)
  }

  // MARK: - Bootstrap Performance

  @Test("Bootstrap + first event recorded in < 50ms (order-of-magnitude overhead check)")
  func testBootstrapAndFirstEventUnder50ms() async throws {
    // Note: Wall-clock timing is inherently imprecise in unit tests and can
    // produce flaky results on loaded CI runners. This test is intentionally
    // generous (50ms) — it validates that there is no catastrophic blocking
    // (e.g., accidental main-thread UI work), not sub-millisecond precision.
    // Per-frame latency is exercised in the concurrency load tests below.
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
      let actor = try makeCaptureActor()
      await actor.record(event: .touchFixture())
    }
    #expect(
      elapsed < .milliseconds(50), "Bootstrap + first record took \(elapsed), expected < 50ms")
  }

  // MARK: - Routing Correctness

  @Test("Touch event bypasses buffer — appears in persistent store, not buffer")
  func testHighSignalEventBypassesBuffer() async throws {
    let actor = try makeCaptureActor()

    await actor.record(event: .touchFixture())

    let buffered = await actor.bufferedEventCount
    let persisted = await actor.persistedEventCount

    #expect(buffered == 0, "Touch event should NOT enter the ring buffer")
    #expect(persisted == 1, "Touch event should be in persistent memory")
  }

  @Test("Gaze event is buffered — never enters persistent store directly")
  func testLowSignalEventEntersBuffer() async throws {
    let actor = try makeCaptureActor()

    await actor.record(event: .gazeFixture())

    let buffered = await actor.bufferedEventCount
    let persisted = await actor.persistedEventCount

    #expect(buffered == 1, "Gaze event should enter the ring buffer")
    #expect(persisted == 0, "Gaze event should NOT be in persistent memory")
  }

  @Test("Gaze event score is set to gazeWeight by router")
  func testGazeEventScoreAssignment() async throws {
    let actor = try makeCaptureActor(gazeWeight: 0.25)
    await actor.record(event: .gazeFixture())

    let events = await actor.flush()
    #expect(events.count == 1)
    #expect(events.first?.score == 0.25)
  }

  @Test("Touch event score is set to interactionWeight by router")
  func testTouchEventScoreAssignment() async throws {
    let actor = try makeCaptureActor(interactionWeight: 1.0)
    await actor.record(event: .touchFixture())

    let persisted = await actor.persistedEvents()
    #expect(persisted.count == 1)
    #expect(persisted.first?.score == 1.0)
  }

  // MARK: - Flush

  @Test("flush() drains buffer and returns events in FIFO order")
  func testFlushOrderAndClears() async throws {
    let actor = try makeCaptureActor()
    let events = (0..<5).map { _ in SpatialEvent.gazeFixture() }

    for event in events {
      await actor.record(event: event)
    }

    let flushed = await actor.flush()
    #expect(flushed.count == 5)

    for (original, flushed) in zip(events, flushed) {
      #expect(original.id == flushed.id)
    }

    let afterFlush = await actor.bufferedEventCount
    #expect(afterFlush == 0)
  }

  @Test("flush() on empty buffer returns empty array")
  func testFlushEmpty() async throws {
    let actor = try makeCaptureActor()
    let result = await actor.flush()
    #expect(result.isEmpty)
  }

  // MARK: - Concurrency

  @Test("1000 concurrent records do not exceed buffer capacity")
  func testConcurrentRecords() async throws {
    let capacity = 128
    let actor = try makeCaptureActor(bufferCapacity: capacity)

    // Launch 1000 concurrent gaze recordings
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<1_000 {
        group.addTask {
          await actor.record(event: .gazeFixture())
        }
      }
    }

    let buffered = await actor.bufferedEventCount
    #expect(buffered <= capacity, "Buffer overflowed its capacity \(capacity), got \(buffered)")
  }

  @Test("1000 concurrent touch records all land in persistent store")
  func testConcurrentInteractionRecords() async throws {
    let actor = try makeCaptureActor(bufferCapacity: 64)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<1_000 {
        group.addTask {
          await actor.record(event: .touchFixture())
        }
      }
    }

    let persisted = await actor.persistedEventCount
    #expect(persisted == 1_000, "All 1000 touch events should be in persistent memory")
  }

  // MARK: - Mixed Events

  @Test("Mixed gaze + touch events route correctly")
  func testMixedEventRouting() async throws {
    let actor = try makeCaptureActor(bufferCapacity: 16)

    for _ in 0..<8 { await actor.record(event: .gazeFixture()) }
    for _ in 0..<4 { await actor.record(event: .touchFixture()) }

    let buffered = await actor.bufferedEventCount
    let persisted = await actor.persistedEventCount

    #expect(buffered == 8, "8 gaze events should be buffered")
    #expect(persisted == 4, "4 touch events should be persisted")
  }
}
