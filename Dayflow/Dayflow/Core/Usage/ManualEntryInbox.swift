//
//  ManualEntryInbox.swift
//  Dayflow
//
//  Watches an iCloud Drive "Dayflow Inbox" folder for small JSON files dropped
//  by a phone Shortcut, and ingests each as a manual time entry. This is the
//  phone → Mac bridge: the iPhone writes a file to iCloud Drive, it syncs to the
//  Mac, and Dayflow picks it up. No server, no account, local once synced.
//
//  Expected JSON (any of):
//    { "title": "Lunch", "category": "Personal", "minutes": 45 }
//    { "title": "Meeting", "category": "Work",
//      "start": "2026-06-22T13:00:00Z", "end": "2026-06-22T14:00:00Z" }
//

import Foundation

final class ManualEntryInbox: @unchecked Sendable {
  static let shared = ManualEntryInbox()

  private let fm = FileManager.default
  private var timer: Timer?

  /// ~/Library/Mobile Documents/com~apple~CloudDocs/Dayflow Inbox
  private var inboxURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        "Library/Mobile Documents/com~apple~CloudDocs/Dayflow Inbox", isDirectory: true)
  }
  private var processedURL: URL { inboxURL.appendingPathComponent("processed", isDirectory: true) }

  private init() {}

  func start() {
    // iCloud Drive may not exist; only run if the container is present.
    let cloudRoot = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    guard fm.fileExists(atPath: cloudRoot.path) else { return }

    try? fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    try? fm.createDirectory(at: processedURL, withIntermediateDirectories: true)

    scan()
    let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.scan()
    }
    self.timer = timer
  }

  private func scan() {
    guard
      let files = try? fm.contentsOfDirectory(
        at: inboxURL, includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles])
    else { return }

    for file in files where file.pathExtension.lowercased() == "json" {
      guard
        let data = try? Data(contentsOf: file),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { continue }

      let fileDate =
        (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
      if let entry = Self.parseEntry(from: object, fallbackEnd: fileDate) {
        Task { @MainActor in StorageManager.shared.insertManualEntry(entry) }
      }

      // Move processed file aside so it isn't ingested twice.
      let dest = processedURL.appendingPathComponent(file.lastPathComponent)
      try? fm.removeItem(at: dest)
      try? fm.moveItem(at: file, to: dest)
    }
  }

  /// Build a ManualEntry from a key/value payload (used by the inbox and the
  /// dayflow://log deep link). Accepts minutes, or explicit ISO start/end.
  static func parseEntry(from values: [String: Any], fallbackEnd: Date = Date()) -> ManualEntry? {
    func string(_ key: String) -> String? {
      if let s = values[key] as? String { return s }
      if let n = values[key] as? NSNumber { return n.stringValue }
      return nil
    }

    let title = (string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    let category = string("category") ?? ""

    let iso = ISO8601DateFormatter()
    if let startStr = string("start"), let endStr = string("end"),
      let start = iso.date(from: startStr), let end = iso.date(from: endStr), end > start
    {
      return ManualEntry(title: title, category: category, start: start, end: end)
    }

    // minutes-based: end at fallback (file time / now), start = end - minutes.
    let minutes: Double? = {
      if let n = values["minutes"] as? NSNumber { return n.doubleValue }
      if let s = string("minutes"), let d = Double(s) { return d }
      return nil
    }()
    if let minutes, minutes > 0 {
      let end = fallbackEnd
      return ManualEntry(
        title: title, category: category,
        start: end.addingTimeInterval(-minutes * 60), end: end)
    }

    return nil
  }
}
