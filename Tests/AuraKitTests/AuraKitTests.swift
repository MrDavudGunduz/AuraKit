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
    instance.configure(with: config)
    let captureActor = try instance.capture()

    // CaptureActor is a reference type (actor); capturing it should succeed
    #expect(type(of: captureActor) == CaptureActor.self)

    instance.reset()  // Teardown
  }

  // MARK: - Re-configuration guard

  @Test("configure(with:) after reset() succeeds and returns a new CaptureActor")
  func testReconfigureAfterReset() throws {
    // The double-configure guard (assertionFailure) is a debug-only programming-error
    // contract that terminates the process — it cannot be unit-tested via Swift Testing.
    // This test validates the documented reconfiguration flow: reset() then configure().
    let instance = AuraKit.shared
    instance.reset()

    let config1 = try AuraConfiguration(bufferCapacity: 64)
    instance.configure(with: config1)
    let first = try instance.capture()

    instance.reset()

    let config2 = try AuraConfiguration(bufferCapacity: 256)
    instance.configure(with: config2)
    let second = try instance.capture()

    // After reset + reconfigure, a new actor is vended
    #expect(first !== second)

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
    instance.configure(with: config)
    _ = try instance.capture()  // Should succeed

    instance.reset()

    #expect(throws: AuraError.notConfigured) {
      try instance.capture()
    }
  }
}
