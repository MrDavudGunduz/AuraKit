// HeuristicRouterTests.swift
// AuraKitTests — Phase 1: Core Infrastructure Tests

import Foundation
import Testing

@testable import AuraKit

// MARK: - HeuristicRouterTests

@Suite("HeuristicRouter")
struct HeuristicRouterTests {

  // MARK: Helpers

  private let router = HeuristicRouter()
  private let config = AuraConfiguration.default

  private func gazeEvent() -> SpatialEvent {
    SpatialEvent(kind: .gaze(rawPosition: SIMD3<Float>(0.5, 0.5, -1.0)), score: 0)
  }

  private func interactionEvent(type: InteractionType) -> SpatialEvent {
    SpatialEvent(
      kind: .interaction(type: type, rawPosition: SIMD3<Float>(0.1, 0.9, -0.5)), score: 0)
  }

  // MARK: - Gaze Routing

  @Test("Gaze event → enqueueBuffer with gazeWeight score")
  func testGazeRoutedToBuffer() {
    let event = gazeEvent()
    let decision = router.route(event, config: config)

    guard case .enqueueBuffer(let score) = decision else {
      Issue.record("Expected .enqueueBuffer, got \(decision)")
      return
    }
    #expect(score == config.gazeWeight)
  }

  @Test("Gaze score equals configured gazeWeight")
  func testGazeScoreMatchesConfig() throws {
    let customConfig = try AuraConfiguration(gazeWeight: 0.15)
    let decision = router.route(gazeEvent(), config: customConfig)

    guard case .enqueueBuffer(let score) = decision else {
      Issue.record("Expected .enqueueBuffer")
      return
    }
    #expect(score == 0.15)
  }

  // MARK: - Interaction Routing

  @Test("Touch event → directStore with interactionWeight score")
  func testTouchRoutedToStore() {
    let event = interactionEvent(type: .touch)
    let decision = router.route(event, config: config)

    guard case .directStore(let score) = decision else {
      Issue.record("Expected .directStore, got \(decision)")
      return
    }
    #expect(score == config.interactionWeight)
  }

  @Test("Move event → directStore with interactionWeight score")
  func testMoveRoutedToStore() {
    let event = interactionEvent(type: .move)
    let decision = router.route(event, config: config)

    guard case .directStore(let score) = decision else {
      Issue.record("Expected .directStore, got \(decision)")
      return
    }
    #expect(score == config.interactionWeight)
  }

  @Test("Pinch event → directStore with interactionWeight score")
  func testPinchRoutedToStore() {
    let event = interactionEvent(type: .pinch)
    let decision = router.route(event, config: config)

    guard case .directStore = decision else {
      Issue.record("Expected .directStore, got \(decision)")
      return
    }
  }

  @Test("Drag event → directStore with interactionWeight score")
  func testDragRoutedToStore() {
    let event = interactionEvent(type: .drag)
    let decision = router.route(event, config: config)

    guard case .directStore = decision else {
      Issue.record("Expected .directStore, got \(decision)")
      return
    }
  }

  @Test("Interaction score is 1.0 (maximum) with default config")
  func testInteractionScoreIsMaximum() {
    let decision = router.route(interactionEvent(type: .touch), config: config)

    if case .directStore(let score) = decision {
      #expect(score == 1.0)
    } else {
      Issue.record("Expected .directStore")
    }
  }

  // MARK: - RouteDecision Equatability

  @Test("RouteDecision equality: same case and score are equal")
  func testRouteDecisionEquality() {
    let a = RouteDecision.directStore(score: 1.0)
    let b = RouteDecision.directStore(score: 1.0)
    #expect(a == b)

    let c = RouteDecision.enqueueBuffer(score: 0.3)
    let d = RouteDecision.enqueueBuffer(score: 0.3)
    #expect(c == d)

    #expect(a != c)
  }
}
