// BatchPromptBuilder.swift
// AuraKit — Intelligence & Serialization

import Foundation

/// Constructs token-efficient JSON prompts from batches of spatial events for LLM evaluation.
public struct BatchPromptBuilder: Sendable {

  /// Compact JSON representation of a spatial event for LLM scoring.
  public struct EventPayload: Codable, Sendable {
    public let id: String
    public let kind: String
    public let score: Double
    public let timestamp: Double
  }

  /// Wraps the batch events into a single JSON request payload.
  public struct BatchPayload: Codable, Sendable {
    public let events: [EventPayload]
  }

  /// Builds a JSON prompt string from a batch of spatial events.
  ///
  /// - Parameter events: The events to evaluate.
  /// - Returns: Formatted JSON string ready for LLM inference pass.
  public static func build(from events: [SpatialEvent]) -> String {
    let payloads = events.map { event in
      EventPayload(
        id: event.id.uuidString,
        kind: String(describing: event.kind),
        score: event.score,
        timestamp: event.timestamp.timeIntervalSince1970
      )
    }

    let batch = BatchPayload(events: payloads)
    let encoder = JSONEncoder()
    // We avoid .sortedKeys as it incurs a massive performance penalty.

    if let data = try? encoder.encode(batch),
       let jsonString = String(data: data, encoding: .utf8) {
      return jsonString
    }

    return "{\"events\":[]}"
  }
}
