import Foundation

/// Discovers the user's existing Codex connections, then exposes only read tools to this run.
/// No credentials or global CLI settings are copied or changed. New tools stay disabled until
/// the next discovery, so a server cannot expand the brief's permissions during a run.
struct DailyBriefCodexAccess: Sendable {
  let configOverrides: [String]
  let connectors: [String: String]
  let model: String?

  static func discover(in directory: URL) throws -> Self {
    guard let executable = CodexExecutableResolver.shared.resolve()?.executableURL else {
      throw DailyBriefGenerator.GenerationError(message: "Dayflow couldn't find Codex on this Mac.")
    }
    let client = try CodexBriefInventoryClient(executable: executable, directory: directory)
    defer { client.close() }
    _ = try client.request(
      "initialize",
      params: [
        "clientInfo": ["name": "dayflow_daily_brief", "version": "1.0"]
      ])
    let response = try client.request(
      "config/read",
      params: [
        "includeLayers": false, "cwd": directory.path,
      ])
    guard let config = response["config"] as? [String: Any] else {
      throw DailyBriefGenerator.GenerationError(
        message: "Codex couldn't read its connection settings.")
    }
    var servers: [[String: Any]] = []
    var cursor: String?
    repeat {
      var params: [String: Any] = ["detail": "toolsAndAuthOnly", "limit": 100]
      if let cursor { params["cursor"] = cursor }
      let page = try client.request("mcpServerStatus/list", params: params)
      guard let data = page["data"] as? [[String: Any]] else {
        throw DailyBriefGenerator.GenerationError(
          message: "Codex couldn't list its connected services.")
      }
      servers += data
      cursor = page["nextCursor"] as? String
    } while cursor != nil
    return try policy(config: config, servers: servers)
  }

  static func policy(config: [String: Any], servers: [[String: Any]]) throws -> Self {
    var overrides = [
      "approval_policy=\"never\"", "web_search=\"live\"", "agents.enabled=false",
      "features.computer_use=false", "features.browser_use=false",
      "features.image_generation=false", "analytics.enabled=false",
    ]
    var connectors: [String: String] = [:]
    var serverPolicies: [String: Any] = [:]
    var pluginPolicies: [String: [String: Any]] = [:]
    let configuredServers = config["mcp_servers"] as? [String: Any] ?? [:]
    let originalApps = config["apps"] as? [String: Any] ?? [:]
    var apps = disableAppTools(originalApps)
    var defaults = apps["_default"] as? [String: Any] ?? [:]
    defaults["enabled"] = false
    defaults["default_tools_approval_mode"] = "writes"
    defaults["destructive_enabled"] = false
    apps["_default"] = defaults

    for server in servers {
      guard let name = server["name"] as? String,
        let tools = server["tools"] as? [String: [String: Any]]
      else {
        throw DailyBriefGenerator.GenerationError(message: "Codex returned an invalid tool list.")
      }
      connectors[name] = server["toolsError"] is String ? "unavailable" : "read-only"
      if name == "codex_apps" {
        for tool in tools.values {
          guard let meta = tool["_meta"] as? [String: Any],
            let appID = meta["connector_id"] as? String,
            let source = meta["_codex_apps"] as? [String: Any],
            let uri = source["resource_uri"] as? String,
            let toolName = uri.split(separator: "/").last.map(String.init)
          else { continue }
          var app = apps[appID] as? [String: Any] ?? [:]
          app["default_tools_enabled"] = false
          app["destructive_enabled"] = false
          let original = originalApps[appID] as? [String: Any] ?? [:]
          let originalDefault = originalApps["_default"] as? [String: Any] ?? [:]
          let originalTools = original["tools"] as? [String: [String: Any]] ?? [:]
          // Codex versions can key policy by the raw MCP name (e.g. github.search)
          // or the app action name (search). Apply the same restriction to both.
          let names = Set([toolName, tool["name"] as? String ?? toolName])
          let appEnabled =
            original["enabled"] as? Bool ?? originalDefault["enabled"] as? Bool ?? true
          let originallyEnabled =
            appEnabled
            && !names.contains { originalTools[$0]?["enabled"] as? Bool == false }
            && (names.contains { originalTools[$0]?["enabled"] as? Bool == true }
              || (original["default_tools_enabled"] as? Bool ?? true))
          var appTools = app["tools"] as? [String: [String: Any]] ?? [:]
          app["enabled"] = appEnabled
          for name in names {
            appTools[name] = [
              "enabled": originallyEnabled
                && isReadTool(toolName, annotations: tool["annotations"]),
              "approval_mode": "writes",
            ]
          }
          app["tools"] = appTools
          apps[appID] = app
        }
        continue
      }
      let plugin = server["pluginId"] as? String
      if plugin == nil, configuredServers[name] == nil, tools.isEmpty {
        continue
      } else if plugin == nil, configuredServers[name] == nil {
        throw DailyBriefGenerator.GenerationError(
          message: "Dayflow couldn't restrict the \(name) connection to read-only tools.")
      }
      let allowed = tools.values.compactMap { tool -> String? in
        guard let toolName = tool["name"] as? String,
          isReadTool(toolName, annotations: tool["annotations"])
        else { return nil }
        return toolName
      }.sorted()
      if let plugin {
        var pluginServers = pluginPolicies[plugin]?["mcp_servers"] as? [String: Any] ?? [:]
        pluginServers[name] = ["enabled_tools": allowed]
        pluginPolicies[plugin] = ["mcp_servers": pluginServers]
      } else {
        serverPolicies[name] = ["enabled_tools": allowed]
      }
    }
    // CLI dotted paths do not unquote table keys. Put server/plugin IDs inside TOML tables
    // so punctuation in their names cannot create a second, transport-less server.
    overrides.append("mcp_servers=\(toml(serverPolicies))")
    overrides.append("plugins=\(toml(pluginPolicies))")
    overrides.append("apps=\(toml(apps))")
    return Self(
      configOverrides: overrides, connectors: connectors, model: config["model"] as? String)
  }

