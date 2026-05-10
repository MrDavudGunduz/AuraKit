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
- `LICENSE` file: MIT license added to repository root (legal compliance)
- `AuraKit.isConfigured`: lightweight state inspection property — avoids the overhead of catching `AuraError.notConfigured` from `capture()`
- `SpatialEvent.score` default value: `score` parameter now defaults to `0` — callers no longer pass a meaningless score that is always overwritten by `HeuristicRouter`

#### Phase 2 — Encrypted Storage & Security Hardening

- `EncryptedMemoryStore`: Actor-isolated SwiftData persistence with AES-GCM encryption via Secure Enclave keys
- `RawMemoryNode`: SwiftData `@Model` entity storing encrypted payloads, scores, timestamps, event types, and recall counters
- `MemoryArchiveNode`: SwiftData `@Model` entity for consolidated semantic memory summaries with source node references
- `KeyManager`: Actor-isolated Secure Enclave key lifecycle manager with HKDF-SHA256 key derivation and Keychain-backed persistence
- `EncryptionService`: Stateless AES-GCM encrypt/decrypt service wrapping CryptoKit
- `PersistenceController`: SwiftData `ModelContainer` factory supporting both persistent and in-memory configurations
- `SpatialEventStore`: Protocol abstraction enabling zero-call-site-modification storage backend swaps
- `EncryptedMemoryStore.events(limit:offset:)`: Paginated query API for large stores — prevents full-table decryption OOM
- `EncryptedMemoryStore.recallAndFetchAll()`: Explicit recall API — fetches all events and increments recall counter for Survival Index
- `EncryptedMemoryStore.recallAndFetch(limit:offset:)`: Paginated recall API with explicit counter increment
- `EncryptedMemoryStore.recalledCount(for:)`: Sendable-safe metadata projection for Survival Index `Rⁿ` parameter
- `RawMemoryNode.recalled`: Integer counter incremented on each read — feeds Phase 3 Survival Index formula
- `PrivacyInfo.xcprivacy`: Privacy Manifest declaring no tracking, no external data transmission
- `Phase2HardeningTests.swift`: Pagination and recall tracking test suite
- `ZeroTrustTests.swift`: Wrong-key tamper detection and ciphertext integrity verification tests

### Changed

- `CaptureActor.init`: auto-constructs `MemoryStore` from `config.storeCapacity` when no explicit store is injected — eliminates capacity inconsistency when using direct `CaptureActor` construction
- `AuraKit.configure(with:)`: simplified to delegate `MemoryStore` construction to `CaptureActor` (single source of truth for store capacity)
- `AuraKit.reset()`: now emits `Logger.info` when tearing down an active pipeline for diagnostics
- `EncryptedMemoryStore.allEvents()`: refactored to **pure read** — no longer increments recall counter. Use `recallAndFetchAll()` for explicit Survival Index recall semantics
- `EncryptedMemoryStore.events(limit:offset:)`: refactored to **pure read** — use `recallAndFetch(limit:offset:)` for recall semantics
- `SpatialEvent.score`: type unified from `Float` to `Double` across the entire pipeline (`AuraConfiguration`, `HeuristicRouter`, `RouteDecision`, `SpatialEvent`) — eliminates implicit widening conversions and precision mismatches with `RawMemoryNode.score`
- `MemoryArchiveNode`: Logger extracted from `@Model` class to external `MemoryArchiveNodeLog` enum — defensive best practice for SwiftData macro compatibility
- `RingBuffer.drainAll()`: merged slot-clearing into the read pass — O(count) instead of O(capacity) for sparse buffers

### Fixed

- **`PersistenceController` force unwrap**: Replaced `cloudKitContainerIdentifier!` with safe `if let` optional binding — eliminates the last force unwrap in the framework
- **`EncryptedMemoryStore` read side effect**: `allEvents()` and `events(limit:offset:)` no longer increment `node.recalled` — read operations are now side-effect-free per the Principle of Least Surprise
- **`EncryptedMemoryStore` DRY violation**: Extracted shared decrypt logic into `decryptNodes()` and `decryptAndRecall()` private helpers
- **`EncryptedMemoryStore` autosave conflict**: Changed `autosaveEnabled` from `true` to `false` — prevents duplicate writes and timing conflicts between SwiftData's autosave and explicit `save()` calls
- **`MemoryArchiveNode` production crash risk**: Replaced `force_try` (`try!`) in `sourceNodeIDs` JSON encoding with defensive `try?` and `os.log` diagnostics — eliminates crash under memory pressure
- **`KeychainHelper` silent write failure**: `store()` now returns `@discardableResult Bool` and logs `OSStatus` errors — all Keychain operations are observable via structured logging
- **`KeychainHelper` logger access violation**: Added dedicated `Logger` instance to `KeychainHelper` enum — previously referenced `KeyManager`'s private logger across access boundaries

### Improved

- `.gitignore`: added `Package.resolved` (SPM library best practice), recursive `.DS_Store` matching, additional IDE state exclusions
- CI pipeline: added release build step, coverage artifact upload (txt + lcov), DocC generation step, `Package.swift`-based cache key
- Test suite: **134 tests across 18 suites** — Thread Sanitizer verified, zero data races
- Documentation: all files updated to reflect Phase 2 completion and current API surface

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

- `RawMemoryNode`: `@Model`-annotated SwiftData entity with AES-GCM encrypted payload, recall counter, and event type metadata
- `MemoryArchiveNode`: Consolidated semantic summary node with encrypted data and source node audit trail
- `EncryptedMemoryStore`: Full-featured encrypted persistence actor with paginated queries and recall tracking
- Zero-Trust encryption: AES-GCM keys generated in the Secure Enclave via `CryptoKit.SecureEnclave.P256`
- CloudKit End-to-End Encryption sync across iPhone, iPad, and Apple Vision Pro
- `PrivacyInfo.xcprivacy` manifest declaring no external data transmission
- Production hardening: zero `force_try`, Keychain diagnostic logging, deterministic save control

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

[Unreleased]: https://github.com/MrDavudGunduz/AuraKit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/MrDavudGunduz/AuraKit/releases/tag/v1.0.0
