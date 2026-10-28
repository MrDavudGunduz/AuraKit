// AuraKitLifecycleObserver.swift
// AuraKit — Utilities
//
// Application lifecycle observer for automatic background write-flushing
// and security key clearing.

import Foundation
import os.log

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - AuraKitLifecycleObserver

/// Automatically monitors application lifecycle state transitions to guarantee zero data loss
/// and minimize key exposure in background states.
///
/// ## Features
///
/// 1. **Zero Data Loss:** When the application enters the background or terminates,
///    pending coalesced writes in ``EncryptedMemoryStore`` are automatically flushed to disk
///    under an expiring-activity assertion so the process is not suspended mid-flush.
/// 2. **Security Hardening:** When moving to the background, cached symmetric keys in ``KeyManager``
///    are cleared from process memory, forcing re-derivation from the Secure Enclave on return.
///
/// ## Usage
///
/// Enable automatic lifecycle monitoring at application launch:
///
/// ```swift
/// AuraKit.shared.startLifecycleObserver()
/// ```
@MainActor
public final class AuraKitLifecycleObserver {

  private nonisolated static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "AuraKitLifecycleObserver"
  )

  /// Shared instance for app lifecycle tracking.
  public static let shared = AuraKitLifecycleObserver()

  private var isObserving: Bool = false

  private init() {}

  /// Starts listening for application lifecycle notifications.
  ///
  /// Observed transitions:
  /// - iOS / visionOS: `didEnterBackground` and `willTerminate`.
  ///   `willResignActive` is intentionally **not** observed — it fires for
  ///   transient interruptions (Control Center, notification banners, Face ID
  ///   prompts, app switcher peeks), which would needlessly flush and force a
  ///   Secure Enclave key re-derivation on every glance.
  /// - macOS: `didHide` and `willTerminate` (a Mac app never "backgrounds";
  ///   resign-active fires on every window switch).
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  public func startObserving() {
    guard !isObserving else { return }
    isObserving = true

    #if canImport(UIKit)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleBackgroundTransition),
        name: UIApplication.didEnterBackgroundNotification,
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleTermination),
        name: UIApplication.willTerminateNotification,
        object: nil
      )
    #elseif canImport(AppKit)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleBackgroundTransition),
        name: NSApplication.didHideNotification,
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleTermination),
        name: NSApplication.willTerminateNotification,
        object: nil
      )
    #endif

    Self.logger.info("[AuraKit] Lifecycle observer active.")
  }

  /// Stops listening for application lifecycle notifications.
  public func stopObserving() {
    guard isObserving else { return }
    isObserving = false
    NotificationCenter.default.removeObserver(self)
    Self.logger.info("[AuraKit] Lifecycle observer stopped.")
  }

  /// Maximum time the background assertion waits for the flush.
  nonisolated static let backgroundFlushTimeout: DispatchTimeInterval = .seconds(25)

  /// Maximum time termination is delayed while the flush completes.
  ///
  /// iOS grants roughly five seconds to `willTerminate` handlers; staying well
  /// below that avoids the watchdog killing the process mid-write.
  nonisolated static let terminationFlushTimeout: DispatchTimeInterval = .seconds(3)

  @objc private func handleBackgroundTransition() {
    beginBackgroundFlush(capture: AuraKit.shared.captureOrNil)
  }

  @objc private func handleTermination() {
    let done = DispatchSemaphore(value: 0)
    startFlush(capture: AuraKit.shared.captureOrNil, signalling: done)

    // The process exits as soon as this handler returns, so a bounded
    // synchronous wait is the only way to let the flush finish. This cannot
    // deadlock: the flush runs on the cooperative pool, not the main actor.
    Self.wait(for: done, timeout: Self.terminationFlushTimeout, context: "Termination")
  }

  /// Starts the background flush under a process assertion and returns
  /// immediately — the calling (main) thread is never blocked.
  ///
  /// - Parameter capture: The pipeline to flush, or `nil` if not configured.
  /// - Returns: The flush task; await its `value` to observe completion.
  @discardableResult
  func beginBackgroundFlush(capture: CaptureActor?) -> Task<Void, Never> {
    let reason = "AuraKit: flush encrypted writes and clear key material"
    let done = DispatchSemaphore(value: 0)
    let task = startFlush(capture: capture, signalling: done)

    // Without an assertion the process can be suspended mid-flush, losing the
    // coalesced writes and leaving the key cached. The wait always happens on
    // a background queue.
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      // `performExpiringActivity` works in apps *and* extensions (unlike
      // `UIApplication.beginBackgroundTask`) and invokes its block on a
      // background queue.
      ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
        guard !expired else { return }
        Self.wait(for: done, timeout: Self.backgroundFlushTimeout, context: "Background transition")
      }
    #elseif os(macOS)
      // `performActivity(options:reason:using:)` runs its block *synchronously*
      // on the calling thread. Invoking it from the main thread (as a previous
      // version did) blocked the main actor that the flush needed — a 25 s hang
      // on every hide. Run the synchronous assertion wait in a detached task.
      Task.detached(priority: .userInitiated) {
        ProcessInfo.processInfo.performActivity(options: .userInitiated, reason: reason) {
          Self.wait(
            for: done, timeout: Self.backgroundFlushTimeout, context: "Background transition")
        }
      }
    #endif
    return task
  }

  /// Starts the flush-then-wipe sequence **off the main actor** and signals
  /// `done` when it finishes.
  @discardableResult
  private func startFlush(
    capture: CaptureActor?,
    signalling done: DispatchSemaphore
  ) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
      if let capture {
        await Self.flushAndSecure(capture)
      }
      done.signal()
    }
  }

  /// Flushes buffered and coalesced writes, then clears cached key material.
  ///
  /// The order matters: the flush needs the key to encrypt.
  nonisolated static func flushAndSecure(_ capture: CaptureActor) async {
    let flushed = await capture.flushToStore()
    logger.info("[AuraKit] Lifecycle: Flushed \(flushed) events to store.")
    await capture.clearSensitiveDataForBackground()
    logger.info("[AuraKit] Lifecycle: Cleared sensitive data.")
  }

  private nonisolated static func wait(
    for semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval,
    context: StaticString
  ) {
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
      logger.error("[AuraKit] \(context): flush did not finish before timeout.")
    }
  }
}

extension AuraKit {

  /// Starts the automatic application lifecycle observer for background state protection.
  ///
  /// Call this at app startup from a `@MainActor` context.
  public func startLifecycleObserver() {
    AuraKitLifecycleObserver.shared.startObserving()
  }
}
