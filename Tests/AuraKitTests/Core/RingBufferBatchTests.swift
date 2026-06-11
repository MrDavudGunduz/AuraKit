// RingBufferBatchTests.swift
// AuraKitTests — Core Infrastructure
//
// Unit tests for RingBuffer's batchEnqueue() method.
// Validates batch enqueue functionality, overflow counting, empty array
// handling, and consistency with sequential enqueue behaviour.

import Foundation
import Testing

@testable import AuraKit

// MARK: - RingBuffer Batch Enqueue Tests

@Suite("Core — RingBuffer Batch Enqueue")
struct RingBufferBatchTests {

  @Test("batchEnqueue enqueues all elements within capacity")
  func batchEnqueueWithinCapacity() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 10)
    let events = (0..<5).map { idx in
      SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: 0.3
      )
    }

    let overflows = buffer.batchEnqueue(events)

    #expect(overflows == 0, "No overflows expected when within capacity")
    #expect(buffer.count == 5)
    #expect(buffer.isFull == false)
  }

  @Test("batchEnqueue returns correct overflow count")
  func batchEnqueueOverflowCount() {
    let capacity = 4
    var buffer = RingBuffer<SpatialEvent>(capacity: capacity)
    let events = (0..<10).map { idx in
      SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: 0.3
      )
    }

    let overflows = buffer.batchEnqueue(events)

    // 10 elements into capacity 4 → 6 overflows
    #expect(overflows == 6, "Expected 6 overflows, got \(overflows)")
    #expect(buffer.count == capacity)
    #expect(buffer.isFull)

    // Verify the most recent 4 events survive
    let drained = buffer.drainAll()
    #expect(drained.count == capacity)

    // First surviving event should be index 6 (events 0-5 were evicted)
    if case .gaze(let position) = drained.first?.kind {
      #expect(position.x == 6.0, "Oldest surviving event should be index 6")
    }
  }

  @Test("batchEnqueue with empty array is a no-op")
  func batchEnqueueEmptyArray() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 10)

    // Pre-fill one event
    let event = SpatialEvent(kind: .gaze(position: .zero), score: 0.3)
    buffer.enqueue(event)

    let overflows = buffer.batchEnqueue([])

    #expect(overflows == 0)
    #expect(buffer.count == 1, "Count should be unchanged after empty batch")
  }

  @Test("batchEnqueue is consistent with sequential enqueue")
  func batchEnqueueConsistencyWithSequential() {
    let capacity = 8
    let events = (0..<12).map { idx in
      SpatialEvent(
        kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
        score: Double(idx) * 0.1
      )
    }

    // Sequential path
    var seqBuffer = RingBuffer<SpatialEvent>(capacity: capacity)
    for event in events {
      seqBuffer.enqueue(event)
    }
    let seqResult = seqBuffer.drainAll()

    // Batch path
    var batchBuffer = RingBuffer<SpatialEvent>(capacity: capacity)
    batchBuffer.batchEnqueue(events)
    let batchResult = batchBuffer.drainAll()

    // Both should produce identical results
    #expect(seqResult.count == batchResult.count)
    for idx in 0..<seqResult.count {
      #expect(seqResult[idx].id == batchResult[idx].id, "Event at index \(idx) should match")
    }
  }

  @Test("batchEnqueue exactly fills buffer without overflow")
  func batchEnqueueExactCapacity() {
    var buffer = RingBuffer<SpatialEvent>(capacity: 5)
    let events = (0..<5).map { _ in
      SpatialEvent(kind: .gaze(position: .zero), score: 0.3)
    }

    let overflows = buffer.batchEnqueue(events)

    #expect(overflows == 0)
    #expect(buffer.count == 5)
    #expect(buffer.isFull)
  }
}
