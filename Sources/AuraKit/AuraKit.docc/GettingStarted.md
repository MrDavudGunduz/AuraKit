# Getting Started with AuraKit

Integrate AuraKit into your spatial application in minutes.

## Overview

AuraKit captures, encrypts, and persists spatial interactions — gaze, touch, movement — with zero data ever leaving the device. This guide walks through the essential integration steps.

## Add the Package

Add AuraKit as a Swift Package Manager dependency:

```swift
dependencies: [
    .package(url: "https://github.com/AuraKit/AuraKit.git", from: "1.0.0")
]
```

Then add `AuraKit` to your target's dependencies:

```swift
.target(name: "MyApp", dependencies: ["AuraKit"])
```

## Configure AuraKit

Configure AuraKit once at app launch. The ``AuraConfiguration`` struct controls buffer sizes, scoring weights, and storage behaviour:

```swift
import AuraKit

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    let config = try! AuraConfiguration(
                        interactionWeight: 1.0,
                        gazeWeight: 0.3,
                        bufferCapacity: 512,
                        storeCapacity: 10_000
                    )
                    AuraKit.shared.configure(with: config)
                }
        }
    }
}
```

> Important: ``AuraKit/shared`` is `@MainActor`-isolated. Call ``AuraKit/configure(with:)`` from the main actor context (e.g., a `.task` modifier or `@MainActor` method).

## Record Spatial Events

Use the ``CaptureActor`` to record events from any async context:

```swift
let capture = try AuraKit.capture()

// Record a touch interaction
let touch = SpatialEvent(
    kind: .interaction(type: .touch, position: CodableSIMD3(x: 0.5, y: 1.2, z: -0.8)),
    score: 1.0
)
await capture.record(event: touch)

// Record a gaze sample
let gaze = SpatialEvent(
    kind: .gaze(position: CodableSIMD3(x: 0.1, y: 0.9, z: -1.0)),
    score: 0.3
)
await capture.record(event: gaze)
```

### Event Routing

AuraKit's ``HeuristicRouter`` automatically routes events based on their type:

| Event Type | Route | Destination |
|-----------|-------|-------------|
| Touch, Move, Pinch, Drag | ``RouteDecision/directStore(score:)`` | Immediate encrypted persistence |
| Gaze | ``RouteDecision/enqueueBuffer(score:)`` | Ring buffer for batch processing |

## Query Stored Events

Retrieve decrypted events from the persistent store:

```swift
let capture = try AuraKit.capture()

// Fetch all events (pure read — no side effects)
let allEvents = await capture.persistedEvents()

// Fetch paginated results
let page = await capture.persistedEvents(limit: 50, offset: 100)
```

## Use Encrypted Storage (Phase 2)

For production deployments, use ``EncryptedMemoryStore`` with Secure Enclave–derived keys:

```swift
let container = try PersistenceController.makeContainer()
let store = EncryptedMemoryStore(container: container)

let config = try AuraConfiguration(bufferCapacity: 512, storeCapacity: 10_000)
let capture = CaptureActor(config: config, store: store)
```

All events are automatically encrypted with AES-GCM before touching disk.

## Monitor Store Health

Track write success rates and detect silent data loss:

```swift
let metrics = await store.metrics
print("Written: \(metrics.totalEventsWritten)")
print("Dropped: \(metrics.droppedEventCount)")
print("Success Rate: \(metrics.writeSuccessRate)%")

// Subscribe to real-time drop notifications
Task {
    for await drop in store.droppedEventStream {
        logger.error("Event dropped: \(drop.reason)")
    }
}
```

## Topics

### Essential Types

- ``AuraKit``
- ``AuraConfiguration``
- ``CaptureActor``
- ``SpatialEvent``

### Storage

- ``EncryptedMemoryStore``
- ``MemoryStore``
- ``PersistenceController``
