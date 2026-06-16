// RingBufferPropertyTests.swift
// AuraKitTests — Property-Based Invariant Verification
//
// Validates RingBuffer structural invariants across randomised inputs.
// These tests complement the deterministic unit tests in RingBufferTests.swift
// by exercising a wide range of capacity/count combinations, catching
// edge-case regressions that hand-crafted tests may miss.

import Foundation
import Testing

@testable import AuraKit

// MARK: - RingBuffer Property Tests

@Suite("RingBuffer — Property-Based Invariants")
struct RingBufferPropertyTests {

  // MARK: - Helpers

  /// Generates a random capacity in a practical range.
  private static func randomCapacity() -> Int {
    Int.random(in: 1...1_024)
  }

  /// Generates a random event count for stress inputs.
  private static func randomEventCount(max: Int = 5_000) -> Int {
    Int.random(in: 0...max)
  }

  /// Creates a SpatialEvent with a unique score for ordering verification.
  private static func event(index: Int) -> SpatialEvent {
    SpatialEvent(
      kind: .gaze(position: CodableSIMD3(x: Float(index), y: 0, z: 0)),
      score: Double(index) * 0.001
    )
  }

  // MARK: - Count Invariant: 0 ≤ count ≤ capacity

  @Test("Count invariant holds across 100 random capacity/event combinations")
  func countInvariantRandomised() {
    for _ in 0..<100 {
      let capacity = Self.randomCapacity()
      let eventCount = Self.randomEventCount()
      var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

      for idx in 0..<eventCount {
        buffer.enqueue(Self.event(index: idx))

        // Invariant: count must always be in [0, capacity]
        #expect(buffer.count >= 0, "Count must be non-negative")
        #expect(buffer.count <= capacity, "Count must not exceed capacity")
      }

      // Final count: min(eventCount, capacity)
      let expectedCount = min(eventCount, capacity)
      #expect(buffer.count == expectedCount)
    }
  }

  // MARK: - Drain-Empty Invariant

  @Test("drainAll() always leaves buffer empty regardless of prior state")
  func drainEmptyInvariant() {
    for _ in 0..<50 {
      let capacity = Self.randomCapacity()
      let eventCount = Self.randomEventCount(max: 3_000)
      var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

      for idx in 0..<eventCount {
        buffer.enqueue(Self.event(index: idx))
      }

      let drained = buffer.drainAll()

      // Post-drain invariants
      #expect(buffer.count == 0, "Count must be 0 after drainAll()")
      #expect(buffer.isEmpty, "isEmpty must be true after drainAll()")

      // Drained element count must equal pre-drain count
      let expectedDrainCount = min(eventCount, capacity)
      #expect(drained.count == expectedDrainCount)
    }
  }

  // MARK: - FIFO Order Invariant

  @Test("Elements are always yielded in FIFO order after overflow")
  func fifoOrderInvariant() {
    for _ in 0..<50 {
      let capacity = Int.random(in: 2...256)
      let eventCount = Int.random(in: capacity...(capacity * 4))
      var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

      for idx in 0..<eventCount {
        buffer.enqueue(Self.event(index: idx))
      }

      let drained = buffer.drainAll()

      // After overflow, the oldest surviving element should be at index
      // (eventCount - capacity), and elements should be in ascending order.
      let expectedFirstIndex = eventCount - capacity

      for (offset, event) in drained.enumerated() {
        let expectedScore = Double(expectedFirstIndex + offset) * 0.001
        #expect(
          event.score == expectedScore,
          "Element at offset \(offset) has wrong score: expected \(expectedScore), got \(event.score)"
        )
      }
    }
  }

  // MARK: - Overflow Idempotence

  @Test("Count remains at capacity under sustained overflow")
  func overflowIdempotence() {
    let capacity = Int.random(in: 16...512)
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

    // Fill to capacity
    for idx in 0..<capacity {
      buffer.enqueue(Self.event(index: idx))
    }
    #expect(buffer.count == capacity)

    // Continue adding — count must stay at capacity
    for idx in capacity..<(capacity * 3) {
      buffer.enqueue(Self.event(index: idx))
      #expect(
        buffer.count == capacity,
        "Count must remain at capacity during overflow"
      )
    }
  }

  // MARK: - Enqueue-Dequeue Round-Trip

  @Test("Single element enqueue → dequeue preserves identity")
  func singleElementRoundTrip() {
    for _ in 0..<100 {
      let capacity = Self.randomCapacity()
      var buffer = RingBuffer<SpatialEvent>(capacity: capacity)
      let original = Self.event(index: Int.random(in: 0...10_000))

      buffer.enqueue(original)
      let drained = buffer.drainAll()

      #expect(drained.count == 1)
      #expect(drained.first?.id == original.id, "Round-trip must preserve event identity")
      #expect(drained.first?.score == original.score, "Round-trip must preserve event score")
    }
  }

  // MARK: - Empty Buffer Safety

  @Test("Operations on empty buffer are safe")
  func emptyBufferSafety() {
    for _ in 0..<50 {
      let capacity = Self.randomCapacity()
      var buffer = RingBuffer<SpatialEvent>(capacity: capacity)

      // Draining an empty buffer should return empty array
      #expect(buffer.isEmpty)
      #expect(buffer.count == 0)
      let drained = buffer.drainAll()
      #expect(drained.isEmpty)

      // Double drain should also be safe
      let doubleDrained = buffer.drainAll()
      #expect(doubleDrained.isEmpty)
    }
  }

  // MARK: - Batch Enqueue Consistency

  @Test("batchEnqueue produces same result as sequential enqueue")
  func batchEnqueueConsistency() {
    for _ in 0..<50 {
      let capacity = Int.random(in: 4...256)
      let eventCount = Int.random(in: 1...(capacity * 3))

      let events = (0..<eventCount).map { Self.event(index: $0) }

      // Sequential enqueue
      var sequentialBuffer = RingBuffer<SpatialEvent>(capacity: capacity)
      for event in events {
        sequentialBuffer.enqueue(event)
      }

      // Batch enqueue
      var batchBuffer = RingBuffer<SpatialEvent>(capacity: capacity)
      batchBuffer.batchEnqueue(events)

      // Results must be identical
      let sequentialDrained = sequentialBuffer.drainAll()
      let batchDrained = batchBuffer.drainAll()

      #expect(sequentialDrained.count == batchDrained.count)
      for idx in 0..<sequentialDrained.count {
        #expect(
          sequentialDrained[idx].id == batchDrained[idx].id,
          "Sequential and batch enqueue must produce identical ordering"
        )
      }
    }
  }
}
