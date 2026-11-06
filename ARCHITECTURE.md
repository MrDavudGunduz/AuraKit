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
│                  IntelligenceActor                                 │
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
│                               │ Local-only SQLite (No Sync)      │
└───────────────────────────────┼──────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────┐
│                       LAYER 4: SEARCH                            │
│                     MetalSearchEngine                            │
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
    private var buffer: RingBuffer<SpatialEvent>
    private let router: HeuristicRouter
    let store: any SpatialEventStore

    public func record(event: SpatialEvent) async {
        let decision = router.route(event, config: config)

        switch decision {
        case .directStore(let score):
            await store.append(event.withScore(score))      // High-signal → persistent memory
        case .enqueueBuffer(let score):
            buffer.enqueue(event.withScore(score))          // Low-signal → L1 ring buffer (sync)
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

### `IntelligenceActor`

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
public final class RawMemoryNode {
    @Attribute(.unique) public var id: UUID
    public var encryptedPayload: Data       // AES-GCM ciphertext (nonce ‖ ciphertext ‖ tag), bound via AAD
    public var score: Double                // Heuristic or Survival Index score
    public var timestamp: Date
    public var eventType: String            // SpatialEventType.rawValue (.gaze | .touch | .move | .pinch | .drag)
    public var recalled: Int                // Incremented by explicit recallAndFetchAll() — feeds SI(t) Rⁿ
    public var keyVersion: Int              // Tracks encryption key version for partial rotation migration
}
```

### `MemoryArchiveNode`

```swift
@Model
public final class MemoryArchiveNode {
    @Attribute(.unique) public var id: UUID
    public var encryptedSummary: Data       // LLM-generated semantic summary, AES-GCM encrypted (AAD-bound)
    public var createdAt: Date
    public var sourceNodeIDsData: Data      // JSON-encoded [UUID] — defensive encoding
}
```

> **Note:** `sourceNodeIDs` is stored as `Data` (JSON-encoded `[UUID]`) with a `@Transient` in-memory cache (`decodedSourceNodeIDs`) for zero-allocation repeated reads.

---

## Dependency Injection — `AuraConfiguration`

AuraKit uses a **value-type configuration** injected at startup, composed of domain-specific sub-configurations (`CaptureConfiguration`, `StorageConfiguration`, `IntelligenceConfiguration`). There are no singletons with mutable global state.

```swift
public struct AuraConfiguration: Sendable, Equatable {
    public let capture: CaptureConfiguration
    public let storage: StorageConfiguration
    public let intelligence: IntelligenceConfiguration

    public init(
        capture: CaptureConfiguration,
        storage: StorageConfiguration,
        intelligence: IntelligenceConfiguration
    ) { ... }
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
| LLM inference never on main thread                    | `IntelligenceActor` background isolation        |

---

## Metal Search Architecture

### Shader Pipeline

```metal
// cosine_similarity.metal
struct CosineSimilarityParams {
    uint dimension;
    uint vectorCount;
};

kernel void cosine_similarity_kernel(
    device const float* queryVector           [[buffer(0)]],
    device const float* memoryVectors         [[buffer(1)]],
    device float*       results               [[buffer(2)]],
    constant CosineSimilarityParams& params   [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= params.vectorCount) { return; }
    const uint dim = params.dimension;
    const uint offset = gid * dim;

    float dotProduct = 0.0f, queryMagnitudeSq = 0.0f, memoryMagnitudeSq = 0.0f;
    for (uint i = 0; i < dim; i++) {
        float q = queryVector[i];
        float m = memoryVectors[offset + i];
        dotProduct += q * m;
        queryMagnitudeSq += q * q;
        memoryMagnitudeSq += m * m;
    }
    float denominator = sqrt(queryMagnitudeSq) * sqrt(memoryMagnitudeSq);
    results[gid] = (denominator < 1e-8f) ? 0.0f : (dotProduct / denominator);
}
```

### Non-Blocking Host-Side Dispatch

```swift
// MetalSearchEngine+Dispatch.swift
// Uses addCompletedHandler + CheckedContinuation to avoid blocking the Swift Concurrency thread pool:
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    commandBuffer.addCompletedHandler { completed in
        if let error = completed.error {
            continuation.resume(throwing: AuraError.vectorSearchFailed(
                reason: "Metal compute command failed: \(error.localizedDescription)"
            ))
        } else {
            continuation.resume()
        }
    }
    commandBuffer.commit()
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
