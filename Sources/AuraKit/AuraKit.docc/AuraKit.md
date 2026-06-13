# ``AuraKit``

On-device, cryptographically secured spatial memory framework for iOS, macOS, and visionOS.

## Overview

AuraKit provides a persistent, privacy-first memory layer for 3D and spatial applications. It captures user interactions (gaze, touch, spatial movement) through a Swift 6 Actor-isolated pipeline, scores them with a heuristic bypass engine, and stores them in an on-device AES-GCM encrypted SwiftData database.

No data ever leaves the user's device. All encryption keys are derived from the Secure Enclave.

### Architecture

AuraKit's data pipeline flows through four isolated layers:

```
CaptureActor → IntelligenceActor → MemoryActor → Metal Search
```

- **Capture Layer**: Ingests 60fps spatial events through ``CaptureActor``, routing high-signal interactions directly to persistent memory while queuing gaze events in a ``RingBuffer`` for batch LLM processing.
- **Intelligence Layer**: Evaluates buffered events using an on-device LLM (Apple MLX) and produces Survival Index scores. *(Phase 3)*
- **Memory Layer**: Encrypts and persists events via ``EncryptedMemoryStore`` using AES-GCM with Secure Enclave–derived keys.
- **Search Layer**: GPU-accelerated cosine similarity search via Metal compute shaders. *(Phase 4)*

### Quick Start

Configure AuraKit once at app launch:

```swift
import AuraKit

// In your App's .task modifier (runs on @MainActor)
let config = try AuraConfiguration(
    interactionWeight: 1.0,
    gazeWeight: 0.3,
    bufferCapacity: 512
)
AuraKit.shared.configure(with: config)

// Record spatial events from any async context
let capture = try AuraKit.capture()
await capture.record(event: .touch(at: SIMD3(0.1, 0.9, -1.0)))
```

### Security Model

AuraKit follows a **Zero-Trust, Privacy-First** philosophy:

| Threat | Mitigation |
|---|---|
| Data at rest | AES-GCM encryption with Secure Enclave keys |
| Key extraction | Private key never leaves Secure Enclave hardware |
| Cloud exposure | CloudKit End-to-End Encryption |
| On-device AI | Network-isolated MLX sandbox |

## Topics

### Configuration

- ``AuraConfiguration``

### Capture Pipeline

- ``CaptureActor``
- ``SpatialEvent``
- ``SpatialEventKind``
- ``InteractionType``
- ``RingBuffer``
- ``HeuristicRouter``
- ``RouteDecision``

### Storage

- ``SpatialEventStore``
- ``MemoryStore``
- ``EncryptedMemoryStore``
- ``StoreMetrics``

### Persistence

- ``RawMemoryNode``
- ``MemoryArchiveNode``
- ``PersistenceController``
- ``SpatialEventType``
- ``AuraKitSchemaV1``
- ``AuraKitSchemaV2``
- ``AuraKitMigrationPlan``

### Security

- ``KeyManager``
- ``EncryptionService``

### Utilities

- ``SignpostLogger``
- ``CodableSIMD3``

### Errors

- ``AuraError``
