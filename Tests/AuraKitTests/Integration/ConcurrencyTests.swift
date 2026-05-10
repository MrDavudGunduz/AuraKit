// ConcurrencyTests.swift
// AuraKitTests — Multi-Task Concurrent Access
//
// Validates that AuraKit's actor-isolated pipeline correctly serialises
// concurrent writes from multiple tasks without data races, lost events,
// or invariant violations.

import Foundation
import Testing

@testable import AuraKit

// MARK: - CaptureActor Concurrency

@Suite("Concurrency — CaptureActor Multi-Task")
struct CaptureActorConcurrencyTests {

  @Test("Concurrent record() calls from 10 tasks produce correct event count")
  func concurrentRecordFrom10Tasks() async throws {
    let config = try AuraConfiguration(bufferCapacity: 2_048, storeCapacity: 10_000)
    let capture = CaptureActor(config: config)

    let tasksCount = 10
    let eventsPerTask = 100

    await withTaskGroup(of: Void.self) { group in
      for taskIdx in 0..<tasksCount {
        group.addTask {
          for eventIdx in 0..<eventsPerTask {
            let event = SpatialEvent(
              kind: .interaction(
                type: .touch,
                position: CodableSIMD3(
                  x: Float(taskIdx),
                  y: Float(eventIdx),
                  z: 0
                )
              ),
              score: 0
            )
            await capture.record(event: event)
          }
        }
      }
    }

    // All interaction events should be in the persistent store
    let persistedCount = await capture.persistedEventCount
    #expect(
      persistedCount == tasksCount * eventsPerTask,
      "Expected \(tasksCount * eventsPerTask) persisted events, got \(persistedCount)"
    )
  }

  @Test("Concurrent gaze events from 10 tasks serialise through RingBuffer")
  func concurrentGazeEventsSerialise() async throws {
    let bufferCapacity = 2_048
    let config = try AuraConfiguration(bufferCapacity: bufferCapacity, storeCapacity: 10_000)
    let capture = CaptureActor(config: config)

    let tasksCount = 10
    let eventsPerTask = 100

    await withTaskGroup(of: Void.self) { group in
      for taskIdx in 0..<tasksCount {
        group.addTask {
          for eventIdx in 0..<eventsPerTask {
            let event = SpatialEvent(
              kind: .gaze(
                position: CodableSIMD3(
                  x: Float(taskIdx),
                  y: Float(eventIdx),
                  z: 0
                )
              ),
              score: 0
            )
            await capture.record(event: event)
          }
        }
      }
    }

    // All gaze events should be in the buffer (total < capacity)
    let bufferedCount = await capture.bufferedEventCount
    let totalSent = tasksCount * eventsPerTask
    #expect(
      bufferedCount == totalSent,
      "Expected \(totalSent) buffered gaze events, got \(bufferedCount)"
    )
  }

  @Test("Concurrent mixed events maintain routing invariant")
  func concurrentMixedEventsRouting() async throws {
    let config = try AuraConfiguration(bufferCapacity: 2_048, storeCapacity: 10_000)
    let capture = CaptureActor(config: config)

    let tasksCount = 8
    let eventsPerTask = 50

    await withTaskGroup(of: Void.self) { group in
      for taskIdx in 0..<tasksCount {
        group.addTask {
          for eventIdx in 0..<eventsPerTask {
            // Alternate between gaze and interaction events
            let isGaze = eventIdx % 2 == 0
            let event: SpatialEvent
            if isGaze {
              event = SpatialEvent(
                kind: .gaze(position: CodableSIMD3(x: Float(taskIdx), y: Float(eventIdx), z: 0)),
                score: 0
              )
            } else {
              event = SpatialEvent(
                kind: .interaction(
                  type: .touch,
                  position: CodableSIMD3(x: Float(taskIdx), y: Float(eventIdx), z: 0)
                ),
                score: 0
              )
            }
            await capture.record(event: event)
          }
        }
      }
    }

    let buffered = await capture.bufferedEventCount
    let persisted = await capture.persistedEventCount
    let total = buffered + persisted

    #expect(
      total == tasksCount * eventsPerTask,
      "Total events (\(total)) should equal sent events (\(tasksCount * eventsPerTask))"
    )

    // Half should be gaze (buffered), half should be interaction (persisted)
    let expectedPerKind = (tasksCount * eventsPerTask) / 2
    #expect(buffered == expectedPerKind, "Gaze events should go to buffer")
    #expect(persisted == expectedPerKind, "Interaction events should go to store")
  }

  @Test("Concurrent flush() and record() do not lose events")
  func concurrentFlushAndRecord() async throws {
    let config = try AuraConfiguration(bufferCapacity: 1_024, storeCapacity: 10_000)
    let capture = CaptureActor(config: config)

    // Writer task: sends 200 gaze events
    let writerTask = Task {
      for idx in 0..<200 {
        let event = SpatialEvent(
          kind: .gaze(position: CodableSIMD3(x: Float(idx), y: 0, z: 0)),
          score: 0
        )
        await capture.record(event: event)
      }
    }

    // Flusher task: periodically flushes the buffer
    var totalFlushed = 0
    let flusherTask = Task {
      var flushed = 0
      for _ in 0..<10 {
        let batch = await capture.flush()
        flushed += batch.count
        try? await Task.sleep(for: .milliseconds(1))
      }
      return flushed
    }

    await writerTask.value
    totalFlushed = await flusherTask.value

    // Final flush to collect remaining events
    let remaining = await capture.flush()
    totalFlushed += remaining.count

    #expect(
      totalFlushed == 200,
      "Total flushed (\(totalFlushed)) should equal total sent (200)"
    )
  }
}

// MARK: - MemoryStore Concurrency

@Suite("Concurrency — MemoryStore Multi-Task")
struct MemoryStoreConcurrencyTests {

  @Test("Concurrent appends to MemoryStore produce consistent count")
  func concurrentAppendsConsistentCount() async throws {
    let store = MemoryStore(capacity: 10_000)
    let tasksCount = 10
    let eventsPerTask = 100

    await withTaskGroup(of: Void.self) { group in
      for taskIdx in 0..<tasksCount {
        group.addTask {
          for eventIdx in 0..<eventsPerTask {
            let event = SpatialEvent(
              kind: .interaction(
                type: .touch,
                position: CodableSIMD3(x: Float(taskIdx), y: Float(eventIdx), z: 0)
              ),
              score: 1.0
            )
            await store.append(event)
          }
        }
      }
    }

    let count = await store.count
    #expect(
      count == tasksCount * eventsPerTask,
      "Expected \(tasksCount * eventsPerTask) events, got \(count)"
    )
  }

  @Test("Concurrent reads and writes do not deadlock")
  func concurrentReadsAndWrites() async throws {
    let store = MemoryStore(capacity: 5_000)

    await withTaskGroup(of: Void.self) { group in
      // Writer
      group.addTask {
        for idx in 0..<500 {
          let event = SpatialEvent(
            kind: .interaction(type: .touch, position: .zero),
            score: Double(idx) * 0.002
          )
          await store.append(event)
        }
      }

      // Reader (concurrent with writer)
      group.addTask {
        for _ in 0..<50 {
          _ = await store.allEvents()
          _ = await store.count
          _ = await store.events(limit: 10, offset: 0)
        }
      }
    }

    let count = await store.count
    #expect(count == 500)
  }
}
