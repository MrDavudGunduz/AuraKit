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
  private let buffer: RingBuffer<SpatialEvent>

  /// Stateless routing engine. Determines destination per event kind.
  private let router: HeuristicRouter

  /// Direct memory sink for high-signal interaction events.
  private let store: any SpatialEventStore

  /// The active configuration driving routing weights and buffer sizing.
  private let config: AuraConfiguration

  // MARK: - Init

  /// Creates a `CaptureActor` with the supplied configuration.
  ///
  /// - Parameters:
  ///   - config: The active ``AuraConfiguration``. Captured at init and
  ///     immutable for the lifetime of this actor.
  ///   - store: The backing ``SpatialEventStore`` for high-signal events.
  ///     Defaults to a new in-memory ``MemoryStore``. Inject a Phase 2
  ///     `EncryptedSwiftDataStore` for production persistence.
  public init(config: AuraConfiguration, store: some SpatialEventStore = MemoryStore()) {
    self.config = config
    self.store = store
    self.buffer = RingBuffer<SpatialEvent>(capacity: config.bufferCapacity)
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

    switch decision {
    case .directStore(let score):
      let scored = SpatialEvent(
        id: event.id,
        timestamp: event.timestamp,
        kind: event.kind,
        score: score
      )
      await store.append(scored)

    case .enqueueBuffer(let score):
      let scored = SpatialEvent(
        id: event.id,
        timestamp: event.timestamp,
        kind: event.kind,
        score: score
      )
      await buffer.enqueue(scored)
    }
  }

  /// Drains all L1 ring buffer events and returns them for downstream processing.
  ///
  /// After this call, the ring buffer is empty. In the Enterprise tier, the
  /// returned events are forwarded to `IntelligenceActor` for LLM semantic
  /// pruning and Survival Index scoring.
  ///
  /// - Returns: All buffered gaze events in FIFO order (oldest first).
  public func flush() async -> [SpatialEvent] {
    await buffer.drainAll()
  }

  /// The number of gaze events currently held in the L1 ring buffer.
  ///
  /// Use this for observability and back-pressure monitoring. The value
  /// reflects the state at the time of the async read.
  public var bufferedEventCount: Int {
    get async { await buffer.count }
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
}
