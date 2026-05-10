# AuraKit — Technical Architecture

## Overview

AuraKit is built on a **strict Actor-isolation model** enforced by Swift 6's Strict Concurrency checker. Every subsystem runs on its own isolated `Actor`, communicating through `async/await` message passing. There are no shared mutable globals; all state mutation is serialized through actor boundaries.

---

## Architectural Layers

```
┌──────────────────────────────────────────────────────────────────┐
│                        Host Application                          │
│              (Game, AR App, Spatial Computing App)                │
└─────────────────────────────┬────────────────────────────────────┘
                              │ SpatialEvent
┌─────────────────────────────▼────────────────────────────────────┐
│                     LAYER 1: CAPTURE                             │
│                      CaptureActor                                │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │             RingBuffer<SpatialEvent>                       │   │
│  │    Fixed capacity · Zero Allocation · Thread-safe         │   │
│  └────────────┬──────────────────────────┬───────────────────┘   │
│               │ .gaze (low weight)       │ .touch/.move (1.0)    │
│               │ → L1 enqueue             │ → Heuristic Bypass    │
└───────────────┼──────────────────────────┼───────────────────────┘
                │                          │
┌───────────────▼──────────────────────────▼───────────────────────┐
│                     LAYER 2: INTELLIGENCE                        │
│                  IntelligenceActor (Enterprise)                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │   MLX LLM Sandbox (network-isolated · Apple Silicon)      │   │
│  │   Batch inference → Survival Index scoring                │   │
│  │   SI(t) = S₀ · Rⁿ · e^(-λt)                             │   │
│  └────────────────────────────┬──────────────────────────────┘   │
│                               │ Ranked manifest                  │
└───────────────────────────────┼──────────────────────────────────┘
                                │ Prune / Persist
┌───────────────────────────────▼──────────────────────────────────┐
│                      LAYER 3: MEMORY                             │
│              SpatialEventStore (Protocol)                         │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  MemoryStore (Phase 1 — in-memory, test/dev)              │   │
│  │  EncryptedMemoryStore (Phase 2 — AES-GCM, production)     │   │
│  │    SwiftData + Secure Enclave keys + Keychain             │   │
│  │    RawMemoryNode  ◄──────────►  MemoryArchiveNode         │   │
│  └────────────────────────────┬──────────────────────────────┘   │
│                               │ CloudKit E2EE                    │
└───────────────────────────────┼──────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────┐
│                       LAYER 4: SEARCH                            │
│                     Metal Search Layer (Enterprise)               │
│          GPU Cosine Similarity via MTLComputePipelineState        │
└──────────────────────────────────────────────────────────────────┘
```

---

## Actor Model

### `CaptureActor`

**Responsibility:** Accept raw spatial events from the host application and route them based on heuristic classification.

```swift
public actor CaptureActor {
    private let config: AuraConfiguration
    private let buffer: RingBuffer<SpatialEvent>
    private let router: HeuristicRouter
    private let store: any SpatialEventStore

    public func record(event: SpatialEvent) async {
        let decision = router.route(event, config: config)

        let score: Double
        switch decision {
        case .directStore(let routedScore): score = routedScore
        case .enqueueBuffer(let routedScore): score = routedScore
        }

        let scored = SpatialEvent(
            id: event.id, timestamp: event.timestamp,
            kind: event.kind, score: score
        )

        switch decision {
        case .directStore:
            await store.append(scored)      // High-signal → persistent memory
        case .enqueueBuffer:
            await buffer.enqueue(scored)    // Low-signal → L1 ring buffer
        }
    }
}
```

**Why Actor?**

- Eliminates data races on `RingBuffer` without a single `DispatchQueue` or `NSLock`
- Swift 6 compiler enforces isolation at compile time — not runtime

---

### `RingBuffer<T>`

A generic, fixed-capacity circular buffer that overwrites the oldest entry when full. This prevents unbounded memory growth under sustained 60fps input.

```
capacity = 512

Write pointer ──►  [■][■][■][■][■][ ][ ][ ][ ][ ]
                    0   1   2   3   4   5 ...
```

