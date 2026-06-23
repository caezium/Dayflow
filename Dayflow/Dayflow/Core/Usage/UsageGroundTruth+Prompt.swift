//
//  UsageGroundTruth+Prompt.swift
//  Dayflow
//
//  Formats ground-truth usage into a compact factual block for the analysis
//  prompt, so the LLM categorizes from measured app/site time rather than only
//  inferring from screenshots.
//

import Foundation

enum UsagePreferences {
  private static let feedKey = "feedGroundTruthToAI"
  private static let autoLaunchAWKey = "autoLaunchActivityWatch"
  private static let ocrKey = "useScreenTextOCR"

  /// Whether to OCR screenshots and feed the on-screen text into the AI prompt
  /// for sharper detection. Default on; local-only, no extra permission.
  static var useScreenTextOCR: Bool {
    get {
      if UserDefaults.standard.object(forKey: ocrKey) == nil { return true }
      return UserDefaults.standard.bool(forKey: ocrKey)
    }
    set { UserDefaults.standard.set(newValue, forKey: ocrKey) }
  }

  /// Whether measured usage (Screen Time / ActivityWatch) is added to the
  /// analysis prompt to improve accuracy. Default on; degrades to no-op when no
  /// source has data (e.g. Full Disk Access not granted).
  static var feedGroundTruthToAI: Bool {
    get {
      if UserDefaults.standard.object(forKey: feedKey) == nil { return true }
      return UserDefaults.standard.bool(forKey: feedKey)
    }
    set { UserDefaults.standard.set(newValue, forKey: feedKey) }
  }

  /// Whether to automatically launch ActivityWatch when Dayflow starts. Default
  /// off (opt-in), so Dayflow never starts other apps unexpectedly.
  static var autoLaunchActivityWatch: Bool {
    get { UserDefaults.standard.bool(forKey: autoLaunchAWKey) }
    set { UserDefaults.standard.set(newValue, forKey: autoLaunchAWKey) }
  }
}

extension UsageGroundTruth {
  /// A compact, factual usage block for the analysis prompt, or nil if there's
  /// nothing to add. Combines Screen Time (apps + sites) with ActivityWatch.
  func promptSection(from start: Date, to end: Date) async -> String? {
    guard end > start else { return nil }

    let screenTime = usage(from: start, to: end)
    let apps = screenTime.filter { $0.kind == .app }
    let sites = screenTime.filter { $0.kind == .web }
    let aw = (await activityWatchRunning()) ? await activityWatchUsage(from: start, to: end) : []

    guard !apps.isEmpty || !sites.isEmpty || !aw.isEmpty else { return nil }

    func summarize(_ entries: [UsageEntry], limit: Int) -> String {
      entries.prefix(limit)
        .map { "\($0.displayName) \(Self.compactDuration($0.seconds))" }
        .joined(separator: ", ")
    }

    var lines: [String] = []
    if !apps.isEmpty { lines.append("Apps (foreground): \(summarize(apps, limit: 12))") }
    if !sites.isEmpty { lines.append("Websites (foreground): \(summarize(sites, limit: 12))") }
    if !aw.isEmpty { lines.append("Windows (ActivityWatch): \(summarize(aw, limit: 12))") }

    return """
      ## Ground-truth foreground usage (measured by the system, not inferred)
      Exact foreground durations for this window, from the OS. Treat these as authoritative for which apps/sites were actually in use and for how long — prefer them over guesses from screenshots when identifying apps/sites and splitting time.
      \(lines.joined(separator: "\n"))
      """
  }

  static func compactDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
    if m > 0 { return "\(m)m" }
    return "<1m"
  }
}
