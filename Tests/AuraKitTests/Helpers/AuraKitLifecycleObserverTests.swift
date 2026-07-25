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
}
