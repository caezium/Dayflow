//
//  UsageGroundTruth.swift
//  Dayflow
//
//  Reads accurate, local, ground-truth foreground usage to complement the
//  screenshot+LLM pipeline:
//    • macOS Screen Time (knowledgeC.db) — per-app and per-website foreground
//      time. Requires Full Disk Access; degrades to empty without it.
//    • ActivityWatch — window/AFK detail from its local REST API when running
//      (added in a companion extension).
//
//  All sources are local-only (no network egress), matching Dayflow's privacy
//  posture. knowledgeC is in WAL mode and owned by the system, so we copy it to
//  a temp file before opening read-only — the standard safe pattern.
//

import AppKit
import Foundation
import GRDB

/// One app or website's foreground time within a queried window.
struct UsageEntry: Identifiable, Sendable, Equatable {
  enum Kind: String, Sendable { case app, web }
  let id = UUID()
  let key: String  // bundle id (app) or domain (web)
  let displayName: String
  let kind: Kind
  let seconds: Double

  static func == (lhs: UsageEntry, rhs: UsageEntry) -> Bool {
    lhs.key == rhs.key && lhs.kind == rhs.kind && lhs.seconds == rhs.seconds
  }
}

enum UsageSource: String, Sendable { case screenTime, activityWatch }

final class UsageGroundTruth: @unchecked Sendable {
  static let shared = UsageGroundTruth()

  /// Mac absolute time (CFAbsoluteTime) epoch offset from Unix time.
  private let macEpochOffset: Double = 978_307_200

  private var knowledgeDBURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
  }

  private init() {}

  // MARK: - Public

  /// Merged ground-truth usage for the window, highest time first.
  func usage(from start: Date, to end: Date) -> [UsageEntry] {
    // Screen Time is always-available (given Full Disk Access); ActivityWatch is
    // layered on top by the companion reader when running.
    readScreenTime(from: start, to: end)
  }

  /// Whether Dayflow can actually read knowledgeC.db right now (i.e. Full Disk
  /// Access has been granted). Cheap probe used to drive the permission prompt.
  func screenTimeReadable() -> Bool {
    guard FileManager.default.isReadableFile(atPath: knowledgeDBURL.path) else { return false }
    // isReadableFile can be optimistic under TCC; confirm with an actual open.
    return withTemporaryCopy(of: knowledgeDBURL) { url in
      (try? DatabaseQueue(path: url.path, configuration: readonlyConfig)) != nil
    } ?? false
  }

  // MARK: - Screen Time (knowledgeC.db)

  private func readScreenTime(from start: Date, to end: Date) -> [UsageEntry] {
    let macStart = start.timeIntervalSince1970 - macEpochOffset
    let macEnd = end.timeIntervalSince1970 - macEpochOffset
    guard macEnd > macStart else { return [] }

    let rows: [(stream: String, key: String, seconds: Double)] =
      withTemporaryCopy(of: knowledgeDBURL) { url -> [(String, String, Double)] in
        guard let queue = try? DatabaseQueue(path: url.path, configuration: readonlyConfig) else {
          return []
        }
        return
          (try? queue.read { db in
            try Row.fetchAll(
              db,
              sql: """
                    SELECT ZSTREAMNAME AS stream,
                           ZVALUESTRING AS key,
                           SUM(MIN(ZENDDATE, ?) - MAX(ZSTARTDATE, ?)) AS seconds
                    FROM ZOBJECT
                    WHERE ZSTREAMNAME IN ('/app/usage', '/app/webUsage')
                      AND ZVALUESTRING IS NOT NULL
                      AND ZENDDATE > ? AND ZSTARTDATE < ?
                    GROUP BY ZSTREAMNAME, ZVALUESTRING
                    HAVING seconds > 0
                    ORDER BY seconds DESC
                """,
              arguments: [macEnd, macStart, macStart, macEnd]
            )
            .compactMap { row -> (String, String, Double)? in
              guard
                let stream: String = row["stream"],
                let key: String = row["key"],
                let seconds: Double = row["seconds"]
              else { return nil }
              return (stream, key, seconds)
            }
          }) ?? []
      } ?? []

    return rows.map { row in
      let isWeb = row.stream == "/app/webUsage"
      return UsageEntry(
        key: row.key,
        displayName: isWeb ? row.key : Self.appName(forBundleId: row.key),
        kind: isWeb ? .web : .app,
        seconds: row.seconds
      )
    }
  }

  // MARK: - Helpers

  private var readonlyConfig: Configuration {
    var config = Configuration()
    config.readonly = true
    return config
  }

  /// Copies the DB (plus its -wal/-shm sidecars) to a temp file and runs `body`
  /// against the copy, then cleans up. Returns nil if the copy fails (e.g. no
  /// Full Disk Access). Avoids touching the live, system-owned WAL database.
  private func withTemporaryCopy<T>(of dbURL: URL, _ body: (URL) -> T) -> T? {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("dayflow-usage-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let dest = dir.appendingPathComponent(dbURL.lastPathComponent)
      try fm.copyItem(at: dbURL, to: dest)
      for suffix in ["-wal", "-shm"] {
        let side = URL(fileURLWithPath: dbURL.path + suffix)
        if fm.fileExists(atPath: side.path) {
          try? fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix))
        }
      }
      return body(dest)
    } catch {
      return nil
    }
  }

  /// Best-effort human-readable app name for a bundle id, falling back to the id.
  private static func appName(forBundleId bundleId: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
      return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
    }
    // Fall back to the last dotted component, title-cased-ish.
    return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
  }
}
