# Metal GPU-Accelerated Search

Perform sub-millisecond cosine similarity search across thousands of memory vectors using Metal compute shaders.

## Overview

AuraKit's Metal search engine leverages Apple Silicon GPUs to perform massively parallel cosine similarity computations. A custom `cosine_similarity_kernel` Metal shader processes thousands of embedding vectors simultaneously, delivering search results in under 0.5ms on A17 Pro.

### Architecture

The Metal search pipeline flows through four stages:

```
[Float] query + [[Float]] vectors
    → MTLBuffer upload (CPU → GPU)
        → cosine_similarity_kernel dispatch (GPU parallel compute)
            → MTLBuffer readback (GPU → CPU) → sorted [VectorSearchResult]
```

Each GPU thread computes the cosine similarity between the query vector and a single stored memory vector, enabling true parallel search.

### Performance Characteristics

| Vector Count | Dimension | A17 Pro Latency | A14 Latency |
|-------------|-----------|-----------------|-------------|
| 1,000       | 384       | < 0.5ms         | < 1ms       |
| 10,000      | 384       | < 2ms           | < 5ms       |

### Basic Usage

```swift
import AuraKit

// Prepare embedding vectors
let queryEmbedding: [Float] = /* 384-dimensional embedding */
let storedEmbeddings: [[Float]] = /* Memory vector database */
let storedIDs: [UUID] = /* Corresponding memory node IDs */

// Perform GPU-accelerated search
let results = try await AuraKit.shared.memory.searchSimilarMemories(
    queryVector: queryEmbedding,
    vectors: storedEmbeddings,
    ids: storedIDs,
    topK: 5
)

// Process results (sorted by descending similarity)
for result in results {
    print("\(result.id): similarity = \(result.similarity)")
}
```

### Custom Configuration

Configure the Metal search engine for your specific embedding model:

```swift
let config = try MetalSearchConfiguration(
    vectorDimension: 768,    // Match your embedding model's output
    maxVectorCount: 50_000,  // Support larger vector databases
    threadgroupSize: 256     // Optimal for Apple Silicon
)

let results = try await AuraKit.shared.memory.searchSimilarMemories(
    queryVector: queryEmbedding,
    vectors: storedEmbeddings,
    ids: storedIDs,
    topK: 10,
    config: config
)
```

### Direct Engine Access

For advanced use cases, create and manage a ``MetalSearchEngine`` directly:

```swift
let engine = try MetalSearchEngine(config: .default)

// Reuse the engine for multiple searches
let results1 = try await engine.search(
    query: embedding1, vectors: database, ids: ids, topK: 5
)
let results2 = try await engine.search(
    query: embedding2, vectors: database, ids: ids, topK: 5
)
```

### Platform Availability

Metal compute shaders require:
- iOS 17+ (A14 Bionic or later)
- macOS 14+ (Apple Silicon or compatible GPU)
- visionOS 1+ (M2 chip)

On platforms where Metal is unavailable (e.g., Linux CI), ``MetalSearchEngine`` throws ``AuraError/metalUnavailable(reason:)`` at initialisation.

### Instruments Profiling

Metal search intervals are visible in **Instruments → os_signpost**:

| Signpost Name   | Location | Metadata |
|-----------------|----------|----------|
| `MetalSearch`   | ``MetalSearchEngine/search(query:vectors:ids:topK:)`` | `vectorCount` |

Use **Metal GPU Frame Capture** in Instruments to inspect shader occupancy and dispatch latency.

## Topics

### Search Engine

- ``MetalSearchEngine``

### Results

- ``VectorSearchResult``

### Configuration

- ``MetalSearchConfiguration``

### Errors

- ``AuraError/metalUnavailable(reason:)``
- ``AuraError/vectorSearchFailed(reason:)``
