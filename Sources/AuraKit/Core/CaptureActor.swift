// CaptureActor.swift
// AuraKit — Phase 1: Core Infrastructure
//
// The primary public surface for all 3D spatial event ingestion.
// Orchestrates HeuristicRouter → RingBuffer (gaze) or SpatialEventStore (interaction).
// Fully Swift 6 compliant: no shared mutable state, no concurrency warnings.

import Foundation

// MARK: - CaptureActor

/// The main actor-isolated ingestion point for 3D spatial events.
///
/// `CaptureActor` orchestrates the full event lifecycle from raw sensor input
/// to routed storage:
///
/// ```
/// record(event:)
///   └─ HeuristicRouter.route(_:config:)
///         ├─ .directStore  → SpatialEventStore.append(_:)   [interaction events]
///         └─ .enqueueBuffer → RingBuffer.enqueue(_:)          [gaze events]
/// ```
///
/// ## Concurrency Model
///
/// `CaptureActor` is marked `public actor`, providing full Swift 6 actor
/// isolation. All mutable state is accessed exclusively through actor hops
/// — zero shared mutable state, zero data races.
///
/// ## Dependency Injection
///
/// The persistence layer is injected as a ``SpatialEventStore`` protocol, not
/// a concrete type. This enables Phase 2 to swap in an AES-GCM encrypted
/// SwiftData store without changing any call site:
///
/// ```swift
/// let actor = CaptureActor(config: config, store: EncryptedSwiftDataStore())
/// ```
///
/// ## Usage
///
/// ```swift
/// // Obtained via AuraKit.shared.capture() after configuration
/// let capture = CaptureActor(config: config)
///
/// // Safe to call from concurrent tasks:
/// await capture.record(event: .init(kind: .interaction(type: .touch, position: .zero), score: 0))
///
/// // Drain the L1 buffer for LLM batch processing:
/// let gazeEvents = await capture.flush()
/// ```
public actor CaptureActor {

  // MARK: - Private Components

  /// L1 ring buffer for low-signal gaze events awaiting LLM processing.
  ///
  /// Stored as `var` because `RingBuffer` is a value type (`struct`) with
  /// `mutating` methods. Actor isolation guarantees exclusive access — no
  /// data races are possible despite the mutable binding.
  private var buffer: RingBuffer<SpatialEvent>

  /// Stateless routing engine. Determines destination per event kind.
  private let router: HeuristicRouter

  /// Direct memory sink for high-signal interaction events.
  ///
  /// Exposed as `internal` to allow ``MemoryManager`` to access the store
  /// for compression queries. Actor isolation ensures thread safety.
  let store: any SpatialEventStore

  /// The active configuration driving routing weights and buffer sizing.
  private let config: AuraConfiguration

  /// The intelligence actor for LLM evaluation and cognitive compression.
  ///
  /// Lazily initialized on first access — avoids paying the construction
  /// cost when the host application never uses compression or evaluation.
  private var _intelligenceActor: IntelligenceActor?

  /// The intelligence actor for LLM operations including cognitive compression.
  ///
  /// Lazily creates an ``IntelligenceActor`` configured with this capture's
  /// configuration and backing store. Used by ``MemoryManager`` for compression.
  ///
  /// - Parameter modelProvider: Optional model provider override (for testing).
  /// - Returns: The shared ``IntelligenceActor`` instance for this capture pipeline.
  public func intelligenceActor(
    modelProvider: (any MLXModelProvider)? = nil
  ) -> IntelligenceActor {
    if let existing = _intelligenceActor {
      return existing
    }
    let actor = IntelligenceActor(
      config: config,
      store: store,
      modelProvider: modelProvider
    )
    _intelligenceActor = actor
    return actor
  }

  // MARK: - Init

  /// Creates a `CaptureActor` with the supplied configuration.
  ///
  /// - Parameters:
  ///   - config: The active ``AuraConfiguration``. Captured at init and
  ///     immutable for the lifetime of this actor.
  ///   - store: The backing ``SpatialEventStore`` for high-signal events.
  ///     When omitted, a new ``MemoryStore`` is created using
  ///     `config.storeCapacity` — ensuring capacity consistency between
  ///     the configuration and the store. Inject a Phase 2
  ///     `EncryptedSwiftDataStore` for production persistence.
  public init(config: AuraConfiguration, store: (any SpatialEventStore)? = nil) {
    self.config = config
    self.store = store ?? MemoryStore(capacity: config.storage.capacity)
    self.buffer = RingBuffer<SpatialEvent>(capacity: config.capture.bufferCapacity)
    self.router = HeuristicRouter()
  }

  // MARK: - Public API

  /// Records a raw ``SpatialEvent`` through the capture pipeline.
  ///
  /// The event is routed synchronously by the ``HeuristicRouter``:
  /// - **Interaction** → score is set, event is written directly to ``SpatialEventStore``
  /// - **Gaze** → score is set, event is enqueued in the L1 ``RingBuffer``
  ///
  /// This method is designed for 60fps call frequency. The routing
  /// decision itself is **allocation-free and synchronous** (`HeuristicRouter.route` has no
  /// async work); only the terminal storage writes carry actor-hop cost.
  ///
  /// - Parameter event: The raw event from the sensor pipeline. The
  ///   `score` field will be **overwritten** by the router's decision.
  public func record(event: SpatialEvent) async {
    let decision = router.route(event, config: config)

    // Single-pass: extract score, build the scored copy, and route — no redundant branching.
    switch decision {
    case .directStore(let score):
      await store.append(event.withScore(score))

    case .enqueueBuffer(let score):
      buffer.enqueue(event.withScore(score))
    }
  }

  /// Records multiple events through the capture pipeline in a single batch.
  ///
  /// Events are routed synchronously by the ``HeuristicRouter``, then:
  /// - **Interaction events** → collected and written via ``SpatialEventStore/batchAppend(_:)``
  ///   (single `save()` for all store-bound events)
  /// - **Gaze events** → collected and written via ``RingBuffer/batchEnqueue(_:)``
  ///   (single actor hop for all buffer-bound events)
  ///
  /// Use this for burst ingestion scenarios where multiple sensor frames are
  /// available simultaneously (e.g., ARKit batch updates, replay pipelines).
  ///
  /// - Parameter events: The raw events from the sensor pipeline. The `score`
  ///   field on each event will be **overwritten** by the router's decision.
  public func recordBatch(events: [SpatialEvent]) async {
    guard !events.isEmpty else { return }

    var storeEvents: [SpatialEvent] = []
    var bufferEvents: [SpatialEvent] = []
    storeEvents.reserveCapacity(events.count)
    bufferEvents.reserveCapacity(events.count)

    for event in events {
      let decision = router.route(event, config: config)

      switch decision {
      case .directStore(let score):
        storeEvents.append(event.withScore(score))

      case .enqueueBuffer(let score):
        bufferEvents.append(event.withScore(score))
      }
    }

    // Batch-enqueue all buffer-bound events in a single synchronous pass
    if !bufferEvents.isEmpty {
      buffer.batchEnqueue(bufferEvents)
    }

    // Batch-insert all store-bound events in a single save
    if !storeEvents.isEmpty {
      await store.batchAppend(storeEvents)
    }
  }

  /// Drains all L1 ring buffer events and returns them for downstream processing.
  ///
  /// After this call, the ring buffer is empty. The returned events are
  /// forwarded to `IntelligenceActor` for LLM semantic pruning and
  /// Survival Index scoring.
  ///
  /// - Returns: All buffered gaze events in FIFO order (oldest first).
  public func flush() -> [SpatialEvent] {
    buffer.drainAll()
  }

  /// The number of gaze events currently held in the L1 ring buffer.
  ///
  /// Use this for observability and back-pressure monitoring. The value
  /// reflects the state at the time of the async read.
  public var bufferedEventCount: Int {
    buffer.count
  }

  /// A snapshot of all high-signal events in the persistent memory store.
  ///
  /// Primarily for debugging and test introspection. In production, consumers
  /// should query the `MemoryActor` (Phase 2) rather than reaching into the
  /// capture layer.
  public func persistedEvents() async -> [SpatialEvent] {
    await store.allEvents()
  }

  /// Total number of high-signal events written to persistent memory.
  public var persistedEventCount: Int {
    get async { await store.count }
  }

  // MARK: - Lifecycle

  /// Drains all L1 ring buffer events and writes them to the persistent store.
  ///
  /// Unlike ``flush()``, which returns events for external processing,
  /// `flushToStore()` writes all buffered gaze events directly to the
  /// backing ``SpatialEventStore`` — ensuring no data loss during
  /// pipeline teardown or graceful shutdown.
  ///
  /// Events are written as a single batch via ``SpatialEventStore/batchAppend(_:)``,
  /// minimising I/O operations. After the batch write, any pending coalesced
  /// inserts from prior individual `append()` calls are also flushed via
  /// ``SpatialEventStore/flushPendingWrites()`` — guaranteeing zero data loss.
  ///
  /// - Returns: The number of events flushed to the store.
  @discardableResult
  public func flushToStore() async -> Int {
    let events = buffer.drainAll()
    if !events.isEmpty {
      await store.batchAppend(events)
    }

    // Flush any coalesced writes from prior individual append() calls.
    // Without this, the last (saveThreshold - 1) events could be lost
    // during pipeline teardown when using EncryptedMemoryStore with
    // write coalescing enabled.
    await store.flushPendingWrites()

    return events.count
  }

  // MARK: - Security

  /// Clears sensitive data (like cached encryption keys) in the underlying persistent store.
  /// Called automatically by `AuraKitLifecycleObserver` when the app moves to the background.
  public func clearSensitiveDataForBackground() async {
    await store.clearSensitiveDataForBackground()
  }
}
