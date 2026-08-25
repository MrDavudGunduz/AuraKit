// ConsolidationPromptBuilder.swift
// AuraKit — Intelligence & Serialization
//
// Constructs the LLM prompt for cognitive compression (Phase 4).
// Given a set of low-SI RawMemoryNodeSnapshots, produces a token-efficient
// JSON prompt that asks the model to summarize the key spatial events
// in one sentence.

import Foundation

// MARK: - ConsolidationPromptBuilder

/// Builds a token-efficient LLM prompt for cognitive compression of spatial memories.
///
/// `ConsolidationPromptBuilder` serializes a set of ``RawMemoryNodeSnapshot``
/// records into a structured JSON prompt that instructs the on-device LLM to
/// produce a single-sentence natural-language summary.
///
/// ## Prompt Structure
///
/// ```json
/// {
///   "task": "consolidate",
///   "instruction": "Summarize the key spatial events in one sentence.",
///   "events": [
///     { "type": "gaze", "score": 0.12, "timestamp": 1693000000.0 },
///     { "type": "touch", "score": 0.08, "timestamp": 1693000050.0 }
///   ]
/// }
/// ```
///
/// ## Thread Safety
///
/// `ConsolidationPromptBuilder` is a stateless `enum` — fully `Sendable` and
/// safe to call from any actor or task without synchronisation.
public enum ConsolidationPromptBuilder {

  // MARK: - Internal Payload Types

  /// Compact representation of a memory node for the consolidation prompt.
  struct NodePayload: Codable, Sendable {
    let type: String
    let score: Double
    let timestamp: Double
  }

  /// The top-level consolidation request sent to the LLM.
  struct ConsolidationPayload: Codable, Sendable {
    let task: String
    let instruction: String
    let events: [NodePayload]
  }

  // MARK: - Public API

  /// Builds a consolidation prompt from an array of memory node snapshots.
  ///
  /// The resulting JSON string is ready for direct submission to
  /// ``MLXModelProvider/infer(prompt:)``.
  ///
  /// - Parameter snapshots: The low-SI node snapshots to consolidate.
  ///   Order is preserved but not semantically significant — the LLM
  ///   considers all events holistically.
  /// - Returns: A formatted JSON prompt string.
  public static func build(from snapshots: [RawMemoryNodeSnapshot]) -> String {
    let payloads = snapshots.map { snapshot in
      NodePayload(
        type: snapshot.eventType.rawValue,
        score: snapshot.score,
        timestamp: snapshot.timestamp.timeIntervalSince1970
      )
    }

    let consolidation = ConsolidationPayload(
      task: "consolidate",
      instruction: "Summarize the key spatial events in one sentence.",
      events: payloads
    )

    let encoder = JSONEncoder()

    if let data = try? encoder.encode(consolidation),
       let jsonString = String(data: data, encoding: .utf8) {
      return jsonString
    }

    return "{\"task\":\"consolidate\",\"instruction\":\"Summarize the key spatial events in one sentence.\",\"events\":[]}"
  }
}