**Invariants:**

- O(1) read and write — no heap allocation after initialization
- Thread-safe because all access is serialized through `CaptureActor`
- When full: oldest entry is overwritten (oldest-first eviction)

---

### `IntelligenceActor` (Enterprise)

**Responsibility:** Batch-evaluate L1 buffer contents using the on-device LLM and produce Survival Index scores.

```swift
actor IntelligenceActor {
    private let model: MLXLanguageModel  // network-isolated, Apple Silicon

    func evaluate(batch: [SpatialEvent]) async throws -> [ScoredEvent] {
        let prompt = BatchPromptBuilder.build(from: batch)
        let response = try await model.infer(prompt)
        return SurvivalIndexParser.parse(response, referencing: batch)
    }
}
```

**MLX Sandbox constraints:**

- `com.apple.security.network.client` entitlement: **false**
- Model runs entirely within process memory — no XPC, no extension
- Inference dispatched on a background priority task to protect the render loop

---

### `EncryptedMemoryStore` (Phase 2 Production Store)

**Responsibility:** Encrypt and persist `RawMemoryNode` objects to SwiftData, expose paginated queries, and track recall counters for the Survival Index formula.

```swift
public actor EncryptedMemoryStore: SpatialEventStore {
    private let modelContext: ModelContext      // autosaveEnabled = false
    private let keyManager: KeyManager
    private let encryptionService: EncryptionService
}
```

Key methods:

| Method                                  | Description                                                       |
| --------------------------------------- | ----------------------------------------------------------------- |
| `append(_ event: SpatialEvent)`         | Encrypt → `RawMemoryNode` → SwiftData                            |
| `allEvents()`                           | **Pure read** — full-table decrypt, no side effects               |
| `events(limit:offset:)`                 | **Pure read** — paginated decrypt, prevents OOM                   |
| `recallAndFetchAll()`                   | Full-table decrypt **+ recalled++** (Survival Index)              |
| `recallAndFetch(limit:offset:)`         | Paginated decrypt **+ recalled++**                                |
| `events(limit:offset:)`                 | Paginated decrypt — prevents OOM on large stores                  |
| `fetchNodeCount(eventType:)`            | Metadata-only count (no decrypt)                                  |
| `recalledCount(for: UUID)`              | Sendable-safe recalled counter projection                         |
| `deleteNodes(belowScore:)`              | Prune nodes below Survival Index threshold                        |
| `clear()`                               | Test-only: delete all nodes                                       |

**Design decisions:**

- `autosaveEnabled = false` — explicit `save()` calls prevent duplicate-write race conditions
- **Read/write separation**: `allEvents()` and `events(limit:offset:)` are pure reads. Use `recallAndFetchAll()` / `recallAndFetch(limit:offset:)` to explicitly increment recalled for SI(t) = S₀ · Rⁿ · e^(-λt)
- Failed decryptions are logged and skipped — corrupted nodes never crash the pipeline

---

### `SpatialEventStore` Protocol

```swift
public protocol SpatialEventStore: Actor {
    func append(_ event: SpatialEvent) async
    func allEvents() async -> [SpatialEvent]
    var count: Int { get async }
}
```

**Conforming types:**

- `MemoryStore` — Phase 1 in-memory store (tests, prototyping)
- `EncryptedMemoryStore` — Phase 2 AES-GCM encrypted SwiftData store (production)

---

## Data Models

### `RawMemoryNode`

```swift
@Model
final class RawMemoryNode {
    @Attribute(.unique) var id: UUID
    var encryptedPayload: Data       // AES-GCM ciphertext (nonce ‖ ciphertext ‖ tag)
    var score: Double                // Heuristic or Survival Index score
    var timestamp: Date
    var eventType: String            // SpatialEventType.rawValue (.gaze | .touch | .move)
    var recalled: Int = 0            // Incremented by explicit recallAndFetchAll() — feeds SI(t) Rⁿ
}
```

### `MemoryArchiveNode`

