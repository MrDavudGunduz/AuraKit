// AuraConfigurationTests.swift
// AuraKitTests — Phase 1: Core Infrastructure Tests

import Foundation
import Testing

@testable import AuraKit

// MARK: - AuraConfigurationTests

@Suite("AuraConfiguration")
struct AuraConfigurationTests {

  // MARK: - Default Values

  @Test("Default configuration has expected values")
  func testDefaultValues() throws {
    let config = try AuraConfiguration()

    #expect(config.interactionWeight == 1.0)
    #expect(config.gazeWeight == 0.3)
    #expect(config.bufferCapacity == 512)
    #expect(config.storeCapacity == 10_000)
  }

  @Test("Static .default accessor returns valid configuration")
  func testStaticDefault() {
    let config = AuraConfiguration.default
    #expect(config.interactionWeight == 1.0)
    #expect(config.gazeWeight == 0.3)
    #expect(config.bufferCapacity == 512)
    #expect(config.storeCapacity == 10_000)
  }

  // MARK: - Custom Values

  @Test("Custom values are stored correctly")
  func testCustomValues() throws {
    let config = try AuraConfiguration(
      interactionWeight: 0.8,
      gazeWeight: 0.1,
      bufferCapacity: 128,
      storeCapacity: 5_000
    )

    #expect(config.interactionWeight == 0.8)
    #expect(config.gazeWeight == 0.1)
    #expect(config.bufferCapacity == 128)
    #expect(config.storeCapacity == 5_000)
  }

  // MARK: - Boundary Values

  @Test("Weight of exactly 0.0 is valid")
  func testZeroWeightIsValid() throws {
    let config = try AuraConfiguration(interactionWeight: 0.0, gazeWeight: 0.0)
    #expect(config.interactionWeight == 0.0)
    #expect(config.gazeWeight == 0.0)
  }

  @Test("Weight of exactly 1.0 is valid")
  func testMaxWeightIsValid() throws {
    let config = try AuraConfiguration(interactionWeight: 1.0, gazeWeight: 1.0)
    #expect(config.interactionWeight == 1.0)
    #expect(config.gazeWeight == 1.0)
  }

  @Test("Buffer capacity of 1 is valid")
  func testMinimumBufferCapacity() throws {
    let config = try AuraConfiguration(bufferCapacity: 1)
    #expect(config.bufferCapacity == 1)
  }

  @Test("storeCapacity of 0 is valid (unbounded mode)")
  func testZeroStoreCapacityIsUnbounded() throws {
    let config = try AuraConfiguration(storeCapacity: 0)
    #expect(config.storeCapacity == 0)
  }

  // MARK: - Validation Errors

  @Test("interactionWeight > 1.0 throws invalidConfiguration with reason")
  func testInteractionWeightTooHigh() {
    #expect {
      try AuraConfiguration(interactionWeight: 1.1)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("interactionWeight")
    }
  }

  @Test("interactionWeight < 0.0 throws invalidConfiguration with reason")
  func testInteractionWeightTooLow() {
    #expect {
      try AuraConfiguration(interactionWeight: -0.1)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("interactionWeight")
    }
  }

  @Test("gazeWeight > 1.0 throws invalidConfiguration with reason")
  func testGazeWeightTooHigh() {
    #expect {
      try AuraConfiguration(gazeWeight: 1.5)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("gazeWeight")
    }
  }

  @Test("gazeWeight < 0.0 throws invalidConfiguration with reason")
  func testGazeWeightNegative() {
    #expect {
      try AuraConfiguration(gazeWeight: -0.05)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("gazeWeight")
    }
  }

  @Test("bufferCapacity of 0 throws invalidConfiguration with reason")
  func testZeroBufferCapacity() {
    #expect {
      try AuraConfiguration(bufferCapacity: 0)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("bufferCapacity")
    }
  }

  @Test("bufferCapacity < 0 throws invalidConfiguration with reason")
  func testNegativeBufferCapacity() {
    #expect {
      try AuraConfiguration(bufferCapacity: -1)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("bufferCapacity")
    }
  }

  @Test("storeCapacity < 0 throws invalidConfiguration with reason")
  func testNegativeStoreCapacity() {
    #expect {
      try AuraConfiguration(storeCapacity: -1)
    } throws: { error in
      guard case AuraError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("storeCapacity")
    }
  }

  // MARK: - Equatability

  @Test("Equal configurations are equal")
  func testEquality() throws {
    let a = try AuraConfiguration(interactionWeight: 0.9, gazeWeight: 0.2, bufferCapacity: 256)
    let b = try AuraConfiguration(interactionWeight: 0.9, gazeWeight: 0.2, bufferCapacity: 256)
    #expect(a == b)
  }

  @Test("Different configurations are not equal")
  func testInequality() throws {
    let a = try AuraConfiguration(gazeWeight: 0.3)
    let b = try AuraConfiguration(gazeWeight: 0.5)
    #expect(a != b)
  }
}
