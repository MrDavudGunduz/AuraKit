# AuraKit — Testing Guide

> **Framework:** [Swift Testing](https://developer.apple.com/documentation/testing) (Xcode 16+ / Swift 6)  
> **Target:** `AuraKitTests`  
> **Parallellism:** All `@Test` functions run in parallel by default — write them as independent, side-effect-free units.

---

## Table of Contents

- [Philosophy](#philosophy)
- [Directory Structure](#directory-structure)
- [Running Tests](#running-tests)
- [Core Concepts](#core-concepts)
  - [@Test and @Suite](#test-and-suite)
  - [#expect and #require](#expect-and-require)
  - [Tags](#tags)
  - [Parameterized Tests](#parameterized-tests)
  - [async/await & Actor Testing](#asyncawait--actor-testing)
  - [withKnownIssue](#withknownissue)
  - [Confirmation (AsyncStream & Callbacks)](#confirmation-asyncstream--callbacks)
- [Testing Patterns Per Layer](#testing-patterns-per-layer)
  - [RingBuffer](#ringbuffer)
  - [CaptureActor](#captureactor)
  - [Encryption](#encryption)
  - [MemoryActor](#memoryactor)
  - [Survival Index (Enterprise)](#survival-index-enterprise)
- [Mocking Strategy](#mocking-strategy)
- [Code Coverage](#code-coverage)
- [Continuous Integration](#continuous-integration)

---

## Philosophy

AuraKit tests follow four principles:

1. **Isolation** — Each `@Test` function is independent. No shared mutable state exists between tests.
2. **Determinism** — Tests produce the same result on every run. No `sleep()`, no `Date()` without injection, no network calls.
3. **Concurrency Safety** — Tests exercise Actor boundaries explicitly. The Swift Testing runtime runs tests in parallel; all tests must be safe under concurrent execution.
4. **Readability** — Test names are full sentences. A failing test name should read like a bug report: _"RingBuffer overwrites oldest entry when at capacity"_.

---

## Directory Structure

```
Tests/AuraKitTests/
├── AuraKitTests.swift              ← Top-level bootstrap / smoke test
│
├── Capture/
│   ├── RingBufferTests.swift       ← O(1) guarantees, overflow, edge cases
│   └── CaptureActorTests.swift     ← Actor isolation, heuristic bypass routing
│
├── Memory/
│   ├── EncryptionTests.swift       ← AES-GCM round-trips, tamper detection
│   └── MemoryActorTests.swift      ← Persist, query, prune, compress
│
├── Configuration/
│   └── AuraConfigurationTests.swift ← Default values, weight clamping, Sendable
│
├── Intelligence/                   ← Enterprise tier (conditional compilation)
│   └── SurvivalIndexTests.swift    ← SI formula, decay, recall multiplier
│
└── Helpers/
    ├── MockMemoryStore.swift        ← In-memory SwiftData substitute
    └── SpatialEventFactory.swift    ← Test data builders
```

---

## Running Tests

```bash
# Run all tests (parallel, default)
swift test

# Run a specific named suite
swift test --filter "RingBuffer"

# Run a specific test function
swift test --filter "RingBuffer/overwrites oldest entry when at capacity"

# Run with code coverage
swift test --enable-code-coverage

# Run serially (useful for debugging race conditions)
swift test --no-parallel

# Run in Xcode: ⌘U (all) or click the ◆ diamond next to @Test
```

---

## Core Concepts

### @Test and @Suite

```swift
import Testing
@testable import AuraKit

// ── Standalone test ────────────────────────────────────────────────────────
@Test("AuraKit.version matches semantic versioning format")
func versionFormatIsValid() {
    let components = AuraKit.version.split(separator: ".").map(String.init)
    #expect(components.count == 3)
    #expect(components.allSatisfy { Int($0) != nil })
}

// ── Suite: groups related tests, supports setUp/tearDown via init/deinit ──
@Suite("RingBuffer")
struct RingBufferTests {

    // Swift Testing does not have setUp/tearDown;
    // use stored properties initialised in init() instead.
    let buffer: RingBuffer<Int>

    init() {
        buffer = RingBuffer<Int>(capacity: 4)
    }

    @Test("starts empty")
    func startsEmpty() {
        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
    }
}
```

### #expect and #require

| Macro                                 | Behaviour on failure                                    |
| ------------------------------------- | ------------------------------------------------------- |
| `#expect(condition)`                  | Records failure, test continues                         |
| `#require(condition)`                 | Records failure, **stops** the current test immediately |
| `#expect(throws: ErrorType.self) { }` | Asserts that a specific error is thrown                 |
| `#expect(throws: Never.self) { }`     | Asserts that no error is thrown                         |

```swift
@Test("decryption fails when ciphertext is tampered")
func decryptionFailsOnTamperedData() throws {
    let key = SymmetricKey(size: .bits256)
    var ciphertext = try encrypt(Data("hello".utf8), using: key)
    ciphertext[ciphertext.startIndex] ^= 0xFF  // Flip first byte

    #expect(throws: CryptoKitError.self) {
        _ = try decrypt(ciphertext, using: key)
    }
}

@Test("configuration interactionWeight is clamped to 1.0")
func interactionWeightClamped() throws {
    let config = AuraConfiguration(interactionWeight: 2.5)
    let weight = try #require(config.interactionWeight as Double?)
    #expect(weight <= 1.0)
}
```

### Tags

Tags allow cross-suite filtering without changing directory structure:

```swift
extension Tag {
    @Tag static var concurrency: Self
    @Tag static var encryption: Self
    @Tag static var performance: Self
    @Tag static var enterprise: Self
}

@Test("CaptureActor serialises concurrent writes", .tags(.concurrency))
func concurrentWritesSerialized() async { ... }

@Test("AES-GCM round-trip produces identical plaintext", .tags(.encryption))
func aesGCMRoundTrip() throws { ... }
```

Run only tagged tests:

```bash
swift test --filter ":concurrency"
swift test --filter ":encryption"
```

### Parameterized Tests

```swift
@Suite("AuraConfiguration weight validation")
struct ConfigurationWeightTests {

    // Test runs once per argument — shown individually in Xcode test navigator
    @Test(
        "gazeWeight is never negative",
        arguments: [-1.0, -0.5, -0.001, 0.0, 0.3, 1.0]
    )
    func gazeWeightNonNegative(input: Double) {
        let config = AuraConfiguration(gazeWeight: input)
        #expect(config.gazeWeight >= 0.0)
    }

    // Zip two sequences for paired arguments
    @Test(
        "scores match expected heuristic bypass values",
        arguments: zip(
            [SpatialEventType.gaze,  .touch, .move],
            [0.3,                    1.0,    1.0  ]
        )
    )
    func heuristicBypassScores(eventType: SpatialEventType, expectedScore: Double) {
        let score = HeuristicBypass.score(for: eventType, config: .default)
        #expect(score == expectedScore)
    }
}
```

### async/await & Actor Testing

Swift Testing natively supports `async` test functions — no `XCTestExpectation` or semaphores needed.

```swift
@Suite("CaptureActor", .serialized)  // .serialized prevents parallel execution within this suite
struct CaptureActorTests {

    @Test("touch event bypasses LLM and scores 1.0")
    func touchEventBypassesLLM() async throws {
        let store = MockMemoryStore()
        let actor = CaptureActor(config: .default, store: store)

        await actor.record(event: .interaction(type: .touch, position: .zero))

        let persisted = await store.persistedEvents
        #expect(persisted.count == 1)
        #expect(persisted.first?.score == 1.0)
    }

    @Test("gaze event is enqueued in L1 buffer, not persisted immediately")
    func gazeEventEnqueuedInBuffer() async throws {
        let store = MockMemoryStore()
        let actor = CaptureActor(config: .default, store: store)

        await actor.record(event: .gaze(position: .zero))

        let persisted = await store.persistedEvents
        #expect(persisted.isEmpty, "Gaze should not bypass to store directly")
    }
}
```

> **Note on `.serialized`:** Apply `@Suite(..., .serialized)` only when tests genuinely share actor-level state. Prefer independent tests that can run in parallel.

### withKnownIssue

Use `withKnownIssue` to mark tests that are expected to fail due to a known, tracked bug. This prevents false passes/failures during CI and documents the issue inline.

```swift
@Test("compression completes under 50ms on A15 (known: regression tracked in #42)")
func compressionPerformance() async throws {
    withKnownIssue("Performance regression on A15 — see GitHub issue #42") {
        let start = ContinuousClock.now
        try await AuraKit.shared.memory.compressIdleMemories()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(50))
    }
}
```

### Confirmation (AsyncStream & Callbacks)

`Confirmation` replaces `XCTestExpectation` for verifying that async events fire a specific number of times.

```swift
@Test("memory compression emits exactly one MemoryCompressionEvent")
func compressionEmitsEvent() async throws {
    let actor = MemoryActor(config: .default)

    // Prime the store with compressible data
    for _ in 0..<100 {
        await actor.persist(SpatialEventFactory.lowScoreEvent())
    }

    // Confirm the event fires exactly once
    await confirmation("MemoryCompressionEvent emitted") { confirm in
        let stream = await actor.compressionEventStream  // AsyncStream<MemoryCompressionEvent>
        var iterator = stream.makeAsyncIterator()
        try await actor.compressIdleMemories()
        let event = await iterator.next()
        #expect(event != nil)
        confirm()
    }
}
```

---

## Testing Patterns Per Layer

### RingBuffer

```swift
@Suite("RingBuffer")
struct RingBufferTests {

    @Test("count reflects writes up to capacity")
    func countGrowsWithWrites() {
        var buffer = RingBuffer<Int>(capacity: 4)
        #expect(buffer.count == 0)
        buffer.write(1); #expect(buffer.count == 1)
        buffer.write(2); #expect(buffer.count == 2)
        buffer.write(3); buffer.write(4)
        #expect(buffer.count == 4)
    }

    @Test("overwrites oldest entry when at capacity")
    func overwritesOldestOnFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.write(1); buffer.write(2); buffer.write(3)
        buffer.write(4)  // Evicts 1
        let contents = buffer.readAll()
        #expect(contents == [2, 3, 4])
    }

    @Test("isEmpty returns true only before first write")
    func isEmptyBehavior() {
        var buffer = RingBuffer<String>(capacity: 2)
        #expect(buffer.isEmpty)
        buffer.write("a")
        #expect(!buffer.isEmpty)
    }

    @Test("write then readAll is idempotent for N in 1...capacity",
          arguments: 1...8)
    func writeAndReadAllParameterized(n: Int) {
        var buffer = RingBuffer<Int>(capacity: n)
        for i in 0..<n { buffer.write(i) }
        #expect(buffer.readAll().count == n)
    }
}
```

### CaptureActor

```swift
@Suite("CaptureActor — Heuristic Bypass", .serialized)
struct CaptureActorHeuristicTests {

    @Test("move event is assigned score 1.0 and stored immediately",
          .tags(.concurrency))
    func moveEventMaxScore() async throws {
        let store = MockMemoryStore()
        let actor = CaptureActor(
            config: AuraConfiguration(interactionWeight: 1.0, gazeWeight: 0.3),
            store: store
        )
        await actor.record(event: .interaction(type: .move, position: .zero))
        let events = await store.persistedEvents
        #expect(events.first?.score == 1.0)
    }

    @Test("100 concurrent gaze writes do not corrupt ring buffer",
          .tags(.concurrency))
    func concurrentGazeWrites() async throws {
        let actor = CaptureActor(config: .default, store: MockMemoryStore())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await actor.record(
                        event: .gaze(position: .init(Float(i), 0, 0))
                    )
                }
            }
        }
        let count = await actor.bufferCount
        #expect(count <= 512)  // Must not exceed configured capacity
    }
}
```

### Encryption

```swift
@Suite("AES-GCM Encryption", .tags(.encryption))
struct EncryptionTests {

    let key = SymmetricKey(size: .bits256)

    @Test("encrypt then decrypt produces original plaintext")
    func roundTripIsLossless() throws {
        let original = Data("Spatial memory payload 🔐".utf8)
        let ciphertext = try encrypt(original, using: key)
        let recovered = try decrypt(ciphertext, using: key)
        #expect(recovered == original)
    }

    @Test("ciphertext differs from plaintext")
    func ciphertextIsNotPlaintext() throws {
        let original = Data("test".utf8)
        let ciphertext = try encrypt(original, using: key)
        #expect(ciphertext != original)
    }

    @Test("two encryptions of the same plaintext produce different ciphertexts (nonce uniqueness)")
    func nonceUniqueness() throws {
        let data = Data("same input".utf8)
        let c1 = try encrypt(data, using: key)
        let c2 = try encrypt(data, using: key)
        #expect(c1 != c2, "Nonce reuse detected — AES-GCM nonces must be unique per encryption")
    }

    @Test("decryption throws on bit-flipped ciphertext", .tags(.encryption))
    func tamperDetection() throws {
        let original = Data("sensitive".utf8)
        var ciphertext = try encrypt(original, using: key)
        ciphertext[ciphertext.index(ciphertext.startIndex, offsetBy: 5)] ^= 0xFF
        #expect(throws: CryptoKitError.self) {
            _ = try decrypt(ciphertext, using: key)
        }
    }
}
```

### MemoryActor

```swift
@Suite("MemoryActor", .serialized)
struct MemoryActorTests {

    @Test("persisted node is retrievable by query")
    func persistAndQuery() async throws {
        let actor = MemoryActor(store: MockMemoryStore())
        let event = SpatialEventFactory.touchEvent(score: 1.0)
        try await actor.persist(event)
        let results = try await actor.query(context: "touch", limit: 1)
        #expect(results.count == 1)
    }

    @Test("compressIdleMemories removes low-SI nodes and creates archive node")
    func compressionProducesArchiveNode() async throws {
        let store = MockMemoryStore()
        let actor = MemoryActor(store: store, config: .init(pruningThreshold: 0.5))

        for _ in 0..<20 {
            try await actor.persist(SpatialEventFactory.lowScoreEvent(score: 0.1))
        }

        let report = try await actor.compressIdleMemories()

        #expect(report.nodesPruned == 20)
        #expect(report.archiveNodesCreated == 1)
        let rawCount = await store.rawNodeCount
        #expect(rawCount == 0)
    }
}
```

### Survival Index (Enterprise)

```swift
@Suite("SurvivalIndex formula")
struct SurvivalIndexTests {

    @Test("SI decays toward zero over time", arguments: [10.0, 100.0, 1000.0, 10_000.0])
    func decaysOverTime(ageSeconds: Double) {
        let si = SurvivalIndex.calculate(
            initialScore: 1.0,
            recallCount: 0,
            ageSeconds: ageSeconds,
            decayConstant: 0.001
        )
        #expect(si > 0.0)
        #expect(si < 1.0)

        let older = SurvivalIndex.calculate(
            initialScore: 1.0,
            recallCount: 0,
            ageSeconds: ageSeconds * 2,
            decayConstant: 0.001
        )
        #expect(older < si, "Older memory should have lower SI")
    }

    @Test("recall multiplier increases SI relative to non-recalled memory")
    func recallBoostsSI() {
        let age = 500.0
        let base = SurvivalIndex.calculate(
            initialScore: 1.0, recallCount: 0, ageSeconds: age, decayConstant: 0.001
        )
        let recalled = SurvivalIndex.calculate(
            initialScore: 1.0, recallCount: 5, ageSeconds: age, decayConstant: 0.001
        )
        #expect(recalled > base)
    }
}
```

---

## Mocking Strategy

AuraKit avoids protocol-bloat for the sake of testability. Mocks are **minimal, concrete structs** that conform to the same protocols as production types.

```swift
// Helpers/MockMemoryStore.swift

/// In-memory substitute for SwiftData store used in unit tests.
/// Safe to use across actor boundaries — all state is actor-isolated.
actor MockMemoryStore: MemoryStorable {
    private(set) var persistedEvents: [ScoredEvent] = []
    private(set) var rawNodeCount: Int = 0

    func persist(_ event: ScoredEvent) async {
        persistedEvents.append(event)
        rawNodeCount += 1
    }

    func query(context: String, limit: Int) async -> [ScoredEvent] {
        Array(persistedEvents.prefix(limit))
    }

    func deleteAll(below threshold: Double) async {
        persistedEvents.removeAll { $0.score < threshold }
        rawNodeCount = persistedEvents.count
    }

    func reset() {
        persistedEvents = []
        rawNodeCount = 0
    }
}
```

```swift
// Helpers/SpatialEventFactory.swift

/// Deterministic test data builders. Never use Date() or UUID() directly in tests.
enum SpatialEventFactory {

    static func touchEvent(
        score: Double = 1.0,
        position: SIMD3<Float> = .zero,
        id: UUID = UUID()
    ) -> ScoredEvent {
        ScoredEvent(
            id: id,
            type: .touch,
            position: position,
            score: score,
            timestamp: Date(timeIntervalSinceReferenceDate: 0)  // Fixed date for determinism
        )
    }

    static func lowScoreEvent(score: Double = 0.05) -> ScoredEvent {
        touchEvent(score: score)
    }

    static func gazeEvent(weight: Double = 0.3) -> ScoredEvent {
        ScoredEvent(
            id: UUID(),
            type: .gaze,
            position: .zero,
            score: weight,
            timestamp: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
}
```

---

## Code Coverage

### Generate Report

```bash
# 1. Run tests with coverage enabled
swift test --enable-code-coverage

# 2. Locate the profdata file
PROFDATA=$(find .build -name "default.profdata" | head -1)
BINARY=$(find .build -name "AuraKitPackageTests" -type f | head -1)

# 3. Print per-file coverage summary
xcrun llvm-cov report "$BINARY" -instr-profile "$PROFDATA" -ignore-filename-regex ".build"

# 4. Export as LCOV for CI upload (Codecov, Coveralls, etc.)
xcrun llvm-cov export "$BINARY" \
    -instr-profile "$PROFDATA" \
    -format=lcov \
    -ignore-filename-regex ".build" > coverage.lcov
```

### Coverage Thresholds

| Module                          | Minimum | Rationale                                |
| ------------------------------- | ------- | ---------------------------------------- |
| `Sources/AuraKit/Core`          | 90%     | Public API — every branch documented     |
| `Sources/AuraKit/Models`        | 85%     | Data models, init paths                  |
| Encryption round-trips          | 100%    | Zero tolerance for untested crypto paths |
| Error handling paths            | 70%     | All `catch` blocks exercised             |
| Enterprise (`AuraIntelligence`) | 80%     | Complex LLM paths harder to mock         |

---

## Continuous Integration

The GitHub Actions workflow runs tests on every push and pull request:

```yaml
# .github/workflows/tests.yml
name: Tests

on: [push, pull_request]

jobs:
  test:
    name: Swift ${{ matrix.swift }} on ${{ matrix.os }}
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [macos-15]
        swift: ["6.0"]

    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app

      - name: Resolve Dependencies
        run: swift package resolve

      - name: Build
        run: swift build -c release

      - name: Test with Coverage
        run: swift test --enable-code-coverage

      - name: Generate Coverage Report
        run: |
          PROFDATA=$(find .build -name "default.profdata" | head -1)
          BINARY=$(find .build -name "AuraKitPackageTests" -type f | head -1)
          xcrun llvm-cov export "$BINARY" \
            -instr-profile "$PROFDATA" \
            -format=lcov \
            -ignore-filename-regex ".build" > coverage.lcov

      - name: Upload Coverage to Codecov
        uses: codecov/codecov-action@v4
        with:
          files: coverage.lcov
          flags: unittests
          fail_ci_if_error: true
```
