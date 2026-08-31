// PromptBuilderTests.swift
// AuraKitTests — Intelligence Prompt Serialization & Parsing Tests

import Foundation
import Testing
@testable import AuraKit

@Suite("Intelligence — Prompt Builders & Manifest Parsing")
struct PromptBuilderTests {

  @Test("BatchPromptBuilder generates clean JSON payload using eventType rawValue")
  func batchPromptBuilderFormatting() {
    let now = Date()
    let id1 = UUID()
    let id2 = UUID()

    let event1 = SpatialEvent(
      id: id1,
      timestamp: now,
      kind: .gaze(position: .zero),
      score: 0.75
    )
    let event2 = SpatialEvent(
      id: id2,
      timestamp: now.addingTimeInterval(10),
      kind: .interaction(type: .touch, position: .zero),
      score: 0.95
    )

    let json = BatchPromptBuilder.build(from: [event1, event2])

    #expect(json.contains("\"kind\":\"gaze\""))
    #expect(json.contains("\"kind\":\"touch\""))
    #expect(json.contains("\"id\":\"\(id1.uuidString)\""))
    #expect(json.contains("\"id\":\"\(id2.uuidString)\""))
    #expect(json.contains("\"score\":0.75"))
    #expect(json.contains("\"score\":0.95"))
    // Ensure raw SIMD descriptions are NOT leaked
    #expect(!json.contains("SIMD3"))
  }

  @Test("SurvivalIndexParser parses valid manifests and fills missing events with fallback scores")
  func survivalIndexParserValidManifest() {
    let event1 = SpatialEvent.gazeFixture(score: 0.5)
    let event2 = SpatialEvent.touchFixture(score: 0.8)
    let id1 = event1.id
    let id2 = event2.id

    let jsonManifest = """
    {
      "manifest": [
        { "id": "\(id1.uuidString)", "score": 0.9 }
      ]
    }
    """

    let scores = SurvivalIndexParser.parse(jsonManifest, referencing: [event1, event2])

    #expect(scores[id1] == 0.9)
    #expect(scores[id2] == 0.8) // fallback from original event
  }

  @Test("SurvivalIndexParser handles invalid or empty JSON gracefully")
  func survivalIndexParserInvalidJSON() {
    let event = SpatialEvent.gazeFixture(score: 0.42)
    let id = event.id

    let invalidScores = SurvivalIndexParser.parse("not-a-json", referencing: [event])
    #expect(invalidScores[id] == 0.42)

    let emptyScores = SurvivalIndexParser.parse("{}", referencing: [event])
    #expect(emptyScores[id] == 0.42)
  }
}
