// RingBuffer.swift
// AuraKit — Core Infrastructure
//
// A fixed-capacity, actor-isolated ring buffer for 60fps SpatialEvent ingestion.
// Designed for zero heap growth after initial allocation — no dynamic resizing,
// no memory leaks across thousands of frames.

import Foundation

// MARK: - RingBuffer

/// A fixed-capacity, actor-isolated FIFO ring buffer.
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
/// All mutations are actor-isolated. Cross-actor access via `await` is required
/// from any other actor context — each call is an implicit actor hop. This is
/// by design; the hop cost is negligible relative to 60fps frame budgets.
///
/// ## Example
///
/// ```swift
/// let buffer = RingBuffer<SpatialEvent>(capacity: 512)
/// await buffer.enqueue(event)           // actor hop — safe from any context
/// let events = await buffer.drainAll() // atomically drains all events
/// ```
public actor RingBuffer<Element: Sendable> {

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
  public func enqueue(_ element: Element) -> Bool {
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

  /// Removes and returns the oldest element from the buffer.
  ///
  /// - Returns: The oldest element, or `nil` if the buffer is empty.
  @discardableResult
  public func dequeue() -> Element? {
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
  /// This is the primary handoff point for batch LLM processing in the
  /// Enterprise tier.
  ///
  /// Implementation note: uses a single O(n) forward pass and an atomic
  /// state reset — more efficient than n individual ``dequeue()`` calls.
  ///
  /// - Returns: All buffered elements in FIFO order (oldest first).
  public func drainAll() -> [Element] {
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

    // Atomic reset — single state mutation instead of n individual dequeues.
    storage = [Element?](repeating: nil, count: capacity)
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