  /// Preserve disabled apps and existing connection settings while removing per-tool grants.
  private static func disableAppTools(_ value: [String: Any]) -> [String: Any] {
    var result = value
    for (key, item) in value where key != "_default" {
      guard var app = item as? [String: Any] else { continue }
      app["default_tools_enabled"] = false
      app["default_tools_approval_mode"] = "writes"
      app["destructive_enabled"] = false
      if let tools = app["tools"] as? [String: Any] {
        app["tools"] = tools.mapValues { _ in
          ["enabled": false, "approval_mode": "writes"] as [String: Any]
        }
      }
      if let links = app["links"] as? [String: [String: Any]] {
        app["links"] = links.mapValues { link in
          var link = link
          link["default_tools_approval_mode"] = "writes"
          return link
        }
      }
      result[key] = app
    }
    return result
  }

  static func isReadTool(_ name: String, annotations: Any?) -> Bool {
    let hints = annotations as? [String: Any] ?? [:]
    if hints["destructiveHint"] as? Bool == true || hints["readOnlyHint"] as? Bool == false {
      return false
    }
    let words = name.replacingOccurrences(
      of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression
    ).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let writes = Set(
      "send post create update delete write edit remove add reply archive move upload set schedule invite comment react mark publish share assign close merge approve draft submit cancel rename transfer pay run execute exec insert replace append patch put save import apply trigger respond accept decline complete resolve star follow subscribe label tag forward duplicate restore revert deploy kill start stop enable disable toggle unsubscribe unfollow pin unpin snooze mute"
        .split(separator: " ").map(String.init))
    guard writes.isDisjoint(with: words) else { return false }
    let reads = Set(
      "get list search read fetch query find view retrieve describe lookup download".split(
        separator: " "
      ).map(String.init))
    return !reads.isDisjoint(with: words)
  }

  /// JSON string escaping is also valid for TOML basic strings; arrays/tables need TOML syntax.
  static func toml(_ value: Any) -> String {
    if let object = value as? [String: Any] {
      return "{"
        + object.keys.sorted().filter { !(object[$0] is NSNull) }.map {
          "\(toml($0)) = \(toml(object[$0]!))"
        }.joined(separator: ", ") + "}"
    }
    if let array = value as? [Any] { return "[" + array.map(toml).joined(separator: ", ") + "]" }
    let data = try! JSONSerialization.data(
      withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }
}

/// Uses only inventory RPCs; never starts a model turn, changes configuration or logs secrets.
private final class CodexBriefInventoryClient {
  private let process: Process
  private let input = Pipe()
  private let output = Pipe()
  private var buffer = Data()
  private var nextID = 0
  private var deadline: DispatchWorkItem?

  init(executable: URL, directory: URL) throws {
    let command =
      "cd \(LoginShellRunner.shellEscape(directory.path)) && exec \(LoginShellRunner.shellEscape(executable.path)) app-server"
    process = ShellEnvironment.shared.makeProcess(command: command)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let process = process
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    self.deadline = deadline
    DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: deadline)
  }

  func close() {
    deadline?.cancel()
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    try? output.fileHandleForReading.close()
  }

  func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
    nextID += 1
    var data = try JSONSerialization.data(withJSONObject: [
      "id": nextID, "method": method, "params": params,
    ])
    data.append(10)
    guard ChatCLIProcessRunner.writeStandardInput(data, to: input.fileHandleForWriting) else {
      throw DailyBriefGenerator.GenerationError(
        message: "Codex closed its connection check. Try again.")
    }
    while true {
      if let newline = buffer.firstIndex(of: 10) {
        let line = buffer.prefix(upTo: newline)
        buffer.removeSubrange(...newline)
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
          continue
        }
        if message["method"] != nil, let id = message["id"] {
          var refusal = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "error": ["code": -32601, "message": "Daily Brief inventory cannot approve actions."],
          ])
          refusal.append(10)
          guard ChatCLIProcessRunner.writeStandardInput(refusal, to: input.fileHandleForWriting)
          else {
            throw DailyBriefGenerator.GenerationError(
              message: "Codex closed its connection check. Try again.")
          }
        }
        guard message["id"] as? Int == nextID else { continue }
        guard let result = message["result"] as? [String: Any] else {
          throw DailyBriefGenerator.GenerationError(
            message:
              "Codex couldn't inspect its connections. Update Codex or check its MCP settings, then retry."
          )
        }
        return result
      }
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty, buffer.count + chunk.count < 64 * 1024 * 1024 else {
        throw DailyBriefGenerator.GenerationError(
          message: "Codex couldn't finish checking its connections. Try again.")
      }
      buffer.append(chunk)
    }
  }
}
