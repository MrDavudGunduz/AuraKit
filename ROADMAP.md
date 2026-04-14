# AuraKit — Master Development Roadmap (V3 · Final Architecture)

This roadmap targets an **8-week sprint cycle** delivering AuraKit along two parallel tracks:

| Track                 | Scope                                              | License                 |
| --------------------- | -------------------------------------------------- | ----------------------- |
| **AuraKit Core**      | Capture pipeline, encrypted storage, CloudKit sync | Open Source (MIT)       |
| **Aura Intelligence** | On-device LLM, semantic pruning, Metal search      | Commercial (Enterprise) |

---

## Phase 1 — Core Infrastructure & Hybrid Capture Engine

> **Weeks 1–2 · AuraKit Core (OSS)**

### Goal

Ingest 3D spatial events at 60fps without data races, without blocking the main thread, and with a heuristic layer that bypasses AI inference for high-signal interactions.

### Deliverables

#### Swift 6 Actor Architecture

- All data flow managed through `CaptureActor` with full `Strict Concurrency` compliance
- A `RingBuffer<SpatialEvent>` (fixed-capacity, zero memory leak) handles 60fps raycast data
- All public surfaces annotated with `@MainActor` where necessary; internal actors are fully isolated

#### Dependency Injection — `AuraConfiguration`

A developer-facing configuration API that can be injected at startup:

```swift
let config = AuraConfiguration(
    interactionWeight: 1.0, // Touch/Move: max score, bypasses LLM
    gazeWeight: 0.3,        // Gaze: low-weight, queued in L1 Buffer
    bufferCapacity: 512
)
await AuraKit.shared.configure(with: config)
```

#### Heuristic Bypass Layer

| Event Type   | Routing                      | Score                       | Rationale                          |
| ------------ | ---------------------------- | --------------------------- | ---------------------------------- |
| Passive Gaze | → L1 Ring Buffer             | `gazeWeight` (configurable) | Low signal, batched for LLM        |
| Touch / Move | → Persistent memory (direct) | `1.0` (maximum, fixed)      | High signal, no LLM latency needed |

### Acceptance Criteria

- [ ] `CaptureActor` compiles with zero concurrency warnings under Swift 6
- [ ] `RingBuffer` demonstrates no memory growth over 10,000 frames in Instruments → Leaks
- [ ] `AuraConfiguration` bootstrap + first event recorded in < 5ms

---

## Phase 2 — Cryptographic SwiftData & On-Device Storage

> **Weeks 3–4 · AuraKit Core (OSS) + Security Layer**

### Goal

Build an Apple-standard, end-to-end encrypted persistent vector store with CloudKit sync and a Privacy Manifest for App Store compliance.

### Deliverables

#### SwiftData Schema Design

Two `@Model` objects form the memory hierarchy:

```swift
@Model final class RawMemoryNode {
    var id: UUID
    var encryptedPayload: Data      // AES-GCM ciphertext
    var score: Double               // Heuristic / Survival Index
    var timestamp: Date
    var eventType: SpatialEventType
}

@Model final class MemoryArchiveNode {
    var id: UUID
    var encryptedSummary: Data      // Compressed semantic vector (ciphertext)
    var createdAt: Date
    var sourceNodeIDs: [UUID]       // References to pruned RawMemoryNodes
}
```

#### Zero-Trust Encryption (Data at Rest)

- Keys generated in the **Secure Enclave** via `CryptoKit.SecureEnclave.P256.KeyAgreement`
- Symmetric key derived using HKDF → used for AES-GCM encryption of every `RawMemoryNode`
- Keys **never leave** the Secure Enclave; decryption occurs on-device only

#### CloudKit E2EE Sync

- Uses `NSPersistentCloudKitContainer` with CKRecord-level encryption
- User's memory travels from iPhone → Vision Pro without Apple or AuraKit servers seeing plaintext

#### Privacy Manifest

`PrivacyInfo.xcprivacy` declares:

- **No** data transmitted to external servers
- **No** third-party analytics or tracking SDKs
- Data types collected: spatial interaction events (stored locally, encrypted)

### Acceptance Criteria

- [ ] Every write to SwiftData verified as ciphertext in SQLite inspector
- [ ] CloudKit sync tested across two simulators with E2EE active
- [ ] Privacy Manifest passes `xcodebuild -validatePrivacyManifest`

---

## Phase 3 — On-Device LLM & Semantic Pruning

> **Weeks 5–6 · Aura Intelligence (Enterprise License)**

### Goal

Use an on-device LLM as a **filter and capacity manager** — not a generative output layer — to semantically evaluate which raw memories are worth keeping.

### Deliverables

#### MLX On-Device Sandbox

- A quantized 4B-parameter model (e.g., Llama-3.2-4B-Instruct, 4-bit) running via Apple's MLX framework
- Executed on a dedicated `IntelligenceActor` with **network entitlements revoked** (outbound connections blocked at the entitlement level)
- Model weights bundled or downloaded once and stored encrypted

#### Survival Index Algorithm

The Survival Index ($SI$) determines memory longevity:

$$SI(t) = S_0 \cdot R^n \cdot e^{-\lambda t}$$

