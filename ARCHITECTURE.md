# AuraKit — Technical Architecture

## Overview

AuraKit is built on a **strict Actor-isolation model** enforced by Swift 6's Strict Concurrency checker. Every subsystem runs on its own isolated `Actor`, communicating through `async/await` message passing. There are no shared mutable globals; all state mutation is serialized through actor boundaries.

---

## Architectural Layers

```
┌──────────────────────────────────────────────────────────────────┐
│                        Host Application                          │
│              (Game, AR App, Spatial Computing App)               │
└─────────────────────────────┬────────────────────────────────────┘
                              │  AuraConfiguration (DI)
                              │  AuraKit.shared (entry point)
┌─────────────────────────────▼────────────────────────────────────┐
│                         LAYER 1: CAPTURE                         │
│                        CaptureActor                              │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │              RingBuffer<SpatialEvent>                     │   │
│  │    Fixed capacity · Zero Allocation · Thread-safe         │   │
│  └────────────┬──────────────────────────┬────────────────── ┘   │
│               │ .gaze (low weight)        │ .touch/.move (1.0)    │
│               │ → L1 enqueue              │ → Heuristic Bypass    │
└───────────────┼───────────────────────── ┼──────────────────────┘
                │                           │
┌───────────────▼───────────────────────── ▼──────────────────────┐
│                     LAYER 2: INTELLIGENCE                        │
│                  IntelligenceActor (Enterprise)                  │
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
│                          MemoryActor                             │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │   SwiftData Store (AES-GCM · Secure Enclave keys)         │   │
│  │   RawMemoryNode  ◄──────────►  MemoryArchiveNode          │   │
│  └────────────────────────────┬──────────────────────────────┘   │
│                               │ CloudKit E2EE                    │
└───────────────────────────────┼──────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────┐
│                       LAYER 4: SEARCH                            │
│                     Metal Search Layer (Enterprise)              │
│          GPU Cosine Similarity via MTLComputePipelineState       │
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

        let score: Float
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

### `MemoryActor`

**Responsibility:** Persist `RawMemoryNode` and `MemoryArchiveNode` objects to the encrypted SwiftData store, and expose the IoC compression API.

Key methods:

| Method                            | Description                                                       |
| --------------------------------- | ----------------------------------------------------------------- |
| `persist(_ event: ScoredEvent)`   | Encrypt and write a `RawMemoryNode`                               |
| `query(context:limit:)`           | Retrieve top-N memories via Metal cosine search                   |
| `compressIdleMemories()`          | Enterprise IoC: consolidate low-SI nodes into `MemoryArchiveNode` |
| `delete(below threshold: Double)` | Prune nodes below Survival Index threshold                        |

---

## Data Models

### `RawMemoryNode`

```swift
@Model
final class RawMemoryNode {
    @Attribute(.unique) var id: UUID
    var encryptedPayload: Data       // AES-GCM ciphertext (never stored as plaintext)
    var score: Double                // Heuristic or Survival Index score
    var timestamp: Date
    var eventType: SpatialEventType  // .gaze | .touch | .move
    var recalled: Int                // Incremented on each query hit
}
```

### `MemoryArchiveNode`

```swift
@Model
final class MemoryArchiveNode {
    @Attribute(.unique) var id: UUID
    var encryptedSummary: Data       // LLM-generated semantic summary, encrypted
    var embeddingVector: Data        // Float32 array for Metal cosine search
    var createdAt: Date
    var sourceNodeIDs: [UUID]        // Pruned RawMemoryNode references (for audit)
}
```

---

## Dependency Injection — `AuraConfiguration`

AuraKit uses a **value-type configuration** injected at startup. There are no singletons with mutable global state.

```swift
public struct AuraConfiguration: Sendable, Equatable {
    /// Weight applied to passive gaze events (0.0–1.0).
    public let gazeWeight: Float

    /// Weight applied to active interactions. Bypasses LLM (always 1.0 by default).
    public let interactionWeight: Float

    /// Maximum number of frames the Ring Buffer holds before overwrite.
    public let bufferCapacity: Int

    /// Maximum events the MemoryStore retains (FIFO eviction at cap).
    public let storeCapacity: Int

    public init(
        interactionWeight: Float = 1.0,
        gazeWeight: Float = 0.3,
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
