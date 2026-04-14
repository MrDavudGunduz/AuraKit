# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

> Changes staged for the next release.

### Added

- Project scaffold: Swift Package with Swift 6 Strict Concurrency and multi-platform support (iOS 17+, macOS 14+, visionOS 1+)
- SwiftLint build plugin integrated as a compile-time code quality gate
- DocC plugin added for professional API documentation generation

---

## [1.0.0] — _Planned: Week 8 Sprint_

### Added

#### Phase 1 — Core Infrastructure (Weeks 1–2)

- `CaptureActor`: Swift 6 Actor-isolated spatial event ingestion pipeline
- `RingBuffer<T>`: Fixed-capacity circular buffer (O(1) read/write, zero memory leak at 60fps)
- `AuraConfiguration`: Value-type Dependency Injection API (`gazeWeight`, `interactionWeight`, `bufferCapacity`, `decayConstant`, `pruningThreshold`)
- Heuristic Bypass Layer: Touch/Move events score `1.0` and bypass LLM — direct to persistent store
- Passive Gaze routing: low-weight events enqueued to L1 Ring Buffer for batch processing

#### Phase 2 — Encrypted Storage (Weeks 3–4)

- `RawMemoryNode`: `@Model`-annotated SwiftData entity with AES-GCM encrypted payload field
- `MemoryArchiveNode`: Consolidated semantic summary node with encrypted embedding vector
- Zero-Trust encryption: AES-GCM keys generated in the Secure Enclave via `CryptoKit.SecureEnclave.P256`
- CloudKit End-to-End Encryption sync across iPhone, iPad, and Apple Vision Pro
- `PrivacyInfo.xcprivacy` manifest declaring no external data transmission

#### Phase 3 — On-Device LLM (Weeks 5–6) — _Enterprise_

- `IntelligenceActor`: Network-isolated MLX language model execution on Apple Silicon
- Survival Index algorithm: `SI(t) = S₀ · Rⁿ · e^(-λt)` with configurable decay constant
- Asynchronous batch processing: L1 buffer serialized to JSON → single LLM inference pass
- Automatic pruning of `RawMemoryNode` records below configurable SI threshold

#### Phase 4 — Cognitive Compression (Week 7) — _Enterprise_

- Semantic Consolidation Engine: clusters of aging low-SI nodes merged into a single `MemoryArchiveNode` via LLM-generated natural-language summary
- IoC Compression API: `AuraKit.shared.memory.compressIdleMemories()` — `async throws`, developer-triggered
- `CompressionReport`: result type reporting nodes pruned, archive nodes created, and bytes recovered
- `AsyncStream<MemoryCompressionEvent>` telemetry stream for compression lifecycle events

#### Phase 5 — Metal Search & Release (Week 8)

- Metal Compute Shader (`cosine_similarity.metal`): GPU-accelerated cosine similarity search over all stored memory vectors
- `MTLComputePipelineState`-based search host: < 0.5ms for 1,000 vectors on A17 Pro
- `swift package generate-documentation` — DocC site hosted on GitHub Pages
- Enterprise plugin license validation via JWT, cached in Keychain
- Instruments profiling report: < 1ms main thread overhead per frame confirmed

---

## Version History

| Version | Date           | Summary                                                                           |
| ------- | -------------- | --------------------------------------------------------------------------------- |
| 1.0.0   | Planned Week 8 | Initial open-source release of AuraKit Core + Aura Intelligence Enterprise plugin |

---

[Unreleased]: https://github.com/yourusername/AuraKit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/yourusername/AuraKit/releases/tag/v1.0.0