```swift
@Model
final class MemoryArchiveNode {
    @Attribute(.unique) var id: UUID
    var encryptedSummary: Data       // LLM-generated semantic summary, encrypted
    var createdAt: Date
    var sourceNodeIDsData: Data      // JSON-encoded [UUID] — defensive try? encoding
}
```

> **Note:** `sourceNodeIDs` is stored as `Data` (JSON-encoded `[UUID]`) for SwiftData/CloudKit compatibility. A computed property provides type-safe access. Encoding uses defensive `try?` with `os.log` diagnostics to prevent production crashes.

---

## Dependency Injection — `AuraConfiguration`

AuraKit uses a **value-type configuration** injected at startup. There are no singletons with mutable global state.

```swift
public struct AuraConfiguration: Sendable, Equatable {
    /// Weight applied to passive gaze events (0.0–1.0).
    public let gazeWeight: Double

    /// Weight applied to active interactions. Bypasses LLM (always 1.0 by default).
    public let interactionWeight: Double

    /// Maximum number of frames the Ring Buffer holds before overwrite.
    public let bufferCapacity: Int

    /// Maximum events the MemoryStore retains (FIFO eviction at cap).
    public let storeCapacity: Int

    public init(
        interactionWeight: Double = 1.0,
        gazeWeight: Double = 0.3,
        bufferCapacity: Int = 512,
        storeCapacity: Int = 10_000
    ) throws { ... }
}
```

---

## Concurrency Contract

| Rule                                                  | Enforcement                                     |
| ----------------------------------------------------- | ----------------------------------------------- |
| No `@State` or mutable global state                   | Swift 6 compiler                                |
| All actor methods are `async`                         | Actor isolation                                 |
| `SpatialEvent` and `AuraConfiguration` are `Sendable` | `Sendable` conformance required                 |
| UI updates always on `@MainActor`                     | Explicit `@MainActor` annotation                |
| LLM inference never on main thread                    | `Task(priority: .background)` + actor isolation |

---

## Metal Search Architecture (Enterprise)

### Shader Pipeline

```metal
// cosine_similarity.metal
kernel void cosineSimilarity(
    device const float* queryVector   [[ buffer(0) ]],
    device const float* memoryVectors [[ buffer(1) ]],
    device       float* scores        [[ buffer(2) ]],
    constant     uint&  vectorDim     [[ buffer(3) ]],
    uint gid [[ thread_position_in_grid ]])
{
    float dot = 0, qMag = 0, mMag = 0;
    for (uint i = 0; i < vectorDim; i++) {
        float q = queryVector[i];
        float m = memoryVectors[gid * vectorDim + i];
        dot  += q * m;
        qMag += q * q;
        mMag += m * m;
    }
    scores[gid] = dot / (sqrt(qMag) * sqrt(mMag) + 1e-8);
}
```

### Host-Side Dispatch

```swift
func search(query: [Float], in memories: [MemoryArchiveNode]) async throws -> [UUID: Float] {
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let encoder = commandBuffer.makeComputeCommandEncoder()!
    // Bind buffers, set thread groups, dispatch
    encoder.dispatchThreads(
        MTLSizeMake(memories.count, 1, 1),
        threadsPerThreadgroup: MTLSizeMake(64, 1, 1)
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return parseScores(from: scoresBuffer, nodeIDs: memories.map(\.id))
}
```

---

## Performance Targets

| Metric                              | Target      | Measurement Tool            |
| ----------------------------------- | ----------- | --------------------------- |
| Main thread overhead per frame      | < 1ms       | Instruments → Time Profiler |
| Ring Buffer write (per event)       | O(1), < 1µs | Instruments → CPU counters  |
| SwiftData write (per node)          | < 5ms       | Instruments → Core Data     |
| LLM batch inference (512 events)    | < 200ms     | Custom `OSSignpost` spans   |
| Metal cosine search (1,000 vectors) | < 0.5ms     | Metal GPU Frame Capture     |
| Memory leaks over 60min session     | Zero        | Instruments → Leaks         |
