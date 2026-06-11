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
  func testEnqueueDequeueFIFO() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 8)
    let events = (0..<5).map { _ in SpatialEvent.gazeFixture() }

    for event in events {
      buffer.enqueue(event)
    }

    for expected in events {
      let actual = buffer.dequeue()
      #expect(actual?.id == expected.id)
    }

    let afterDrain = buffer.dequeue()
    #expect(afterDrain == nil)
  }

  @Test("Empty buffer returns nil on dequeue")
  func testEmptyDequeue() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 4)
    let result = buffer.dequeue()
    #expect(result == nil)
  }

  @Test("Count reflects enqueued items accurately")
  func testCountAccuracy() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 16)
    #expect(buffer.count == 0)

    buffer.enqueue(.gazeFixture())
    buffer.enqueue(.gazeFixture())
    #expect(buffer.count == 2)

    _ = buffer.dequeue()
    #expect(buffer.count == 1)
  }

  // MARK: - Capacity & Overflow

  @Test("Buffer wraps around without crashing at capacity")
  func testWrapAroundAtCapacity() {
    let capacity = 4
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    // Fill exactly to capacity
    let firstBatch = (0..<capacity).map { _ in SpatialEvent.gazeFixture() }
    for event in firstBatch { buffer.enqueue(event) }
    #expect(buffer.count == capacity)
    #expect(buffer.isFull)

    // Overflow — oldest should be evicted
    let overflow = SpatialEvent.gazeFixture()
    buffer.enqueue(overflow)
    #expect(buffer.count == capacity)  // Count stays at capacity

    // The oldest element (firstBatch[0]) should have been evicted;
    // firstBatch[1] should now be the head.
    let head = buffer.dequeue()
    #expect(head?.id == firstBatch[1].id)
  }

  @Test("peek() returns correct FIFO order after overflow")
  func testPeekAfterOverflow() {
    let capacity = 3
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    // Fill to capacity
    let initial = (0..<capacity).map { _ in SpatialEvent.gazeFixture() }
    for event in initial { buffer.enqueue(event) }

    // Add two more elements, evicting initial[0] and initial[1]
    let extra1 = SpatialEvent.gazeFixture()
    let extra2 = SpatialEvent.gazeFixture()
    buffer.enqueue(extra1)
    buffer.enqueue(extra2)

    // Expected FIFO order: initial[2], extra1, extra2
    let peeked = buffer.peek()
    #expect(peeked.count == capacity)
    #expect(peeked[0].id == initial[2].id)
    #expect(peeked[1].id == extra1.id)
    #expect(peeked[2].id == extra2.id)

    // Must be non-destructive
    #expect(buffer.count == capacity)
  }

  @Test("No memory growth: 10,000 enqueue/dequeue cycles")
  func testNoMemoryGrowthOver10kCycles() {
    // This test validates the memory contract: the backing array must
    // not grow beyond its initial allocation across many cycles.
    // Swift Testing doesn't have direct heap introspection, but we can
    // verify the count invariant which exercises the full wrap-around path.
    let capacity = 64
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    for _ in 0..<10_000 {
      buffer.enqueue(.gazeFixture())
      _ = buffer.dequeue()
    }

    // After 10k cycles, count must be 0 and the buffer must be in clean state.
    #expect(buffer.count == 0)
    #expect(buffer.isEmpty)
  }

  @Test("Overflow across 10,000 frames keeps count at capacity")
  func testOverflowCountInvariant() {
    let capacity = 512
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    for _ in 0..<10_000 {
      buffer.enqueue(.gazeFixture())
    }

    // Count must never exceed capacity regardless of how many enqueues occurred
    let count = buffer.count
    #expect(count == capacity)
  }

  // MARK: - drainAll

  @Test("drainAll returns all elements in FIFO order and clears buffer")
  func testDrainAll() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 16)
    let events = (0..<6).map { _ in SpatialEvent.gazeFixture() }
    for event in events { buffer.enqueue(event) }

    let drained = buffer.drainAll()
    #expect(drained.count == 6)
    #expect(buffer.isEmpty)

    // Verify FIFO order by ID sequence
    for (original, drained) in zip(events, drained) {
      #expect(original.id == drained.id)
    }
  }

  @Test("drainAll on empty buffer returns empty array")
  func testDrainAllEmpty() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 8)
    let result = buffer.drainAll()
    #expect(result.isEmpty)
  }

  // MARK: - peek

  @Test("peek is non-destructive")
  func testPeekNonDestructive() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 8)
    let events = (0..<3).map { _ in SpatialEvent.gazeFixture() }
    for event in events { buffer.enqueue(event) }

    let peeked = buffer.peek()
    #expect(peeked.count == 3)
    #expect(buffer.count == 3)  // Must not have been drained
  }

  // MARK: - Defensive Edge Cases

  @Test("capacity 0 is coerced to 1 — enqueue and dequeue still work")
  func testCapacityZeroCoercion() {
    // RingBuffer coerces capacity 0 → 1 to prevent division-by-zero.
    var buffer = RingBuffer<SpatialEvent>(capacity: 0)
    #expect(buffer.capacity == 1)

    let event = SpatialEvent.gazeFixture()
    buffer.enqueue(event)
    #expect(buffer.count == 1)
    #expect(buffer.isFull)

    let dequeued = buffer.dequeue()
    #expect(dequeued?.id == event.id)
    #expect(buffer.isEmpty)
  }

  @Test("Negative capacity is coerced to 1")
  func testNegativeCapacityCoercion() {
    let buffer = RingBuffer<SpatialEvent>(capacity: -10)
    #expect(buffer.capacity == 1)
  }
}
