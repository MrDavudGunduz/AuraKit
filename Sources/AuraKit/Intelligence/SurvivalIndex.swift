// SurvivalIndex.swift
// AuraKit — Intelligence & Semantic Memory
//
// Implements the Survival Index (SI) memory decay and recall multiplier algorithm.

import Foundation

/// Mathematical engine for calculating the Survival Index (SI) of spatial memories.
///
/// The Survival Index determines memory longevity and determines when a memory
/// node falls below the threshold for pruning or archival:
///
/// ```
/// SI(t) = S₀ · Rⁿ · e^(-λt)
/// ```
///
/// | Variable | Description |
/// | -------- | ----------- |
/// | `S₀`     | Initial heuristic/semantic score `[0.0, 1.0]` |
/// | `R`      | Recall multiplier (e.g. 1.2) |
/// | `n`      | Number of times the memory was queried (`recalledCount`) |
/// | `λ`      | Exponential decay constant per second |
/// | `t`      | Age in seconds since creation |
public struct SurvivalIndex: Sendable {

  /// Calculates the Survival Index for a given memory item at time `t`.
  ///
  /// - Parameters:
  ///   - initialScore: Initial score $S_0$ (clamped to `[0.0, 1.0]`).
  ///   - recallCount: Number of times recalled $n$ ($\ge 0$).
  ///   - ageInSeconds: Age of the memory $t$ in seconds ($\ge 0$).
  ///   - decayConstant: Exponential decay constant $\lambda$ per second ($\ge 0$).
  ///   - recallMultiplier: Recall multiplier $R$ ($\ge 1.0$).
  /// - Returns: The computed Survival Index $SI(t)$.
  public static func calculate(
    initialScore: Double,
    recallCount: Int,
    ageInSeconds: TimeInterval,
    decayConstant: Double = AuraConfiguration.defaultDecayConstant,
    recallMultiplier: Double = AuraConfiguration.defaultRecallMultiplier
  ) -> Double {
    let s0 = max(0.0, min(1.0, initialScore))
    let n = max(0, recallCount)
    let t = max(0.0, ageInSeconds)
    let lambda = max(0.0, decayConstant)
    let r = max(1.0, recallMultiplier)

    // R^n component
    let recallBoost = pow(r, Double(n))

    // e^(-λt) component
    let decayFactor = exp(-lambda * t)

    let score = s0 * recallBoost * decayFactor
    return max(0.0, score.isNaN || score.isInfinite ? 0.0 : score)
  }

  /// Calculates the Survival Index for a ``SpatialEvent`` at a specific reference date.
  ///
  /// - Parameters:
  ///   - event: The spatial event to evaluate.
  ///   - recallCount: Number of times this event was recalled ($n$).
  ///   - referenceDate: Target date for calculation (defaults to current date).
  ///   - config: Configuration providing $\lambda$ and $R$.
  /// - Returns: The computed Survival Index $SI(t)$.
  public static func calculate(
    for event: SpatialEvent,
    recallCount: Int = 0,
    referenceDate: Date = Date(),
    config: AuraConfiguration = .default
  ) -> Double {
    let age = referenceDate.timeIntervalSince(event.timestamp)
    return calculate(
      initialScore: event.score,
      recallCount: recallCount,
      ageInSeconds: age,
      decayConstant: config.intelligence.decayConstant,
      recallMultiplier: config.intelligence.recallMultiplier
    )
  }
}
