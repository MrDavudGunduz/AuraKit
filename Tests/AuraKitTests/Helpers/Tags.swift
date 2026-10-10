// Tags.swift
// AuraKitTests — Shared Swift Testing tags & traits
//
// Tests that assert on wall-clock time (latency / throughput budgets) are
// only meaningful on a quiet machine in a release build. Under parallel
// execution, sanitizers or a loaded CI runner they produce false failures.
//
// They are therefore:
//   • tagged `.performance` (filterable in Xcode's Test Navigator), and
//   • gated by `.performanceGate`, which DISABLES them unless the environment
//     variable `AURAKIT_RUN_PERFORMANCE=1` is set.
//
// (SwiftPM's `swift test` has no `--skip-tag` option, hence the env gate.)
//
// Run them deliberately with:
//   AURAKIT_RUN_PERFORMANCE=1 swift test -c release -Xswiftc -enable-testing \
//     --no-parallel --filter "Performance|Stress|Benchmark|Bootstrap"
//
// The dedicated `test-performance` job in `.github/workflows/ci.yml` does this.

import Foundation
import Testing

extension Tag {
  /// Tests that assert on elapsed wall-clock time (latency / throughput budgets).
  @Tag static var performance: Self
}

extension Trait where Self == ConditionTrait {
  /// Enables a test only when `AURAKIT_RUN_PERFORMANCE=1` is set in the environment.
  static var performanceGate: Self {
    .enabled(
      if: ProcessInfo.processInfo.environment["AURAKIT_RUN_PERFORMANCE"] == "1",
      "Wall-clock benchmark — set AURAKIT_RUN_PERFORMANCE=1 to run (release build, serial)."
    )
  }
}
