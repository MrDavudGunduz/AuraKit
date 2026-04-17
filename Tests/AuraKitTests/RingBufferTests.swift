// RingBufferTests.swift
// AuraKitTests — Phase 1: Core Infrastructure Tests

import Foundation
import Testing

@testable import AuraKit

// MARK: - RingBufferTests

@Suite("RingBuffer")
struct RingBufferTests {

  // MARK: - Basic FIFO Semantics

  @Test("Enqueue and dequeue preserves FIFO order")
  func testEnqueueDequeueFIFO() async {
    let buffer = RingBuffer<SpatialEvent>(capacity: 8)
    let events = (0..<5).map { _ in SpatialEvent.gazeFixture() }

    for event in events {
      await buffer.enqueue(event)
    }

    for expected in events {
      let actual = await buffer.dequeue()
      #expect(actual?.id == expected.id)
    }

    let afterDrain = await buffer.dequeue()
    #expect(afterDrain == nil)
  }

  @Test("Empty buffer returns nil on dequeue")
  func testEmptyDequeue() async {
    let buffer = RingBuffer<SpatialEvent>(capacity: 4)
    let result = await buffer.dequeue()
    #expect(result == nil)
  }

  @Test("Count reflects enqueued items accurately")
  func testCountAccuracy() async {
    let buffer = RingBuffer<SpatialEvent>(capacity: 16)
    #expect(await buffer.count == 0)

    await buffer.enqueue(.gazeFixture())
    await buffer.enqueue(.gazeFixture())
    #expect(await buffer.count == 2)

    _ = await buffer.dequeue()
    #expect(await buffer.count == 1)
  }

  // MARK: - Capacity & Overflow

  @Test("Buffer wraps around without crashing at capacity")
  func testWrapAroundAtCapacity() async {
    let capacity = 4
    let buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    // Fill exactly to capacity
    let firstBatch = (0..<capacity).map { _ in SpatialEvent.gazeFixture() }
    for event in firstBatch { await buffer.enqueue(event) }
    #expect(await buffer.count == capacity)
    #expect(await buffer.isFull)

    // Overflow — oldest should be evicted
    let overflow = SpatialEvent.gazeFixture()
    await buffer.enqueue(overflow)
    #expect(await buffer.count == capacity)  // Count stays at capacity

    // The oldest element (firstBatch[0]) should have been evicted;
    // firstBatch[1] should now be the head.
    let head = await buffer.dequeue()
    #expect(head?.id == firstBatch[1].id)
  }

  @Test("peek() returns correct FIFO order after overflow")
  func testPeekAfterOverflow() async {
    let capacity = 3
    let buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    // Fill to capacity
    let initial = (0..<capacity).map { _ in SpatialEvent.gazeFixture() }
    for event in initial { await buffer.enqueue(event) }

    // Add two more elements, evicting initial[0] and initial[1]
    let extra1 = SpatialEvent.gazeFixture()
    let extra2 = SpatialEvent.gazeFixture()
    await buffer.enqueue(extra1)
    await buffer.enqueue(extra2)

    // Expected FIFO order: initial[2], extra1, extra2
    let peeked = await buffer.peek()
    #expect(peeked.count == capacity)
    #expect(peeked[0].id == initial[2].id)
    #expect(peeked[1].id == extra1.id)
    #expect(peeked[2].id == extra2.id)

    // Must be non-destructive
    #expect(await buffer.count == capacity)
  }

  @Test("No memory growth: 10,000 enqueue/dequeue cycles")
  func testNoMemoryGrowthOver10kCycles() async {
    // This test validates the memory contract: the backing array must
    // not grow beyond its initial allocation across many cycles.
    // Swift Testing doesn't have direct heap introspection, but we can
    // verify the count invariant which exercises the full wrap-around path.
    let capacity = 64
    let buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    for _ in 0..<10_000 {
      await buffer.enqueue(.gazeFixture())
      _ = await buffer.dequeue()
    }

    // After 10k cycles, count must be 0 and the buffer must be in clean state.
    #expect(await buffer.count == 0)
    #expect(await buffer.isEmpty)
  }

  @Test("Overflow across 10,000 frames keeps count at capacity")
  func testOverflowCountInvariant() async {
    let capacity = 512
    let buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    for _ in 0..<10_000 {
      await buffer.enqueue(.gazeFixture())
    }

    // Count must never exceed capacity regardless of how many enqueues occurred
    let count = await buffer.count
    #expect(count == capacity)
  }

  // MARK: - drainAll

  @Test("drainAll returns all elements in FIFO order and clears buffer")
  func testDrainAll() async {
    let buffer = RingBuffer<SpatialEvent>(capacity: 16)
    let events = (0..<6).map { _ in SpatialEvent.gazeFixture() }
    for event in events { await buffer.enqueue(event) }

    let drained = await buffer.drainAll()
    #expect(drained.count == 6)
    #expect(await buffer.isEmpty)

    // Verify FIFO order by ID sequence
    for (original, drained) in zip(events, drained) {
      #expect(original.id == drained.id)
    }
  }

  @Test("drainAll on empty buffer returns empty array")
  func testDrainAllEmpty() async {
    let buffer = RingBuffer<SpatialEvent>(capacity: 8)
    let result = await buffer.drainAll()
    #expect(result.isEmpty)
  }

  // MARK: - peek

  @Test("peek is non-destructive")
  func testPeekNonDestructive() async {
    let buffer = RingBuffer<SpatialEvent>(capacity: 8)
    let events = (0..<3).map { _ in SpatialEvent.gazeFixture() }
    for event in events { await buffer.enqueue(event) }

    let peeked = await buffer.peek()
    #expect(peeked.count == 3)
    #expect(await buffer.count == 3)  // Must not have been drained
  }
}
