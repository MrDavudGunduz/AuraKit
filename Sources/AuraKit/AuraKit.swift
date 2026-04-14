// AuraKit
// On-device, cryptographically secured spatial memory framework.
// https://github.com/yourusername/AuraKit

/// # AuraKit
///
/// AuraKit is an **open-core Swift Package** that provides iOS, macOS, and visionOS
/// applications with a persistent, privacy-first spatial memory layer.
///
/// ## Overview
///
/// AuraKit ingests 3D spatial events (gaze, touch, movement) through a Swift 6
/// Actor-isolated pipeline, scores them using a heuristic bypass engine, and stores
/// them in an on-device AES-GCM encrypted SwiftData store — with no data ever
/// leaving the user's device.
///
/// The Enterprise tier (`Aura Intelligence`) extends this foundation with:
/// - On-device LLM semantic pruning via Apple MLX
/// - Survival Index scoring for intelligent memory longevity
/// - Semantic consolidation (cognitive compression)
/// - GPU-accelerated cosine similarity search via Metal
///
/// ## Quick Start
///
/// Configure AuraKit at app launch:
///
/// ```swift
/// import AuraKit
///
/// let config = AuraConfiguration(
///     interactionWeight: 1.0,
///     gazeWeight: 0.3,
///     bufferCapacity: 512
/// )
/// await AuraKit.shared.configure(with: config)
/// ```
///
/// Record a spatial event:
///
/// ```swift
/// await AuraKit.shared.capture.record(
///     event: .interaction(type: .touch, position: simd_float3(0.1, 0.9, -1.0))
/// )
/// ```
///
/// ## Architecture
///
/// ```
/// CaptureActor → IntelligenceActor (Enterprise) → MemoryActor → Metal Search
/// ```
///
/// For complete architecture documentation, see
/// [ARCHITECTURE.md](https://github.com/yourusername/AuraKit/blob/main/ARCHITECTURE.md).
///
/// ## Topics
///
/// ### Configuration
/// - ``AuraConfiguration``
///
/// ### Capture
/// - ``CaptureActor``
/// - ``SpatialEvent``
/// - ``RingBuffer``
///
/// ### Memory
/// - ``MemoryActor``
/// - ``RawMemoryNode``
/// - ``MemoryArchiveNode``
///
/// ### Intelligence (Enterprise)
/// - ``IntelligenceActor``
/// - ``SurvivalIndex``
/// - ``CompressionReport``
///
/// ### Errors
/// - ``AuraError``
public enum AuraKit {
  /// The current version of the AuraKit framework.
  ///
  /// Follows [Semantic Versioning](https://semver.org).
  public static let version = "1.0.0"
}
