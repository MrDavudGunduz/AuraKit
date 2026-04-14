# Contributing to AuraKit

Thank you for your interest in contributing to AuraKit! This guide covers everything you need to get started, from setting up your development environment to submitting a pull request that passes our review bar.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [What We Accept](#what-we-accept)
- [Development Setup](#development-setup)
- [Swift 6 & Concurrency Rules](#swift-6--concurrency-rules)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Pull Request Process](#pull-request-process)
- [Commit Message Convention](#commit-message-convention)
- [Documentation Standards](#documentation-standards)

---

## Code of Conduct

This project adheres to the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you are expected to uphold this standard.

---

## What We Accept

| Contribution Type                | Status                                 |
| -------------------------------- | -------------------------------------- |
| Bug fixes (Core OSS)             | ✅ Always welcome                      |
| Performance improvements         | ✅ With Instruments benchmark attached |
| New API surface (Core)           | 🔶 Discuss in an Issue first           |
| Documentation improvements       | ✅ No Issue required                   |
| Enterprise feature contributions | ❌ Closed source — contact maintainers |
| New third-party dependencies     | 🔶 Requires strong justification       |

> **Note:** Changes to the public API surface require an associated update to `CHANGELOG.md` and DocC documentation.

---

## Development Setup

### Prerequisites

- **Xcode 16+** with Swift 6 toolchain selected
- **macOS 14+** (Sonoma or later)
- **SwiftLint** (installed automatically as an SPM plugin — no manual installation needed)

### Clone and Build

```bash
git clone https://github.com/yourusername/AuraKit.git
cd AuraKit

# Resolve dependencies
swift package resolve

# Build the package
swift build

# Run all tests
swift test
```

### Open in Xcode

```bash
open Package.swift
```

Xcode will resolve dependencies automatically. Build with **⌘B** to trigger the SwiftLint build plugin.

---

## Swift 6 & Concurrency Rules

AuraKit enforces **Swift 6 Strict Concurrency** across all targets. Every contribution must compile without concurrency warnings.

### Mandatory Rules

1. **No `@unchecked Sendable`** — If a type needs to be `Sendable`, make it genuinely safe or redesign it.
2. **No nonisolated mutable state** — All mutable state belongs inside an `actor`.
3. **No `DispatchQueue` or `NSLock`** — Use `actor` isolation instead.
4. **All public types must declare `Sendable`** conformance explicitly if they cross actor boundaries.
5. **`@MainActor` only for UI** — Do not annotate non-UI types with `@MainActor` for convenience.

### Checking for Warnings

```bash
# Build with all concurrency diagnostics
swift build -Xswiftc -strict-concurrency=complete
```

Pull requests with concurrency warnings will not be merged.

---

## Coding Standards

### SwiftLint

SwiftLint runs automatically as a build plugin. The project enforces the rules defined in `.swiftlint.yml`. Before submitting, confirm your changes introduce no new warnings:

```bash
swift build 2>&1 | grep "warning:"
```

### Style Guide (Key Rules)

| Rule                                       | Example                       |
| ------------------------------------------ | ----------------------------- |
| 4-space indentation (no tabs)              | Standard Xcode default        |
| Opening brace on same line                 | `func foo() {`                |
| `guard` for early exits                    | Avoid deeply nested `if`      |
| `let` over `var` wherever possible         | Immutability by default       |
| Explicit return types on `async` functions | No implicit return inference  |
| No `// MARK: -` abuse                      | Only use for logical sections |
| Maximum line length: 120 characters        | Enforced by SwiftLint         |

### Naming Conventions

```swift
// Types: UpperCamelCase
actor CaptureActor { }
struct AuraConfiguration { }

// Properties and functions: lowerCamelCase
var gazeWeight: Double
func record(event: SpatialEvent) async { }

// Constants: lowerCamelCase (not SCREAMING_SNAKE)
let defaultBufferCapacity = 512

// Protocols: descriptive nouns or adjectives
protocol MemoryStorable { }
protocol SpatialEventEmitting { }
```

---

## Testing Requirements

All new code must include tests. AuraKit uses the **Swift Testing** framework (`import Testing`).

### Test File Structure

```
Tests/AuraKitTests/
├── Capture/
│   ├── CaptureActorTests.swift
│   └── RingBufferTests.swift
├── Memory/
│   ├── MemoryActorTests.swift
│   └── EncryptionTests.swift
└── Configuration/
    └── AuraConfigurationTests.swift
```

### Test Style

```swift
import Testing
@testable import AuraKit

@Suite("RingBuffer")
struct RingBufferTests {

    @Test("overwrites oldest entry when at capacity")
    func overwritesOnFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.write(1); buffer.write(2); buffer.write(3)
        buffer.write(4) // Should overwrite `1`
        #expect(buffer.read() == 2)
    }

    @Test("write and read are O(1)")
    func performanceIsConstant() async throws {
        var buffer = RingBuffer<Int>(capacity: 10_000)
        // Verify no allocation growth during writes
        for i in 0..<10_000 { buffer.write(i) }
        #expect(buffer.count == 10_000)
    }
}
```

### Coverage Requirements

| Area                              | Minimum Coverage |
| --------------------------------- | ---------------- |
| Public API surface                | 90%              |
| Actor state transitions           | 80%              |
| Encryption/decryption round-trips | 100%             |
| Error paths                       | 70%              |

Run coverage report:

```bash
swift test --enable-code-coverage
xcrun llvm-cov report .build/debug/AuraKitPackageTests.xctest/Contents/MacOS/AuraKitPackageTests \
    -instr-profile .build/debug/codecov/default.profdata \
    -ignore-filename-regex ".build"
```

---

## Pull Request Process

### Before Opening a PR

- [ ] `swift build` succeeds with zero warnings (including concurrency)
- [ ] `swift test` passes locally
- [ ] New public APIs are documented with DocC comments
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] Branch name follows convention: `feature/`, `fix/`, `docs/`, `perf/`

### PR Title Convention

```
type(scope): short description

Examples:
feat(capture): add gyroscope event type to SpatialEvent
fix(memory): resolve race condition in MemoryActor.persist
docs(security): clarify Secure Enclave key lifecycle
perf(ring-buffer): reduce branch mispredictions in write path
```

### Review Criteria

PRs are reviewed against three gates:

1. **Correctness** — Does the implementation match the documented behavior?
2. **Concurrency Safety** — Does it compile cleanly under Swift 6 Strict Concurrency?
3. **Performance** — Does it introduce measurable regression? (Attach Instruments snapshot for perf-sensitive changes)

Maintainers aim to provide a first review within **3 business days**.

---

## Commit Message Convention

AuraKit follows [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short description>

[optional body]

[optional footer: BREAKING CHANGE: ...]
```

| Type       | Usage                                      |
| ---------- | ------------------------------------------ |
| `feat`     | New feature                                |
| `fix`      | Bug fix                                    |
| `docs`     | Documentation only                         |
| `perf`     | Performance improvement                    |
| `refactor` | Code restructuring without behavior change |
| `test`     | Adding or updating tests                   |
| `chore`    | Build process, dependency updates          |

---

## Documentation Standards

All public types and methods **must** have DocC documentation:

```swift
/// Records a spatial event into the capture pipeline.
///
/// This method is safe to call from any actor context. Depending on the event type,
/// the event is either enqueued in the L1 Ring Buffer (for gaze) or
/// bypassed directly to the persistent memory store (for touch and move interactions).
///
/// - Parameter event: The ``SpatialEvent`` to record.
/// - Throws: ``AuraError/captureActorUnavailable`` if the actor has been deinitialized.
public func record(event: SpatialEvent) async throws
```

Generate and preview documentation locally:

```bash
swift package --allow-writing-to-directory ./docs \
    generate-documentation --target AuraKit \
    --output-path ./docs \
    --transform-for-static-hosting \
    --hosting-base-path AuraKit
```

---

_Thank you for making AuraKit better. Every contribution matters._
