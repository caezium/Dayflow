import Foundation
import OSLog
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
  static let shared = LaunchAtLoginManager()

  @Published private(set) var isEnabled: Bool = false

  /// Last known login-item status, reported on every heartbeat.
  /// One of: enabled, not_registered, requires_approval, not_found, unknown.
  private(set) var statusName: String = "unknown"

  /// Set once launch at login has been turned on by default for this install, so we never
  /// turn it back on after someone switches it off.
  private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

  /// Fork: opt-in switch for the one-time automatic registration above. Default off.
  static let autoEnableDefaultsKey = "launchAtLoginAutoEnableEnabled"

  private let logger = Logger(subsystem: "com.dayflow.app", category: "launch_at_login")

  private init() {
    // Don't block init - refresh asynchronously
    Task {
      await refreshStatusAsync()
    }
  }

  /// Ensure the cached state is warmed up at launch so UI reflects the system toggle.
  func bootstrapDefaultPreference() {
    refreshStatusInBackground()
  }

  /// Re-reads the status without blocking. SMAppService.mainApp.status makes a synchronous
  /// XPC call that can take 5+ seconds.
  func refreshStatusInBackground() {
    Task {
      await refreshStatusAsync()
    }
  }

  /// Re-sync with System Settings, e.g. if the user adds/removes Dayflow manually.
  /// This is the synchronous version for use in setEnabled() after user action.
  func refreshStatus() {
    apply(status: SMAppService.mainApp.status)
  }

  /// Async version that runs the XPC call off the main actor to avoid blocking
  private func refreshStatusAsync() async {
    // Run XPC call on background thread
    let status = await Task.detached(priority: .utility) {
      SMAppService.mainApp.status
    }.value
    apply(status: status)
  }

  private func apply(status: SMAppService.Status) {
    let enabled = (status == .enabled)
    if isEnabled != enabled {
      logger.debug(
        "Launch at login status changed → \(enabled ? "enabled" : "disabled") [status=\(String(describing: status))]"
      )
    }
    isEnabled = enabled
    statusName = Self.name(for: status)
  }

  /// Register or unregister the main app as a login item from the Settings toggle.
  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }

    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      isEnabled = enabled
      logger.info("Launch at login \(enabled ? "enabled" : "disabled") successfully")
      AnalyticsService.shared.capture(
        "launch_at_login_changed", ["enabled": enabled, "source": "settings", "success": true])
    } catch {
      logger.error(
        "Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription, privacy: .public)"
      )
      AnalyticsService.shared.capture(
        "launch_at_login_changed",
        [
          "enabled": enabled, "source": "settings", "success": false,
          "error": error.localizedDescription,
        ])
    }
    refreshStatusInBackground()
  }

  /// Turns launch at login on once per install, without asking. `source` is
  /// "onboarding" for new users and "existing_user" for people who onboarded before this
  /// shipped. If someone already switched Dayflow off in System Settings (requires_approval),
  /// we leave it off.
  func enableByDefaultIfNeeded(source: String) {
    let defaults = UserDefaults.standard
    // Fork: registering a login item is a change outside the app's own
    // container, made here without the user asking. Keep it behind an opt-in,
    // the same policy as CLIAutoUpdater and the Sparkle flags; the Settings
    // toggle (setEnabled) stays available either way. Opt in with:
    //   defaults write teleportlabs.com.Dayflow launchAtLoginAutoEnableEnabled -bool true
    guard defaults.object(forKey: Self.autoEnableDefaultsKey) as? Bool ?? false else { return }
    guard !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
    defaults.set(true, forKey: Self.defaultAppliedKey)

    Task {
      let result = await Task.detached(priority: .utility) { () -> (String, String?) in
        switch SMAppService.mainApp.status {
        case .enabled:
          return ("already_enabled", nil)
        case .requiresApproval:
          return ("skipped_user_disabled", nil)
        default:
          do {
            try SMAppService.mainApp.register()
            return ("registered", nil)
          } catch {
            return ("failed", error.localizedDescription)
          }
        }
      }.value

      await refreshStatusAsync()

      var props: [String: Any] = [
        "source": source, "result": result.0, "status_after": statusName,
      ]
      if let error = result.1 {
        props["error"] = error
      }
      AnalyticsService.shared.capture("launch_at_login_default_applied", props)
      logger.info("Launch at login default applied: \(result.0, privacy: .public)")
    }
  }

  private static func name(for status: SMAppService.Status) -> String {
    switch status {
    case .enabled: return "enabled"
    case .notRegistered: return "not_registered"
    case .requiresApproval: return "requires_approval"
    case .notFound: return "not_found"
    @unknown default: return "unknown"
    }
  }
}
