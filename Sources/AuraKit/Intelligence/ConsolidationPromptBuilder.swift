// ConsolidationPromptBuilder.swift
// AuraKit — Intelligence & Serialization
//
// Constructs the LLM prompt for cognitive compression (Phase 4).
// Given a set of low-SI RawMemoryNodeSnapshots, produces a token-efficient
// JSON prompt that asks the model to summarize the key spatial events
// in one sentence.

import Foundation
import os.log

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

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "ConsolidationPromptBuilder"
  )

  // MARK: - Internal Payload Types

  /// Compact representation of a memory node for the consolidation prompt.
  ///
  /// `position` is only present when the prompt is built from decrypted
  /// events; `nil` fields are omitted from the JSON.
  struct NodePayload: Codable, Sendable {
    let type: String
    let score: Double
    let timestamp: Double
    var position: [Float]?
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

    return encode(payloads)
  }

  /// Builds a consolidation prompt from **decrypted** events.
  ///
  /// Unlike the snapshot-based `build(from:)`, which only sees plaintext
  /// metadata, this includes each event's 3D position, so the summary can
  /// describe *where* things happened. This is what cognitive compression
  /// uses: the source records are deleted afterwards, so a metadata-only
  /// summary would irreversibly discard the actual memory content.
  ///
  /// The prompt never leaves the device — it is consumed by the on-device
  /// ``MLXModelProvider``.
  ///
  /// - Parameter events: The decrypted events to consolidate.
  /// - Returns: A formatted JSON prompt string.
  public static func build(from events: [SpatialEvent]) -> String {
    let payloads = events.map { event in
      let position: CodableSIMD3
      switch event.kind {
      case .gaze(let gazePosition): position = gazePosition
      case .interaction(_, let interactionPosition): position = interactionPosition
      }
      return NodePayload(
        type: event.kind.eventType.rawValue,
        score: event.score,
        timestamp: event.timestamp.timeIntervalSince1970,
        position: [position.x, position.y, position.z]
      )
    }
    return encode(payloads)
  }

  // MARK: - Encoding

  private static let fallbackPrompt =
    "{\"task\":\"consolidate\",\"instruction\":\"Summarize the key spatial events in one sentence.\",\"events\":[]}"

  private static func encode(_ payloads: [NodePayload]) -> String {
    let consolidation = ConsolidationPayload(
      task: "consolidate",
      instruction: "Summarize the key spatial events in one sentence.",
      events: payloads
    )

    let encoder = JSONEncoder()

    do {
      let data = try encoder.encode(consolidation)
      guard let jsonString = String(data: data, encoding: .utf8) else {
        Self.logger.error(
          "[AuraKit] ConsolidationPromptBuilder: Failed to decode UTF-8 string from encoded JSON data."
        )
        return fallbackPrompt
      }
      return jsonString
    } catch {
      Self.logger.error(
        "[AuraKit] ConsolidationPromptBuilder: Failed to encode JSON — \(error.localizedDescription)"
      )
      return fallbackPrompt
    }
  }
}
