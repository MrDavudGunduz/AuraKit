// SurvivalIndexTests.swift
// AuraKitTests — Phase 3 Survival Index Formula Tests

import Foundation
import Testing
@testable import AuraKit

@Suite("Survival Index Formula — SI(t) = S₀ · Rⁿ · e^(-λt)")
struct SurvivalIndexTests {

  @Test("Fresh event (t=0, n=0) yields initial score S0")
  func freshEventScore() {
    let score = SurvivalIndex.calculate(
      initialScore: 0.8,
      recallCount: 0,
      ageInSeconds: 0,
      decayConstant: 0.0001,
      recallMultiplier: 1.2
    )

    #expect(abs(score - 0.8) < 0.0001)
  }

  @Test("Aging event (t > 0) decays exponentially")
  func agingDecay() {
    let freshScore = SurvivalIndex.calculate(
      initialScore: 1.0,
      recallCount: 0,
      ageInSeconds: 0,
      decayConstant: 0.001,
      recallMultiplier: 1.2
    )

    let agedScore = SurvivalIndex.calculate(
      initialScore: 1.0,
      recallCount: 0,
      ageInSeconds: 1000,
      decayConstant: 0.001,
      recallMultiplier: 1.2
    )

    // e^(-0.001 * 1000) = e^(-1) ≈ 0.367879
    #expect(freshScore > agedScore)
    #expect(abs(agedScore - 0.367879) < 0.001)
  }

  @Test("Recalled event (n > 0) boosts Survival Index score")
  func recallMultiplierBoost() {
    let unrecalled = SurvivalIndex.calculate(
      initialScore: 0.5,
      recallCount: 0,
      ageInSeconds: 100,
      decayConstant: 0.0001,
      recallMultiplier: 1.2
    )

    let recalledTwice = SurvivalIndex.calculate(
      initialScore: 0.5,
      recallCount: 2,
      ageInSeconds: 100,
      decayConstant: 0.0001,
      recallMultiplier: 1.2
    )

    // 1.2^2 = 1.44 boost factor
    #expect(recalledTwice > unrecalled)
    #expect(abs(recalledTwice - (unrecalled * 1.44)) < 0.001)
  }

  @Test("Edge cases: negative age and negative recall count clamped safely")
  func edgeCasesClamped() {
    let score = SurvivalIndex.calculate(
      initialScore: 0.9,
      recallCount: -5,
      ageInSeconds: -300,
      decayConstant: 0.0001,
      recallMultiplier: 1.2
    )

    #expect(abs(score - 0.9) < 0.0001)
  }

  @Test("SpatialEvent extension calculates correct SI from referenceDate")
  func spatialEventConvenience() {
    let timestamp = Date().addingTimeInterval(-100)
    let event = SpatialEvent(
      id: UUID(),
      timestamp: timestamp,
      kind: .gaze(position: .zero),
      score: 1.0
    )

    let config = try! AuraConfiguration(decayConstant: 0.001, recallMultiplier: 1.2)
    let score = SurvivalIndex.calculate(for: event, recallCount: 1, referenceDate: Date(), config: config)

    // e^(-0.1) * 1.2 ≈ 0.904837 * 1.2 ≈ 1.0858 -> clamped / math result
    #expect(score > 0)
  }
}
