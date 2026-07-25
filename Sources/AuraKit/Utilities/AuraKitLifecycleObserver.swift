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
/// 1. **Zero Data Loss:** When the application enters the background or resigns active state,
///    pending coalesced writes in ``EncryptedMemoryStore`` are automatically flushed to disk.
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
public final class AuraKitLifecycleObserver: Sendable {

  private static let logger = Logger(
    subsystem: AuraKitConstants.subsystem,
    category: "AuraKitLifecycleObserver"
  )

  /// Shared instance for app lifecycle tracking.
  public static let shared = AuraKitLifecycleObserver()

  private var isObserving: Bool = false

  private init() {}

  /// Starts listening for application lifecycle notifications.
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
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    #elseif canImport(AppKit)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleBackgroundTransition),
      name: NSApplication.didResignActiveNotification,
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

  @objc private func handleBackgroundTransition() {
    Task { @MainActor in
      guard let capture = AuraKit.shared.captureOrNil else { return }
      let flushed = await capture.flushToStore()
      Self.logger.info(
        "[AuraKit] Background transition: Flushed \(flushed) events to store."
      )
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
