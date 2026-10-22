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
      selector: #selector(handleBackgroundTransition),
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
      selector: #selector(handleBackgroundTransition),
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

  /// Maximum time the expiring-activity assertion waits for the flush.
  private nonisolated static let flushTimeout: DispatchTimeInterval = .seconds(25)

  @objc private func handleBackgroundTransition() {
    let done = DispatchSemaphore(value: 0)

    // Flush first, then wipe keys — the flush needs the key to encrypt.
    let work = Task { @MainActor in
      defer { done.signal() }
      guard let capture = AuraKit.shared.captureOrNil else { return }
      let flushed = await capture.flushToStore()
      Self.logger.info(
        "[AuraKit] Background transition: Flushed \(flushed) events to store."
      )

      await capture.clearSensitiveDataForBackground()
      Self.logger.info("[AuraKit] Background transition: Cleared sensitive data.")
    }

    // Without an assertion the process can be suspended mid-flush, losing the
    // coalesced writes and leaving the key cached. `performExpiringActivity`
    // works in apps *and* extensions (unlike `UIApplication.beginBackgroundTask`)
    // and runs its block on a background queue, so waiting here never blocks
    // the main actor or the Swift Concurrency cooperative pool.
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    ProcessInfo.processInfo.performExpiringActivity(
      withReason: "AuraKit: flush encrypted writes and clear key material"
    ) { expired in
      if expired {
        work.cancel()
        return
      }
      if done.wait(timeout: .now() + Self.flushTimeout) == .timedOut {
        Self.logger.error("[AuraKit] Background transition: flush did not finish before timeout.")
      }
    }
    #elseif os(macOS)
    ProcessInfo.processInfo.performActivity(
      options: .userInitiated,
      reason: "AuraKit: flush encrypted writes and clear key material"
    ) {
      if done.wait(timeout: .now() + Self.flushTimeout) == .timedOut {
        Self.logger.error("[AuraKit] Background transition: flush did not finish before timeout.")
      }
    }
    #else
    if done.wait(timeout: .now() + Self.flushTimeout) == .timedOut {
      Self.logger.error("[AuraKit] Background transition: flush did not finish before timeout.")
    }
    #endif
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
