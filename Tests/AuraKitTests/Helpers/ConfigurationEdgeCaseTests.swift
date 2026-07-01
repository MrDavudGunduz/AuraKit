// ConfigurationEdgeCaseTests.swift
// AuraKitTests — Configuration Lifecycle Edge Cases
//
// Validates configureIfNeeded() idempotency, shutdown → reconfigure lifecycle,
// double shutdown safety, and other configuration edge cases.

import Foundation
import Testing

@testable import AuraKit

@Suite("AuraKit — Configuration Edge Cases", .serialized)
@MainActor
struct ConfigurationEdgeCaseTests {

  // MARK: - Setup / Teardown

  init() {
    AuraKit.shared.reset()
  }

  // MARK: - configureIfNeeded Idempotency

  @Test("configureIfNeeded succeeds on first call")
  func configureIfNeededFirstCall() throws {
    let config = AuraConfiguration.default
    AuraKit.shared.configureIfNeeded(with: config)

    #expect(AuraKit.shared.isConfigured)
    let capture = try AuraKit.shared.capture()
    #expect(capture != nil)
    AuraKit.shared.reset()
  }

  @Test("configureIfNeeded is a no-op on subsequent calls")
  func configureIfNeededIdempotent() async throws {
    let config = AuraConfiguration.default
    AuraKit.shared.configureIfNeeded(with: config)

    // Get a reference to the capture actor from first configure
    let firstCapture = try AuraKit.shared.capture()

    // Call again — should be a no-op
    AuraKit.shared.configureIfNeeded(with: config)

    // Same capture actor should be returned
    let secondCapture = try AuraKit.shared.capture()
    #expect(firstCapture === secondCapture)
    AuraKit.shared.reset()
  }

  @Test("configureIfNeeded does not throw when already configured")
  func configureIfNeededDoesNotThrow() throws {
    // First, configure normally (strict)
    try AuraKit.shared.configure(with: .default)

    // configureIfNeeded should NOT throw (unlike configure which would)
    AuraKit.shared.configureIfNeeded(with: .default)

    // Still configured
    #expect(AuraKit.shared.isConfigured)
    AuraKit.shared.reset()
  }

  @Test("static configureIfNeeded works")
  func staticConfigureIfNeeded() throws {
    AuraKit.configureIfNeeded(with: .default)
    #expect(AuraKit.shared.isConfigured)

    // Second call is no-op
    AuraKit.configureIfNeeded(with: .default)
    #expect(AuraKit.shared.isConfigured)
    AuraKit.shared.reset()
  }

  // MARK: - Shutdown → Reconfigure Lifecycle

  @Test("shutdown then configure creates fresh pipeline")
  func shutdownThenConfigure() async throws {
    let config = AuraConfiguration.default
    try AuraKit.shared.configure(with: config)

    let firstCapture = try AuraKit.shared.capture()
    await firstCapture.record(event: .gazeFixture())

    // Shutdown flushes and tears down
    let flushed = await AuraKit.shared.shutdown()
    #expect(flushed >= 0)
    #expect(AuraKit.shared.isConfigured == false)

    // Reconfigure — should succeed
    try AuraKit.shared.configure(with: config)
    #expect(AuraKit.shared.isConfigured)

    let secondCapture = try AuraKit.shared.capture()
    // New capture actor — fresh pipeline
    #expect(firstCapture !== secondCapture)
    AuraKit.shared.reset()
  }

  @Test("shutdown on unconfigured pipeline returns 0")
  func shutdownUnconfigured() async {
    #expect(AuraKit.shared.isConfigured == false)
    let flushed = await AuraKit.shared.shutdown()
    #expect(flushed == 0)
  }

  // MARK: - Double Shutdown Safety

  @Test("calling shutdown twice does not crash")
  func doubleShutdown() async throws {
    try AuraKit.shared.configure(with: .default)

    let first = await AuraKit.shared.shutdown()
    #expect(first >= 0)
    #expect(AuraKit.shared.isConfigured == false)

    // Second shutdown — should be safe, return 0
    let second = await AuraKit.shared.shutdown()
    #expect(second == 0)
  }

  // MARK: - Reset → Configure Cycle

  @Test("reset then configure works cleanly")
  func resetThenConfigure() throws {
    try AuraKit.shared.configure(with: .default)
    AuraKit.shared.reset()
    #expect(AuraKit.shared.isConfigured == false)

    // Re-configure after reset
    try AuraKit.shared.configure(with: .default)
    #expect(AuraKit.shared.isConfigured)
    AuraKit.shared.reset()
  }

  @Test("multiple reset calls are safe")
  func multipleResets() {
    AuraKit.shared.reset()
    AuraKit.shared.reset()
    AuraKit.shared.reset()
    #expect(AuraKit.shared.isConfigured == false)
  }

  // MARK: - Capture Before Configure

  @Test("capture() throws notConfigured before configure")
  func captureBeforeConfigure() {
    do {
      _ = try AuraKit.shared.capture()
      Issue.record("Expected notConfigured error")
    } catch let error as AuraError {
      #expect(error == .notConfigured)
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }

  @Test("captureOrNil returns nil before configure")
  func captureOrNilBeforeConfigure() {
    #expect(AuraKit.shared.captureOrNil == nil)
  }

  // MARK: - configureIfNeeded with Custom Store

  @Test("configureIfNeeded with store parameter works on first call")
  func configureIfNeededWithStore() async throws {
    let store = MemoryStore(capacity: 100)
    AuraKit.shared.configureIfNeeded(with: .default, store: store)

    #expect(AuraKit.shared.isConfigured)

    let capture = try AuraKit.shared.capture()
    await capture.record(event: .touchFixture())

    let persisted = await capture.persistedEvents()
    #expect(persisted.count == 1)
    AuraKit.shared.reset()
  }

  @Test("static configureIfNeeded with store works")
  func staticConfigureIfNeededWithStore() async throws {
    let store = MemoryStore(capacity: 100)
    AuraKit.configureIfNeeded(with: .default, store: store)

    #expect(AuraKit.shared.isConfigured)
    AuraKit.shared.reset()
  }
}
