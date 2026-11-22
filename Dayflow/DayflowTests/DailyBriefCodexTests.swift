import XCTest

@testable import Dayflow

final class DailyBriefCodexTests: XCTestCase {
  func testConnectorPolicyKeepsReadsAndBlocksWritesAndArbitraryCode() throws {
    for name in ["get_issue", "searchMessages", "list_documents", "fetch_page"] {
      XCTAssertTrue(DailyBriefCodexAccess.isReadTool(name, annotations: nil), name)
    }
    for name in ["send_message", "get_and_delete", "searchAndUpdate", "js", "exec", "run_query"] {
      XCTAssertFalse(
        DailyBriefCodexAccess.isReadTool(name, annotations: ["readOnlyHint": true]), name)
    }
    XCTAssertFalse(
      DailyBriefCodexAccess.isReadTool("get_token", annotations: ["readOnlyHint": false]))
    XCTAssertFalse(
      DailyBriefCodexAccess.isReadTool("get_item", annotations: ["destructiveHint": true]))

    let policy = try DailyBriefCodexAccess.policy(
      config: ["mcp_servers": ["work": ["url": "https://example.com/mcp"]]],
      servers: [
        [
          "name": "work",
          "tools": [
            "search": ["name": "search"], "send": ["name": "send_message"],
          ],
        ]
      ])
    XCTAssertTrue(
      policy.configOverrides.contains(#"mcp_servers={"work" = {"enabled_tools" = ["search"]}}"#))
    XCTAssertTrue(policy.configOverrides.contains(#"web_search="live""#))
    XCTAssertTrue(policy.configOverrides.contains(#"approval_policy="never""#))
  }

  func testPluginPolicyUsesPluginNamespaceAndUnavailableServicesGetNoTools() throws {
    let policy = try DailyBriefCodexAccess.policy(
      config: ["mcp_servers": ["offline": ["command": "missing"]]],
      servers: [
        ["name": "docs", "pluginId": "docs@example", "tools": ["read": ["name": "read_doc"]]],
        ["name": "offline", "tools": [:], "toolsError": "not connected"],
      ])
    XCTAssertTrue(
      policy.configOverrides.contains(
        #"plugins={"docs@example" = {"mcp_servers" = {"docs" = {"enabled_tools" = ["read_doc"]}}}}"#
      ))
    XCTAssertTrue(
      policy.configOverrides.contains(#"mcp_servers={"offline" = {"enabled_tools" = []}}"#))
    XCTAssertEqual(policy.connectors["offline"], "unavailable")
    XCTAssertThrowsError(
      try DailyBriefCodexAccess.policy(
        config: [:], servers: [["name": "unknown", "tools": ["read": ["name": "read_doc"]]]]))
  }

  func testAppPolicyRemovesExistingWriteGrantsAndRespectsDisabledReads() throws {
    func tool(_ name: String, read: Bool) -> [String: Any] {
      [
        "name": "mail." + name, "annotations": ["readOnlyHint": read],
        "_meta": [
          "connector_id": "mail", "_codex_apps": ["resource_uri": "/mail/account/\(name)"],
        ],
      ]
    }
    let policy = try DailyBriefCodexAccess.policy(
      config: [
        "apps": [
          "mail": [
            "tools": [
              "send_message": ["enabled": true, "approval_mode": "approve"],
              "mail.read_private": ["enabled": false],
            ]
          ]
        ]
      ],
      servers: [
        [
          "name": "codex_apps",
          "tools": [
            "read": tool("read_mail", read: true), "write": tool("send_message", read: false),
            "private": tool("read_private", read: true),
          ],
        ]
      ])
    let apps = try XCTUnwrap(policy.configOverrides.first { $0.hasPrefix("apps=") })
    XCTAssertTrue(apps.contains(#""read_mail" = {"approval_mode" = "writes", "enabled" = true}"#))
    XCTAssertTrue(
      apps.contains(#""send_message" = {"approval_mode" = "writes", "enabled" = false}"#))
    XCTAssertTrue(
      apps.contains(#""read_private" = {"approval_mode" = "writes", "enabled" = false}"#))
    XCTAssertTrue(apps.contains(#""default_tools_enabled" = false"#))
    XCTAssertTrue(
      apps.contains(#""mail.read_mail" = {"approval_mode" = "writes", "enabled" = true}"#))
    XCTAssertTrue(
      apps.contains(#""mail.send_message" = {"approval_mode" = "writes", "enabled" = false}"#))
    XCTAssertFalse(apps.contains("approve"))
  }

  func testStrictSchemasRetainEveryBriefSectionAndNullableOptionalFields() throws {
    for part in DailyBriefGenerator.Part.allCases {
      let original = DailyBriefGenerator.schema(for: part)
      let converted = DailyBriefGenerator.codexSchema(original)
      let originalProperties = try XCTUnwrap(original["properties"] as? [String: Any])
      let properties = try XCTUnwrap(converted["properties"] as? [String: Any])
      XCTAssertEqual(Set(properties.keys), Set(originalProperties.keys))
      XCTAssertEqual(Set(converted["required"] as? [String] ?? []), Set(properties.keys))
      XCTAssertEqual(converted["additionalProperties"] as? Bool, false)
      if part == .extras {
        let completed = try XCTUnwrap(properties["completed_yesterday"] as? [String: Any])
        XCTAssertNotNil(completed["anyOf"])
      }
    }
  }

  func testCodexEventsProduceBriefJSONAndAccurateTokenUsageAndFailures() throws {
    let raw = #"""
      {"type":"item.completed","item":{"type":"web_search"}}
      {"type":"item.completed","item":{"type":"agent_message","text":"{\"notes\":\"Done\",\"items\":[]}"}}
      {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}
      """#
    let result = try DailyBriefGenerator.decodeCodexResult(run(raw), access: nil)
    let json = try JSONSerialization.jsonObject(with: result.json) as? [String: Any]
    XCTAssertEqual(json?["notes"] as? String, "Done")
    XCTAssertEqual(result.stats.inputTokens, 60)
    XCTAssertEqual(result.stats.cacheReadTokens, 40)
    XCTAssertEqual(result.stats.outputTokens, 20)
    XCTAssertEqual(result.stats.toolCalls?["web_search"], 1)
    XCTAssertThrowsError(
      try DailyBriefGenerator.decodeCodexResult(
        run(raw + "\n" + #"{"type":"turn.failed","error":{"message":"usage limit"}}"#), access: nil)
    )
    XCTAssertThrowsError(try DailyBriefGenerator.decodeCodexResult(run("not JSON"), access: nil))
  }

  func testStructuredCodexUsesStdinAndRetainsOnlyTheExplicitResearchProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "brief-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("codex")
    try """
    #!/bin/sh
    cat > prompt.txt
    printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"items\\":[]}"}}'
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}'
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let resolver = CodexExecutableResolver(
      candidateProvider: { [.init(executableURL: executable, source: .path)] },
      versionProbe: { _ in "codex-cli 0.171.0" })
    let runner = ChatCLIProcessRunner(codexExecutableResolver: resolver)
    let result = try runner.run(
      tool: .codex, prompt: "PRIVATE_BRIEF_SENTINEL", workingDirectory: directory,
      codexStructuredOutput: .init(
        schemaPath: directory.appendingPathComponent("schema.json").path,
        configOverrides: [#"web_search="live""#]), timeoutSeconds: 10)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, #"{"items":[]}"#)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("prompt.txt"), encoding: .utf8),
      "PRIVATE_BRIEF_SENTINEL")
    let command = try XCTUnwrap(result.shellCommand)
    XCTAssertFalse(command.contains("PRIVATE_BRIEF_SENTINEL"))
    XCTAssertFalse(command.contains("--sandbox"))
    XCTAssertTrue(command.contains("--strict-config"))
    XCTAssertTrue(command.contains(#"default_permissions="dayflow-brief""#))
    XCTAssertTrue(command.contains(#"":root" = "deny""#))
    XCTAssertTrue(command.contains(#"":tmpdir" = "deny""#))
    XCTAssertTrue(command.contains(#"":slash_tmp" = "deny""#))
    XCTAssertTrue(command.contains(#""network" = {"enabled" = false}"#))
    XCTAssertTrue(command.contains("--output-schema"))
    XCTAssertTrue(command.contains("--ephemeral"))
    XCTAssertFalse(command.contains("--ignore-user-config"))
    XCTAssertFalse(command.contains("rmcp_client=false"))
    XCTAssertFalse(command.contains("web_search=disabled"))
    XCTAssertFalse(command.contains("bypass"))
  }

  private func run(_ raw: String) -> ChatCLIRunResult {
    .init(
      exitCode: 0, stdout: "", rawStdout: raw, stderr: "", shellCommand: "",
      environmentOverrides: [:],
      startedAt: Date(), finishedAt: Date(), usage: nil)
  }
}