| Variable  | Meaning                                                    |
| --------- | ---------------------------------------------------------- |
| $S_0$     | Initial score (from heuristic bypass: 0.3–1.0)             |
| $R$       | Recall multiplier (increments each time memory is queried) |
| $n$       | Recall count                                               |
| $\lambda$ | Decay constant (configurable via `AuraConfiguration`)      |
| $t$       | Age in seconds since creation                              |

Memories with $SI < threshold$ are marked for pruning or archival.

#### Async Batch Processing

- L1 Ring Buffer contents are serialized to a single JSON payload and submitted to the LLM in one inference pass
- LLM returns a scored manifest; memories below threshold are deleted from SwiftData

### Acceptance Criteria

- [ ] LLM inference completes in < 200ms for a 512-event batch on A17 Pro
- [ ] No network activity detected in Charles Proxy during LLM inference
- [ ] Survival Index scores verified against expected formula output in unit tests

---

## Phase 4 — Cognitive Compression & Manual Control API

> **Week 7 · Aura Intelligence (Enterprise License)**

### Goal

Prevent vector database bloat by converting clusters of aging low-score memories into a single semantic summary node, exposed via a developer-controlled IoC API.

### Deliverables

#### Semantic Consolidation Engine

When `RawMemoryNode` capacity is reached:

1. `IntelligenceActor` selects all nodes below the SI threshold
2. MLX analyzes them in a single prompt: _"Summarize the key spatial events in one sentence."_
3. The resulting natural-language summary is embedded as a vector
4. A `MemoryArchiveNode` is written with the encrypted summary vector
5. Source `RawMemoryNode` records are deleted

**Example output:**

> `"User inspected the southeast exhibit case twice then moved toward the exit."`

#### Inversion of Control (IoC) API

Compression is **never automatic**. The host application triggers it explicitly to avoid FPS drops:

```swift
// Safe to call during loading screens, cutscenes, or in-game sleep sessions
try await AuraKit.shared.memory.compressIdleMemories()
```

The API:

- Is `async throws` — fully non-blocking
- Returns a `CompressionReport` (nodes pruned, archive nodes created, bytes recovered)
- Emits a `MemoryCompressionEvent` via `AsyncStream` for telemetry

### Acceptance Criteria

- [ ] Compression of 1,000 nodes produces exactly 1 `MemoryArchiveNode` with valid encrypted summary
- [ ] `compressIdleMemories()` does not execute on the main thread (verified with Thread Sanitizer)
- [ ] FPS delta < 1 frame when triggered during a 60fps render loop in the test host app

---

## Phase 5 — Metal Profiling & Open-Source Distribution

> **Week 8 · Testing, Documentation & Release**

### Goal

Prove sub-millisecond performance overhead on the game loop, then ship the open-source Core and prepare the Enterprise plugin licensing infrastructure.

### Deliverables

#### Metal Compute Shaders — Cosine Similarity Search

- Memory vectors are uploaded to a `MTLBuffer`
- A custom `.metal` shader computes cosine similarity across all stored vectors in parallel
- Results returned as a sorted `[UUID: Float]` similarity map
- CPU utilization for search: < 0.5ms on A17 Pro (target)

#### Apple Instruments Profiling Report

Instruments templates used:

- **Time Profiler** — Main thread CPU overhead < 1ms per frame
- **Leaks** — Zero leaks over 60-minute stress session
- **Metal GPU Frame Capture** — Shader occupancy and dispatch latency
- **Core Data** (SwiftData) — Query latency < 5ms per lookup

#### Open-Core Distribution

```
AuraKit (GitHub, MIT)
├── Sources/AuraKit/           ← Core: Capture, Storage, CloudKit
│
AuraIntelligence (Private, Enterprise)
├── Sources/AuraIntelligence/  ← LLM, Survival Index, Metal Search
└── Plugin license validation via StoreKit 2 / JWT
```

**Release checklist:**

- [ ] GitHub Release tagged `v1.0.0` with signed SPM package
- [ ] DocC documentation hosted on GitHub Pages (`swift package generate-documentation`)
- [ ] Enterprise plugin validates license JWT on first run, cached in Keychain
- [ ] `CHANGELOG.md` updated with all Phase 1–5 deliverables

### Acceptance Criteria

- [ ] `swift package lint` passes with zero warnings
- [ ] All DocC pages rendered without broken symbol links
- [ ] Instruments report attached to GitHub Release as PDF artifact
- [ ] SPM resolution succeeds on a clean machine with `swift package resolve`

---

## Milestone Summary

| Phase                   | Weeks | Track           | Key Output                                                 |
| ----------------------- | ----- | --------------- | ---------------------------------------------------------- |
| 1 · Capture Engine      | 1–2   | Core            | `CaptureActor`, `RingBuffer`, `AuraConfiguration`          |
| 2 · Encrypted Storage   | 3–4   | Core + Security | SwiftData schema, AES-GCM, CloudKit E2EE, Privacy Manifest |
| 3 · On-Device LLM       | 5–6   | Enterprise      | `IntelligenceActor`, MLX sandbox, Survival Index           |
| 4 · Compression API     | 7     | Enterprise      | Semantic consolidation, IoC `compressIdleMemories()`       |
| 5 · Profiling + Release | 8     | All             | Metal shaders, Instruments report, SPM open-source release |
