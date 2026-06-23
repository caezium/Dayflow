//
//  ManualEntry.swift
//  Dayflow
//
//  Manually-logged time, e.g. from a phone Shortcut via the iCloud inbox or the
//  dayflow://log deep link. Stored as a normal timeline card (batch_id = NULL,
//  subcategory "Manual") so it shows in the timeline and daily/weekly views.
//
//  Caveat: because these live in timeline_cards, reprocessing that specific day
//  can remove them. They survive normal use; only an explicit day-reprocess clears them.
//

import Foundation
import GRDB

struct ManualEntry: Sendable {
  var title: String
  var category: String
  var start: Date
  var end: Date
}

extension StorageManager {
  /// Insert a manually-logged time entry as a timeline card. Returns the row id.
  @discardableResult
  func insertManualEntry(_ entry: ManualEntry) -> Int64? {
    let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, entry.end > entry.start else { return nil }

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    let startString = timeFormatter.string(from: entry.start)
    let endString = timeFormatter.string(from: entry.end)
    let startTs = Int(entry.start.timeIntervalSince1970)
    let endTs = Int(entry.end.timeIntervalSince1970)
    let (dayString, _, _) = entry.start.getDayInfoFor4AMBoundary()

    let category = entry.category.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedCategory =
      category.isEmpty
      ? (CategoryPersistence.loadPersistedCategories().first(where: { !$0.isIdle })?.name
        ?? "Personal")
      : category

    var newId: Int64?
    try? timedWrite("insertManualEntry") { db in
      try db.execute(
        sql: """
              INSERT INTO timeline_cards(
                  batch_id, start, end, start_ts, end_ts, day, title,
                  summary, category, subcategory, detailed_summary, metadata
              )
              VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
          """,
        arguments: [
          startString, endString, startTs, endTs, dayString, title,
          "Logged manually.", resolvedCategory, "Manual", "",
        ])
      newId = db.lastInsertedRowID
    }

    if newId != nil {
      NotificationCenter.default.post(name: .timelineDataUpdated, object: nil)
    }
    return newId
  }
}
