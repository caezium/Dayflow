//
//  ActivityWatchReader.swift
//  Dayflow
//
//  Reads window/app usage from a locally-running ActivityWatch instance via its
//  REST API (http://localhost:5600). All requests are localhost-only. When AW
//  isn't running, every call degrades to an empty result.
//

import Foundation

extension UsageGroundTruth {
  private var awBaseURL: URL { URL(string: "http://localhost:5600")! }

  /// True if a local ActivityWatch server answers within a short timeout.
  func activityWatchRunning() async -> Bool {
    await awGetJSON(path: "/api/0/info") != nil
  }

  /// Per-app foreground time from ActivityWatch's window watcher for the range.
  /// Empty if AW isn't running or has no window bucket.
  func activityWatchUsage(from start: Date, to end: Date) async -> [UsageEntry] {
    guard
      let buckets = await awGetJSON(path: "/api/0/buckets/") as? [String: Any],
      let windowBucket = buckets.keys.first(where: { $0.hasPrefix("aw-watcher-window") })
    else { return [] }

    let iso = ISO8601DateFormatter()
    var components = URLComponents(
      url: awBaseURL.appendingPathComponent("/api/0/buckets/\(windowBucket)/events"),
      resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "start", value: iso.string(from: start)),
      URLQueryItem(name: "end", value: iso.string(from: end)),
    ]
    guard
      let url = components?.url,
      let events = await awGetJSON(url: url) as? [[String: Any]]
    else { return [] }

    var byApp: [String: Double] = [:]
    for event in events {
      let duration = (event["duration"] as? Double) ?? 0
      guard duration > 0, let data = event["data"] as? [String: Any] else { continue }
      let app = (data["app"] as? String) ?? "Unknown"
      byApp[app, default: 0] += duration
    }

    return
      byApp
      .map { UsageEntry(key: $0.key, displayName: $0.key, kind: .app, seconds: $0.value) }
      .sorted { $0.seconds > $1.seconds }
  }

  // MARK: - Networking

  private func awGetJSON(path: String) async -> Any? {
    await awGetJSON(url: awBaseURL.appendingPathComponent(path))
  }

  private func awGetJSON(url: URL) async -> Any? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: config)
    guard
      let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, http.statusCode == 200
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
