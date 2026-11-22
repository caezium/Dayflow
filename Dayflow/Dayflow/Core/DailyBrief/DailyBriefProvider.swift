import Foundation

enum DailyBriefProvider: String, CaseIterable, Sendable {
  case codex
  case claude

  static let preferenceKey = "dailyBriefProvider"

  static var selected: Self {
    Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .codex
  }

  var title: String { self == .codex ? "Codex / ChatGPT" : "Claude Code" }
  var displayName: String { self == .codex ? "Codex" : "Claude" }

  func readinessProblem() -> String? {
    if self == .claude { return DailyBriefGenerator.claudeReadinessProblem() }
    guard let executable = CodexExecutableResolver.shared.resolve()?.executableURL else {
      return "Codex isn't installed on this Mac. Install Codex, then run `codex login` in Terminal."
    }
    let command = LoginShellRunner.shellEscape(executable.path)
    let help = LoginShellRunner.run("\(command) exec --help", timeout: 20)
    guard help.exitCode == 0, help.stdout.contains("--output-schema"),
      help.stdout.contains("--ephemeral"), help.stdout.contains("--ignore-user-config"),
      help.stdout.contains("--strict-config")
    else { return "Update Codex to use it for Daily Brief, then try again." }
    let login = LoginShellRunner.run("\(command) login status", timeout: 20)
    guard login.exitCode == 0 else {
      return "Codex isn't signed in. Run `codex login` in Terminal, then try again."
    }
    return nil
  }
}

/// Extra capabilities for a structured brief; timeline runs keep their existing restrictions.
struct CodexCLIStructuredOutputOptions: Sendable {
  let schemaPath: String
  let configOverrides: [String]
  var loadsUserConfiguration = true
  var readablePaths: [String] = []

  var commandArguments: [String] {
    var arguments = [
      "--ephemeral", "--strict-config", "--output-schema",
      LoginShellRunner.shellEscape(schemaPath),
    ]
    var filesystem: [String: String] = [
      ":root": "deny", ":minimal": "read", ":tmpdir": "deny", ":slash_tmp": "deny",
    ]
    for path in readablePaths { filesystem[path] = "read" }
    let permissions: [String: Any] = [
      "dayflow-brief": ["filesystem": filesystem, "network": ["enabled": false]]
    ]
    arguments += [
      "-c", LoginShellRunner.shellEscape("default_permissions=\"dayflow-brief\""),
      "-c", LoginShellRunner.shellEscape("permissions=\(DailyBriefCodexAccess.toml(permissions))"),
    ]
    if !loadsUserConfiguration { arguments.append("--ignore-user-config") }
    for value in configOverrides {
      arguments += ["-c", LoginShellRunner.shellEscape(value)]
    }
    return arguments
  }
}
