// RingBuffer.swift
// AuraKit — Core Infrastructure
//
// A fixed-capacity, struct-based ring buffer for 60fps SpatialEvent ingestion.
// Designed for zero heap growth after initial allocation — no dynamic resizing,
// no memory leaks across thousands of frames.
//
// ## Performance Note
//
// `RingBuffer` was intentionally designed as a value type (`struct`) rather than
// an `actor` to eliminate actor-hop overhead on the 60fps capture hot path.
// Thread safety is guaranteed by the owning `CaptureActor`, which serialises all
// access through its own actor isolation boundary — making a nested actor
// redundant and wasteful (each hop adds ~1–5µs of scheduling latency).

import Foundation

// MARK: - RingBuffer

/// A fixed-capacity FIFO ring buffer designed for high-frequency event ingestion.
///
/// `RingBuffer` forms the L1 buffer in AuraKit's capture pipeline. It stores
/// low-signal gaze events in a circular fashion: when the buffer is full, the
/// oldest element is silently overwritten by the newest (overflow is lossless
/// from the perspective of recent data).
///
/// ## Memory Contract
///
/// The backing array is allocated once at initialization with a fixed size equal
/// to `capacity`. No further heap allocations occur during the buffer's lifetime,
/// guaranteeing zero memory growth across an arbitrary number of enqueue/dequeue
/// operations.
///
/// ## Thread Safety
///
/// `RingBuffer` is a value type (`struct`) with no internal synchronisation.
/// Thread safety is provided by the owning ``CaptureActor``, which serialises
/// all buffer access through its actor isolation boundary. This design eliminates
/// the per-operation actor-hop overhead that would occur with a nested actor,
/// while maintaining full data-race safety enforced by Swift 6's strict
/// concurrency checker.
///
/// ## Example
///
/// ```swift
/// var buffer = RingBuffer<SpatialEvent>(capacity: 512)
/// buffer.enqueue(event)               // synchronous — no actor hop
/// let events = buffer.drainAll()      // atomically drains all events
/// ```
public struct RingBuffer<Element: Sendable>: Sendable {

  // MARK: - Private State

  /// Pre-allocated fixed-size storage. Elements are wrapped around using modular indexing.
  private var storage: [Element?]

  /// Index at which the next read will occur.
  private var head: Int = 0

  /// Index at which the next write will occur.
  private var tail: Int = 0

  /// Number of valid elements currently stored.
  private var _count: Int = 0

  // MARK: - Properties

  /// The fixed maximum number of elements this buffer can hold.
  public let capacity: Int

  /// The number of elements currently in the buffer.
  public var count: Int { _count }

  /// `true` when the buffer contains no elements.
  public var isEmpty: Bool { _count == 0 }

  /// `true` when the buffer has reached its capacity.
  public var isFull: Bool { _count == capacity }

  // MARK: - Init

  /// Creates a `RingBuffer` with the given fixed capacity.
  ///
  /// - Parameter capacity: Maximum number of elements. Must be > 0.
  ///   If `0` is passed, the capacity is coerced to `1` to prevent
  ///   division-by-zero in the modular arithmetic.
  public init(capacity: Int) {
    let safeCapacity = max(1, capacity)
    self.capacity = safeCapacity
    self.storage = [Element?](repeating: nil, count: safeCapacity)
  }

  // MARK: - Mutations

  /// Enqueues a new element at the tail of the buffer.
  ///
  /// If the buffer is at capacity, the element at the head (oldest) is
  /// silently evicted to make room. No reallocation occurs.
  ///
  /// - Parameter element: The element to enqueue.
  /// - Returns: `true` if the element was enqueued without eviction;
  ///   `false` if an existing element was evicted to make room (overflow).
  @discardableResult
  public mutating func enqueue(_ element: Element) -> Bool {
    let didOverflow = isFull
    if didOverflow {
      // Evict the oldest element by advancing the head pointer.
      head = (head + 1) % capacity
      _count -= 1
    }
    storage[tail] = element
    tail = (tail + 1) % capacity
    _count += 1
    return !didOverflow
  }

  /// Enqueues multiple elements in a single pass.
  ///
  /// Unlike calling ``enqueue(_:)`` in a loop from outside an actor (which
  /// would incur one actor hop per element when `RingBuffer` was an actor),
  /// `batchEnqueue` processes all elements synchronously within a single
  /// call — ideal for burst ingestion scenarios such as ARKit batch frame
  /// updates, where multiple gaze events arrive simultaneously.
  ///
  /// - Parameter elements: The elements to enqueue. Empty arrays are no-ops.
  /// - Returns: The number of elements that caused an overflow eviction.
  ///   A return value of `0` means all elements were enqueued without eviction.
  @discardableResult
  public mutating func batchEnqueue(_ elements: [Element]) -> Int {
    guard !elements.isEmpty else { return 0 }

    var overflowCount = 0
    for element in elements {
      if isFull {
        head = (head + 1) % capacity
        _count -= 1
        overflowCount += 1
      }
      storage[tail] = element
      tail = (tail + 1) % capacity
      _count += 1
    }
    return overflowCount
  }

  /// Removes and returns the oldest element from the buffer.
  ///
  /// - Returns: The oldest element, or `nil` if the buffer is empty.
  @discardableResult
  public mutating func dequeue() -> Element? {
    guard !isEmpty else { return nil }
    let element = storage[head]
    storage[head] = nil  // Release reference to prevent unintended retention
    head = (head + 1) % capacity
    _count -= 1
    return element
  }

  /// Atomically removes and returns all elements currently in the buffer.
  ///
  /// After this call, the buffer is empty and head/tail are reset to `0`.
  /// This is the primary handoff point for batch LLM processing.
  ///
  /// Implementation note: uses a single O(n) forward pass and an atomic
  /// state reset — more efficient than n individual ``dequeue()`` calls.
  ///
  /// - Returns: All buffered elements in FIFO order (oldest first).
  public mutating func drainAll() -> [Element] {
    guard !isEmpty else { return [] }

    var result = [Element]()
    result.reserveCapacity(_count)

    var index = head
    for _ in 0..<_count {
      if let element = storage[index] {
        result.append(element)
      }
      // Clear the slot in the same pass — avoids a separate O(capacity) loop.
      storage[index] = nil
      index = (index + 1) % capacity
    }

    // Reset head/tail pointers — the backing storage retains its allocation.
    head = 0
    tail = 0
    _count = 0

    return result
  }

  /// Returns a snapshot of all current elements without removing them.
  ///
  /// Unlike ``drainAll()``, this is non-destructive. Primarily useful for
  /// debugging and test introspection.
  ///
  /// - Returns: All elements in FIFO order (oldest first).
  public func peek() -> [Element] {
    guard !isEmpty else { return [] }
    var result = [Element]()
    result.reserveCapacity(_count)
    var index = head
    for _ in 0..<_count {
      if let element = storage[index] {
        result.append(element)
      }
      index = (index + 1) % capacity
    }
    return result
  }
}
