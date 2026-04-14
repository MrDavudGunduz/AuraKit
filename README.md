<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white" alt="Swift 6.0"/>
  <img src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 17+"/>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+"/>
  <img src="https://img.shields.io/badge/visionOS-1%2B-000000?logo=apple&logoColor=white" alt="visionOS 1+"/>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"/>
  <img src="https://img.shields.io/badge/SPM-compatible-brightgreen" alt="SPM Compatible"/>
</p>

<h1 align="center">AuraKit</h1>

<p align="center">
  <strong>On-device, cryptographically secured spatial memory framework for iOS, macOS, and visionOS.</strong><br/>
  Built on Swift 6 Actors, Apple CryptoKit, SwiftData, and Metal — no cloud, no compromise.
</p>

---

## Overview

AuraKit is an **open-core Swift Package** that gives your 3D/spatial applications a persistent, privacy-first memory layer. It captures user interactions (gaze, touch, spatial movement) using a race-free Actor pipeline, scores them with a heuristic bypass engine, stores them in an on-device encrypted SwiftData database, and — in the Enterprise tier — compresses aging memories via an on-device LLM using Apple Silicon MLX.

| Layer        | Technology                    | Description                                 |
| ------------ | ----------------------------- | ------------------------------------------- |
| Capture      | Swift 6 Actors + Ring Buffer  | Race-free 60fps interaction ingestion       |
| Storage      | SwiftData + CryptoKit AES-GCM | Secure Enclave–encrypted persistent store   |
| Sync         | CloudKit E2EE                 | Cross-device memory without server exposure |
| Intelligence | MLX On-Device LLM             | Semantic pruning & memory compression       |
| Search       | Metal Compute Shaders         | GPU-accelerated cosine similarity           |

---

## Feature Matrix

| Feature                                    | AuraKit Core (OSS) | Aura Intelligence (Enterprise) |
| ------------------------------------------ | :----------------: | :----------------------------: |
| Swift 6 Actor capture pipeline             |         ✅         |               ✅               |
| Ring Buffer (60fps, zero leak)             |         ✅         |               ✅               |
| Heuristic Bypass (Touch → max score)       |         ✅         |               ✅               |
| `AuraConfiguration` Dependency Injection   |         ✅         |               ✅               |
| SwiftData `RawMemoryNode` schema           |         ✅         |               ✅               |
| CryptoKit AES-GCM (Secure Enclave)         |         ✅         |               ✅               |
| CloudKit E2EE Sync                         |         ✅         |               ✅               |
| Privacy Manifest (`PrivacyInfo.xcprivacy`) |         ✅         |               ✅               |
| Survival Index scoring algorithm           |         ❌         |               ✅               |
| MLX On-Device LLM sandbox                  |         ❌         |               ✅               |
| Semantic Consolidation (Batch LLM pruning) |         ❌         |               ✅               |
| Inversion of Control (IoC) compress API    |         ❌         |               ✅               |
| Metal Cosine Similarity Search             |         ❌         |               ✅               |

---

## Requirements

- **Xcode 16+** with Swift 6 toolchain
- **iOS 17+** / **macOS 14+** / **visionOS 1+**
- Swift Package Manager

---

## Installation

### Swift Package Manager

Add AuraKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/AuraKit.git", from: "1.0.0")
]
```

Then add `"AuraKit"` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["AuraKit"]
)
```

### Xcode

1. **File → Add Package Dependencies…**
2. Enter the repository URL
3. Select **Up to Next Major Version** from `1.0.0`

---

## Quick Start

### 1. Configure AuraKit

```swift
import AuraKit

// Configure once at app launch (e.g., App.init or AppDelegate)
let config = AuraConfiguration(
    interactionWeight: 1.0,   // Touch/Move → bypasses LLM, goes directly to persistent store
    gazeWeight: 0.3,          // Passive gaze → low-weight L1 buffer
    bufferCapacity: 512       // Ring Buffer frame capacity
)

await AuraKit.shared.configure(with: config)
```

### 2. Capture Spatial Events

```swift
// Feed raycast/gaze data — fully async, Actor-isolated, main-thread safe
await AuraKit.shared.capture.record(
    event: .gaze(position: simd_float3(x: 0.5, y: 1.2, z: -0.8))
)

// Touch/Move events bypass the LLM filter and score 1.0 automatically
await AuraKit.shared.capture.record(
    event: .interaction(type: .touch, position: simd_float3(x: 0.1, y: 0.9, z: -1.0))
)
```

### 3. Query Memories

```swift
// Semantic search via GPU-accelerated cosine similarity (Enterprise)
let memories = try await AuraKit.shared.memory.query(
    context: "Suspect fled through the side door",
    limit: 5
)
```

### 4. Trigger Memory Compression (Enterprise IoC API)

```swift
// Call during loading screens or in-game sleep sessions to avoid FPS drops
try await AuraKit.shared.memory.compressIdleMemories()
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Your Application                  │
└───────────────────────┬─────────────────────────────┘
                        │  AuraConfiguration (DI)
┌───────────────────────▼─────────────────────────────┐
│                  CaptureActor                        │
│   ┌─────────────────────────────────────────────┐   │
│   │   Ring Buffer (60fps, N frames, zero leak)   │   │
│   └──────────┬──────────────────┬───────────────┘   │
│              │ Gaze (low weight) │ Touch/Move (1.0)  │
└──────────────┼──────────────────┼───────────────────┘
               │ L1 Enqueue       │ Heuristic Bypass
┌──────────────▼──────────────────▼───────────────────┐
│              IntelligenceActor (Enterprise)          │
│   MLX LLM Batch Processing → Survival Index Score   │
└──────────────────────────┬──────────────────────────┘
                           │ Prune / Archive
┌──────────────────────────▼──────────────────────────┐
│              MemoryActor                             │
│   SwiftData (AES-GCM encrypted, Secure Enclave)      │
│   RawMemoryNode ◄──────► MemoryArchiveNode           │
└──────────────────────────┬──────────────────────────┘
                           │ CloudKit E2EE
┌──────────────────────────▼──────────────────────────┐
│              Metal Search Layer (Enterprise)         │
│           GPU Cosine Similarity (Shader)             │
└─────────────────────────────────────────────────────┘
```

For detailed architecture documentation, see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## Security & Privacy

AuraKit is designed with a **Zero-Trust, Privacy-First** philosophy:

- All data at rest is encrypted with **AES-GCM** keys generated in the **Secure Enclave**
- Cross-device sync uses **CloudKit End-to-End Encryption** — Apple cannot read your data
- The on-device LLM runs in a **network-isolated MLX sandbox** — no data leaves the device
- A `PrivacyInfo.xcprivacy` manifest declares all data types and confirms no external transmission

See [SECURITY.md](./SECURITY.md) for full details.

---

## Documentation

| Document                             | Description                                                  |
| ------------------------------------ | ------------------------------------------------------------ |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Deep dive into Actor model, Ring Buffer, and data flow       |
| [SECURITY.md](./SECURITY.md)         | Cryptographic design, Secure Enclave, E2EE, Privacy Manifest |
| [ROADMAP.md](./ROADMAP.md)           | 8-week sprint plan, phase deliverables                       |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Contribution guide, PR process, coding standards             |
| [CHANGELOG.md](./CHANGELOG.md)       | Version history                                              |

---

## License

AuraKit **Core** is released under the [MIT License](./LICENSE).  
**Aura Intelligence** (Enterprise features) requires a commercial license. Contact [your@email.com] for details.
