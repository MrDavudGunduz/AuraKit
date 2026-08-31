// SurvivalIndexParser.swift
// AuraKit — Intelligence & Manifest Parsing

import Foundation
import os.log

/// Represents an event score entry returned by the on-device LLM.
public struct ScoredManifestEntry: Codable, Sendable {
  public let id: String
  public let score: Double
}

/// Root JSON container for LLM output.
public struct LLMResponseManifest: Codable, Sendable {
  public let manifest: [ScoredManifestEntry]
}

/// Parses scored manifests returned by the on-device LLM.
public enum SurvivalIndexParser {

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "SurvivalIndexParser"
  )

  /// Parses raw LLM output text into a map of Event UUID -> Updated Score.
  ///
  /// - Parameters:
  ///   - rawOutput: The string response from ``MLXModelProvider``.
  ///   - fallbackEvents: Original events used as fallbacks if parsing fails.
  /// - Returns: Dictionary mapping event ID to updated initial score ($S_0$).
  public static func parse(_ rawOutput: String, referencing fallbackEvents: [SpatialEvent]) -> [UUID: Double] {
    guard let data = rawOutput.data(using: .utf8) else {
      Self.logger.debug("[AuraKit] SurvivalIndexParser: Raw LLM output could not be converted to UTF-8 data. Using fallback scores.")
      return defaultScores(for: fallbackEvents)
    }

    let decoder = JSONDecoder()
    do {
      let container = try decoder.decode(LLMResponseManifest.self, from: data)
      var result: [UUID: Double] = [:]
      for entry in container.manifest {
        if let uuid = UUID(uuidString: entry.id) {
          result[uuid] = max(0.0, min(1.0, entry.score))
        }
      }
      // Fill missing events with original scores
      for event in fallbackEvents {
        if result[event.id] == nil {
          result[event.id] = event.score
        }
      }
      return result
    } catch {
      Self.logger.debug("[AuraKit] SurvivalIndexParser: Failed to decode LLM response manifest (\(error.localizedDescription)). Using fallback scores.")
      return defaultScores(for: fallbackEvents)
    }
  }

  private static func defaultScores(for events: [SpatialEvent]) -> [UUID: Double] {
    var result: [UUID: Double] = [:]
    for event in events {
      result[event.id] = event.score
    }
    return result
  }
}
