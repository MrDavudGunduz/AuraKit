// AuraKitLifecycleObserverTests.swift
// AuraKitTests — Lifecycle Observer Tests

import Foundation
import Testing

@testable import AuraKit

@Suite("AuraKitLifecycleObserver Tests", .serialized)
struct AuraKitLifecycleObserverTests {

  @Test("LifecycleObserver startObserving and stopObserving do not crash")
  @MainActor
  func lifecycleObserverStartStop() {
    let observer = AuraKitLifecycleObserver.shared
    observer.startObserving()
    // Repeated call is no-op
    observer.startObserving()
    observer.stopObserving()
    // Repeated call is no-op
    observer.stopObserving()
  }

  @Test("AuraKit.startLifecycleObserver convenience method succeeds")
  @MainActor
  func auraKitStartLifecycleObserver() {
    AuraKit.shared.startLifecycleObserver()
  }

  @Test("Background flush returns immediately on the main actor and completes off it")
  @MainActor
  func backgroundFlushDoesNotBlockMainActor() async throws {
    let store = try makeTestEncryptedStore(saveThreshold: 100)
    let capture = CaptureActor(config: try AuraConfiguration.smallBuffer(), store: store)
    await capture.record(event: .gaze(at: SIMD3(0, 0, 0)))
    await capture.record(event: .touch(at: SIMD3(1, 1, 1)))

    // Regression: the macOS path previously waited on a semaphore on the main
    // thread while the flush itself required the main actor (25 s hang).
    let clock = ContinuousClock()
    let start = clock.now
    let task = AuraKitLifecycleObserver.shared.beginBackgroundFlush(capture: capture)
    #expect(start.duration(to: clock.now) < .milliseconds(500))

    await task.value
    #expect(await capture.bufferedEventCount == 0)
    #expect(await store.count == 2)
  }

  @Test("Background flush with no configured pipeline completes")
  @MainActor
  func backgroundFlushWithoutPipeline() async {
    await AuraKitLifecycleObserver.shared.beginBackgroundFlush(capture: nil).value
  }
}
