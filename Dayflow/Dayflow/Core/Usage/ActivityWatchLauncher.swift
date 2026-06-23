//
//  ActivityWatchLauncher.swift
//  Dayflow
//
//  Detects whether ActivityWatch is installed/running and can launch it, so its
//  richer window/AFK tracking is available to the usage features. Optionally
//  auto-launches it when Dayflow starts.
//

import AppKit
import Combine

@MainActor
final class ActivityWatchLauncher: ObservableObject {
  static let shared = ActivityWatchLauncher()

  private let bundleId = "net.activitywatch.ActivityWatch"

  /// True while the ActivityWatch app process is running.
  @Published private(set) var isRunning = false
  /// True if ActivityWatch is installed on this Mac.
  @Published private(set) var isInstalled = false
  /// True briefly while a launch is in flight (so the button can show progress).
  @Published private(set) var isLaunching = false

  private var observers: [NSObjectProtocol] = []

  private init() {
    isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    refreshRunning()
    observeWorkspace()
  }

  func refreshRunning() {
    isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
  }

  /// Launch ActivityWatch without stealing focus from Dayflow.
  func launch() {
    guard isInstalled, !isRunning,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    else { return }

    isLaunching = true
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
      [weak self] _, _ in
      Task { @MainActor in
        // The aw-server takes a moment to come up; refresh after a short delay.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        self?.isLaunching = false
        self?.refreshRunning()
      }
    }
  }

  /// Called at startup: launch ActivityWatch if the user opted in and it's down.
  func autoLaunchIfEnabled() {
    guard UsagePreferences.autoLaunchActivityWatch else { return }
    refreshRunning()
    guard isInstalled, !isRunning else { return }
    launch()
  }

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.refreshRunning() }
      }
      observers.append(observer)
    }
  }
}
