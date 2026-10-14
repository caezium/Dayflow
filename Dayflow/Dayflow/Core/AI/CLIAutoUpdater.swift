import Foundation

/// Runs `codex update` / `claude update` on the user's behalf after Dayflow
/// itself updates, so CLI providers don't drift onto stale versions.
/// Best-effort: failures are reported to analytics and never shown to the user.
enum CLIAutoUpdater {
  private static let timeout: TimeInterval = 5 * 60

  /// Fork: silent background updates of the user's own dev tooling are off
  /// unless explicitly opted in — the same policy that keeps Sparkle's
  /// auto-update disabled. A `claude`/`codex` upgrade mid-session is the
  /// user's call, not the app's. Opt in with:
  ///   defaults write teleportlabs.com.Dayflow cliAutoUpdateEnabled -bool true
  static let enabledDefaultsKey = "cliAutoUpdateEnabled"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? false
  }

  /// Updates only the CLIs the user has routed as primary or backup provider.
  static func updateProviderCLIs() {
    guard isEnabled else {
      print("[CLIAutoUpdater] Disabled (fork default); skipping provider CLI updates")
      return
    }
    guard let routing = try? LLMProviderRoutingStore.load() else { return }
    let providers = [routing.primary, routing.secondary]
    let tools = [ChatCLITool.codex, ChatCLITool.claude].filter {
      providers.contains($0.providerID)
    }
    guard !tools.isEmpty else { return }

    Task.detached(priority: .utility) {
      for tool in tools {
        update(tool)
      }
      await CLIVersionTelemetry.refresh()
    }
  }

  private static func update(_ tool: ChatCLITool) {
    guard let fromVersion = installedVersion(of: tool) else { return }
    guard let command = updateCommand(for: tool) else {
      // Codex bundled inside Codex.app / ChatGPT.app is updated by that app.
      capture(tool, fromVersion: fromVersion, outcome: "skipped_app_bundled")
      return
    }

    let startedAt = Date()
    let result = LoginShellRunner.run(command, timeout: timeout)
    let outcome: String
    switch result.exitCode {
    case 0: outcome = "succeeded"
    case -2: outcome = "timed_out"
    default: outcome = "failed"
    }

    capture(
      tool,
      fromVersion: fromVersion,
      outcome: outcome,
      extra: [
        "to_version": installedVersion(of: tool) ?? "not_installed",
        "exit_code": Int(result.exitCode),
        "duration_seconds": Int(Date().timeIntervalSince(startedAt)),
      ])
  }

  private static func updateCommand(for tool: ChatCLITool) -> String? {
    switch tool {
    case .claude:
      return "claude update"
    case .codex:
      guard let codex = CodexExecutableResolver.shared.resolve(), codex.source == .path else {
        return nil
      }
      return "\(LoginShellRunner.shellEscape(codex.executableURL.path)) update"
    }
  }

  private static func installedVersion(of tool: ChatCLITool) -> String? {
    switch tool {
    case .claude:
      return LoginShellRunner.version(of: "claude").map(CLIVersionTelemetry.numericVersion)
    case .codex:
      // Drop the cached resolution so the post-update probe sees the new binary.
      CodexExecutableResolver.shared.invalidate()
      return CodexExecutableResolver.shared.resolve()?.version
    }
  }

  private static func capture(
    _ tool: ChatCLITool,
    fromVersion: String,
    outcome: String,
    extra: [String: Any] = [:]
  ) {
    let props: [String: Any] = [
      "tool": tool.rawValue,
      "from_version": fromVersion,
      "outcome": outcome,
    ]
    AnalyticsService.shared.capture(
      "cli_auto_update", props.merging(extra) { _, new in new })
  }
}
