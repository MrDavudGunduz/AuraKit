// AuraKitTests.swift
// AuraKitTests — Phase 1: Core Infrastructure Tests
//
// Integration tests for the AuraKit singleton entry point.
// Tests cover configure, capture, version, and re-configuration guard.

import Foundation
import Testing

@testable import AuraKit

// MARK: - AuraKit Singleton Tests

@Suite("AuraKit Singleton", .serialized)
@MainActor
struct AuraKitSmokeTests {

  // MARK: - Versioning

  @Test("AuraKit.version is defined and matches expected value")
  func testVersion() {
    #expect(!AuraKit.version.isEmpty)
    #expect(AuraKit.version == "1.0.0")
  }

  @Test("AuraKit.version conforms to Semantic Versioning (MAJOR.MINOR.PATCH)")
  func testVersionIsSemVer() {
    // Regex: MAJOR.MINOR.PATCH with optional pre-release/build metadata
    let semVerPattern = /^\d+\.\d+\.\d+(-[\w.]+)?(\+[\w.]+)?$/
    #expect(AuraKit.version.wholeMatch(of: semVerPattern) != nil,
            "version '\(AuraKit.version)' is not a valid SemVer string")
  }

  // MARK: - notConfigured error

  @Test("AuraError.notConfigured has correct localised description")
  func testNotConfiguredErrorDescription() {
    let error = AuraError.notConfigured
    #expect(error.errorDescription?.contains("Not configured") == true)
  }

  @Test("capture() throws notConfigured before configure(with:) is called")
  func testCaptureThrowsBeforeConfiguration() {
    // Use a fresh local AuraKit to avoid coupling on shared singleton state
    // across test runs. AuraKit.capture() delegates to AuraKit.shared internally,
    // so we directly exercise the instance method path.
    let instance = AuraKit.shared
    instance.reset()  // Ensure clean state

    #expect(throws: AuraError.notConfigured) {
      try instance.capture()
    }
  }

  // MARK: - configure + capture round-trip

  @Test("configure(with:) + capture() returns a non-nil CaptureActor")
  func testConfigureThenCapture() throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration()
    try instance.configure(with: config)
    let captureActor = try instance.capture()

    // CaptureActor is a reference type (actor); capturing it should succeed
    #expect(type(of: captureActor) == CaptureActor.self)

    instance.reset()  // Teardown
  }

  // MARK: - Re-configuration guard

  @Test("configure(with:) after reset() succeeds and returns a new CaptureActor")
  func testReconfigureAfterReset() throws {
    // Validates the documented reconfiguration flow: reset() then configure().
    let instance = AuraKit.shared
    instance.reset()

    let config1 = try AuraConfiguration(bufferCapacity: 64)
    try instance.configure(with: config1)
    let first = try instance.capture()

    instance.reset()

    let config2 = try AuraConfiguration(bufferCapacity: 256)
    try instance.configure(with: config2)
    let second = try instance.capture()

    // After reset + reconfigure, a new actor is vended
    #expect(first !== second)

    instance.reset()  // Teardown
  }

  // MARK: - alreadyConfigured error

  @Test("configure(with:) throws alreadyConfigured on double call without reset")
  func testDoubleConfigureThrowsAlreadyConfigured() throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration()
    try instance.configure(with: config)

    #expect(throws: AuraError.alreadyConfigured) {
      try instance.configure(with: config)
    }

    instance.reset()  // Teardown
  }

  // MARK: - Static convenience API

  @Test("Static AuraKit.capture() throws if not configured")
  func testStaticCaptureThrowsIfNotConfigured() {
    AuraKit.shared.reset()
    #expect(throws: AuraError.notConfigured) {
      try AuraKit.capture()
    }
  }

  // MARK: - reset()

  @Test("reset() clears configuration — capture() throws notConfigured afterwards")
  func testResetClearsConfiguration() throws {
    let instance = AuraKit.shared
    let config = try AuraConfiguration()
    try instance.configure(with: config)
    _ = try instance.capture()  // Should succeed

    instance.reset()

    #expect(throws: AuraError.notConfigured) {
      try instance.capture()
    }
  }

  // MARK: - isConfigured

  @Test("isConfigured is false before configure(with:) is called")
  func testIsConfiguredBeforeConfigure() {
    let instance = AuraKit.shared
    instance.reset()
    #expect(!instance.isConfigured)
  }

  @Test("isConfigured is true after configure(with:) is called")
  func testIsConfiguredAfterConfigure() throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration()
    try instance.configure(with: config)
    #expect(instance.isConfigured)

    instance.reset()  // Teardown
  }

  @Test("isConfigured returns to false after reset()")
  func testIsConfiguredAfterReset() throws {
    let instance = AuraKit.shared
    instance.reset()

    let config = try AuraConfiguration()
    try instance.configure(with: config)
    #expect(instance.isConfigured)

    instance.reset()
    #expect(!instance.isConfigured)
  }

  // MARK: - Store Injection

  @Test("configure(with:store:) injects custom store into CaptureActor")
  func testConfigureWithCustomStore() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let customStore = MemoryStore(capacity: 100)
    let config = try AuraConfiguration()
    try instance.configure(with: config, store: customStore)

    let capture = try instance.capture()
    let event = SpatialEvent.touchFixture()
    await capture.record(event: event)

    // Event should be in the custom store
    let storedCount = await customStore.count
    #expect(storedCount == 1, "Custom store should contain the recorded event")

    let events = await customStore.allEvents()
    #expect(events.first?.id == event.id, "Stored event should match recorded event")

    instance.reset()
  }

  @Test("Static configure(with:store:) convenience wrapper works")
  func testStaticConfigureWithStore() async throws {
    let instance = AuraKit.shared
    instance.reset()

    let customStore = MemoryStore(capacity: 50)
    let config = try AuraConfiguration()
    try AuraKit.configure(with: config, store: customStore)

    #expect(instance.isConfigured)

    let capture = try AuraKit.capture()
    await capture.record(event: .touchFixture())

    let storedCount = await customStore.count
    #expect(storedCount == 1)

    instance.reset()
  }
}
