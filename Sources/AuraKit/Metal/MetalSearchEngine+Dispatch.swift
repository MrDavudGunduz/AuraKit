// MetalSearchEngine+Dispatch.swift
// AuraKit — Metal GPU-Accelerated Search
//
// Buffer allocation, shader compilation, compute kernel dispatch, and
// top-K partial selection for MetalSearchEngine.
// Extracted from MetalSearchEngine.swift for file-length and single-responsibility
// compliance while remaining within the actor's isolation domain.

#if canImport(Metal)
import Metal
#endif
import Foundation
import os.log

// MARK: - MetalSearchEngine + Compute Dispatch & Top-K Selection

extension MetalSearchEngine {

  #if canImport(Metal)

  /// Loads the precompiled `default.metallib` if present, falling back to
  /// runtime compilation of the bundled `cosine_similarity.metal` source.
  static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    if let precompiled = try? device.makeDefaultLibrary(bundle: Bundle.module) {
      return precompiled
    }
    if let shaderURL = Bundle.module.url(forResource: "cosine_similarity", withExtension: "metal"),
       let source = try? String(contentsOf: shaderURL, encoding: .utf8),
       let compiled = try? device.makeLibrary(source: source, options: nil) {
      return compiled
    }
    throw AuraError.metalUnavailable(
      reason: "Failed to load or compile Metal shader library from Bundle.module."
    )
  }

  /// Clamps vector count to `config.maxVectorCount`, logging a warning on truncation.
  func clampVectorCount(_ count: Int) -> Int {
    if count > config.maxVectorCount {
      Self.logger.warning(
        """
        [AuraKit] MetalSearchEngine: \(count) vectors exceed \
        maxVectorCount \(self.config.maxVectorCount) — only the first \
        \(self.config.maxVectorCount) are searched.
        """
      )
    }
    return min(count, config.maxVectorCount)
  }

  /// Validates the search input parameters.
  func validateSearchInputs(
    query: [Float],
    vectors: [[Float]],
    ids: [UUID]
  ) throws {
    guard query.count == config.vectorDimension else {
      throw AuraError.vectorSearchFailed(
        reason: "Query vector dimension \(query.count) does not match "
          + "configured dimension \(config.vectorDimension)."
      )
    }
    guard vectors.count == ids.count else {
      throw AuraError.vectorSearchFailed(
        reason: "Vector count (\(vectors.count)) does not match ID count (\(ids.count))."
      )
    }
  }

  /// Flattens 2D vectors into a contiguous 1D float array for GPU upload.
  func flattenVectors(
    _ vectors: [[Float]],
    count vectorCount: Int
  ) throws -> [Float] {
    let dimension = config.vectorDimension
    var flat = [Float]()
    flat.reserveCapacity(vectorCount * dimension)

    for idx in 0..<vectorCount {
      let vec = vectors[idx]
      guard vec.count == dimension else {
        throw AuraError.vectorSearchFailed(
          reason: "Memory vector at index \(idx) has dimension \(vec.count), "
            + "expected \(dimension)."
        )
      }
      flat.append(contentsOf: vec)
    }
    return flat
  }

  /// Creates Metal buffers, dispatches the compute kernel, and returns raw similarity scores.
  func dispatchComputeKernel(
    query: [Float],
    flatVectors: [Float],
    vectorCount: Int
  ) async throws -> [Float] {
    let dimension = config.vectorDimension
    let buffers = try createMetalBuffers(
      query: query,
      flatVectors: flatVectors,
      vectorCount: vectorCount,
      dimension: dimension
    )

    try await encodeAndSubmit(buffers: buffers, vectorCount: vectorCount)

    return readBackResults(
      from: buffers.results,
      count: vectorCount
    )
  }

  /// Allocates the four Metal buffers required by the cosine similarity kernel.
  func createMetalBuffers(
    query: [Float],
    flatVectors: [Float],
    vectorCount: Int,
    dimension: Int
  ) throws -> MetalBuffers {
    guard let queryBuf = device.makeBuffer(
      bytes: query,
      length: dimension * MemoryLayout<Float>.stride,
      options: .storageModeShared
    ) else {
      throw AuraError.vectorSearchFailed(reason: "Failed to create query MTLBuffer.")
    }

    guard let memoryBuf = device.makeBuffer(
      bytes: flatVectors,
      length: vectorCount * dimension * MemoryLayout<Float>.stride,
      options: .storageModeShared
    ) else {
      throw AuraError.vectorSearchFailed(reason: "Failed to create memory vectors MTLBuffer.")
    }

    guard let resultsBuf = device.makeBuffer(
      length: vectorCount * MemoryLayout<Float>.stride,
      options: .storageModeShared
    ) else {
      throw AuraError.vectorSearchFailed(reason: "Failed to create results MTLBuffer.")
    }

    var params = (UInt32(dimension), UInt32(vectorCount))
    guard let paramsBuf = device.makeBuffer(
      bytes: &params,
      length: MemoryLayout.size(ofValue: params),
      options: .storageModeShared
    ) else {
      throw AuraError.vectorSearchFailed(reason: "Failed to create params MTLBuffer.")
    }

    return MetalBuffers(
      query: queryBuf,
      memory: memoryBuf,
      results: resultsBuf,
      params: paramsBuf
    )
  }

  /// Encodes the compute command and submits it to the GPU.
  ///
  /// Completion is awaited via `addCompletedHandler` + a checked continuation
  /// instead of `waitUntilCompleted()`, which would block a Swift Concurrency
  /// cooperative-pool thread for the full GPU round-trip.
  func encodeAndSubmit(buffers: MetalBuffers, vectorCount: Int) async throws {
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw AuraError.vectorSearchFailed(
        reason: "Failed to create Metal command buffer or encoder."
      )
    }

    encoder.setComputePipelineState(pipelineState)
    encoder.setBuffer(buffers.query, offset: 0, index: 0)
    encoder.setBuffer(buffers.memory, offset: 0, index: 1)
    encoder.setBuffer(buffers.results, offset: 0, index: 2)
    encoder.setBuffer(buffers.params, offset: 0, index: 3)

    let tgSize = MTLSize(
      width: min(config.threadgroupSize, pipelineState.maxTotalThreadsPerThreadgroup),
      height: 1,
      depth: 1
    )
    encoder.dispatchThreads(
      MTLSize(width: vectorCount, height: 1, depth: 1),
      threadsPerThreadgroup: tgSize
    )
    encoder.endEncoding()

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
  }

  /// Reads raw float similarity scores back from the GPU results buffer.
  func readBackResults(from buffer: MTLBuffer, count: Int) -> [Float] {
    let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
    return Array(UnsafeBufferPointer(start: pointer, count: count))
  }

  #endif

  /// Pairs raw similarity scores with UUIDs and extracts the top-K results in O(N + K log K).
  func buildSortedResults(
    similarities: [Float],
    ids: [UUID],
    topK: Int
  ) -> [VectorSearchResult] {
    let count = min(similarities.count, ids.count)
    guard count > 0, topK > 0 else { return [] }

    Self.logger.info(
      "[AuraKit] MetalSearchEngine: Search completed — \(count) vectors, top-\(topK) returned."
    )

    guard topK < count else {
      return (0..<count)
        .map { VectorSearchResult(id: ids[$0], similarity: similarities[$0]) }
        .sorted()
    }

    var heap = (0..<topK).map { VectorSearchResult(id: ids[$0], similarity: similarities[$0]) }
    heap.sort { $0.similarity < $1.similarity }

    for idx in topK..<count where similarities[idx] > heap[0].similarity {
      heap[0] = VectorSearchResult(id: ids[idx], similarity: similarities[idx])
      Self.siftDownMinHeap(&heap, from: 0)
    }
    return heap.sorted()
  }

  /// Sifts the root element down in a min-heap ordered by ascending `.similarity`.
  private nonisolated static func siftDownMinHeap(
    _ heap: inout [VectorSearchResult],
    from index: Int
  ) {
    let count = heap.count
    var parent = index
    while true {
      let left = 2 * parent + 1
      let right = 2 * parent + 2
      var smallest = parent
      if left < count, heap[left].similarity < heap[smallest].similarity { smallest = left }
      if right < count, heap[right].similarity < heap[smallest].similarity { smallest = right }
      if smallest == parent { break }
      heap.swapAt(parent, smallest)
      parent = smallest
    }
  }
}

// MARK: - MetalBuffers

#if canImport(Metal)
/// Internal container for the four MTLBuffers used by a single search dispatch.
///
/// Groups the query, memory, results, and params buffers into a single
/// value to reduce parameter passing between helper methods.
struct MetalBuffers {
  let query: MTLBuffer
  let memory: MTLBuffer
  let results: MTLBuffer
  let params: MTLBuffer
}
#endif

