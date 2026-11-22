import Foundation

extension DailyBriefGenerator {
  static func runStructured(
    provider: DailyBriefProvider, codexAccess: DailyBriefCodexAccess? = nil,
    prompt: String, options: ClaudeCLIStructuredOutputOptions, workingDirectory: URL,
    timeoutSeconds: TimeInterval, transcriptURL: URL? = nil, tooLongMessage: String
  ) throws -> StructuredBriefResult {
    if provider == .codex {
      return try runStructuredCodex(
        prompt: prompt, options: options, access: codexAccess, workingDirectory: workingDirectory,
        timeoutSeconds: timeoutSeconds, transcriptURL: transcriptURL, tooLongMessage: tooLongMessage
      )
    }
    return try runStructuredClaude(
      prompt: prompt, options: options, workingDirectory: workingDirectory,
      timeoutSeconds: timeoutSeconds, transcriptURL: transcriptURL, tooLongMessage: tooLongMessage)
  }

  static func runStructuredCodex(
    prompt: String, options: ClaudeCLIStructuredOutputOptions, access: DailyBriefCodexAccess?,
    workingDirectory: URL, timeoutSeconds: TimeInterval, transcriptURL: URL? = nil,
    tooLongMessage: String
  ) throws -> StructuredBriefResult {
    let schemaURL = workingDirectory.appendingPathComponent("\(options.name)-schema.json")
    defer { try? FileManager.default.removeItem(at: schemaURL) }
    guard
      let schema = try JSONSerialization.jsonObject(with: Data(options.jsonSchema.utf8))
        as? [String: Any]
    else {
      throw GenerationError(message: "Dayflow couldn't prepare the brief's response format.")
    }
    try Data(jsonString(codexSchema(schema)).utf8).write(to: schemaURL, options: .atomic)
    var overrides =
      access?.configOverrides ?? [
        "approval_policy=\"never\"", "web_search=\"disabled\"", "agents.enabled=false",
        "features.apps=false", "features.plugins=false", "features.shell_tool=false",
        "features.computer_use=false", "features.browser_use=false", "analytics.enabled=false",
      ]
    if let configPath = options.mcpConfigPath,
      let data = FileManager.default.contents(atPath: configPath),
      let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let servers = config["mcpServers"] as? [String: [String: Any]],
      let dayflow = servers["dayflow"]
    {
      for key in ["command", "args"] {
        if let value = dayflow[key] {
          overrides.append("mcp_servers.dayflow.\(key)=\(DailyBriefCodexAccess.toml(value))")
        }
      }
      overrides.append(
        "mcp_servers.dayflow.enabled_tools=\(DailyBriefCodexAccess.toml(dayflowReadTools))")
    }
    let profile = CodexCLIStructuredOutputOptions(
      schemaPath: schemaURL.path, configOverrides: overrides, loadsUserConfiguration: access != nil,
      readablePaths: [workingDirectory.path]
        + options.allowedTools.compactMap { rule in
          guard rule.hasPrefix("Read(/"), rule.hasSuffix("/**)") else { return nil }
          return String(rule.dropFirst("Read(/".count).dropLast("/**)".count))
        })
    let runner = ChatCLIProcessRunner()
    let run: ChatCLIRunResult
    do {
      run = try runner.run(
        tool: .codex, prompt: prompt, workingDirectory: workingDirectory,
        reasoningEffort: "medium", codexStructuredOutput: profile, timeoutSeconds: timeoutSeconds)
    } catch let error as NSError where error.domain == "ChatCLI" && error.code == -3 {
      throw GenerationError(message: tooLongMessage)
    } catch {
      throw GenerationError(message: "Codex couldn't run the brief: \(error.localizedDescription)")
    }
    if let transcriptURL {
      let text =
        "# Prompt\n\n\(prompt)\n\n# Codex events\n\n\(run.rawStdout)\n\n# stderr\n\n\(run.stderr)\n"
      try? FileManager.default.createDirectory(
        at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
    return try decodeCodexResult(run, access: access)
  }

  static func decodeCodexResult(_ run: ChatCLIRunResult, access: DailyBriefCodexAccess?) throws
    -> StructuredBriefResult
  {
    let runner = ChatCLIProcessRunner()
    let output = runner.parseCodexJSONOutput(run.rawStdout)
    guard run.exitCode == 0, output?.errors.isEmpty != false else {
      throw GenerationError(
        message: "Codex couldn't finish the brief. \(run.failureMessage(toolName: "Codex"))")
    }
    guard let json = jsonObjectData(in: output?.text ?? run.stdout, runner: runner) else {
      throw GenerationError(message: "Codex's answer came back in an unexpected shape. Try again.")
    }
    var stats = DailyBriefRunStats()
    stats.model = access?.model ?? "Codex"
    stats.connectors = access?.connectors
    let usage = output?.usage ?? run.usage
    stats.inputTokens = usage?.input
    stats.outputTokens = usage?.output
    stats.cacheReadTokens = usage?.cachedInput
    var toolCalls: [String: Int] = [:]
    var turns = 0
    for line in run.rawStdout.split(whereSeparator: \.isNewline) {
      guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }
      if event["type"] as? String == "turn.completed" { turns += 1 }
      guard event["type"] as? String == "item.completed",
        let item = event["item"] as? [String: Any],
        let type = item["type"] as? String
      else { continue }
      if ["mcp_tool_call", "web_search", "command_execution", "image_view"].contains(type) {
        toolCalls[item["tool"] as? String ?? type, default: 0] += 1
      }
    }
    stats.toolCalls = toolCalls
    stats.numTurns = turns
    return StructuredBriefResult(json: json, stats: stats)
  }

  /// OpenAI strict schemas require every property; nullable fields preserve upstream's optionals.
  static func codexSchema(_ schema: [String: Any]) -> [String: Any] {
    var result = schema
    if let properties = schema["properties"] as? [String: [String: Any]] {
      let required = Set(schema["required"] as? [String] ?? [])
      var converted: [String: Any] = [:]
      for (key, property) in properties {
        let child = codexSchema(property)
        converted[key] = required.contains(key) ? child : ["anyOf": [child, ["type": "null"]]]
      }
      result["properties"] = converted
      result["required"] = properties.keys.sorted()
      result["additionalProperties"] = false
    }
    if let items = schema["items"] as? [String: Any] { result["items"] = codexSchema(items) }
    return result
  }
}
