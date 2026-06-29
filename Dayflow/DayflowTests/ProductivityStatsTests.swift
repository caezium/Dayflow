//
//  ProductivityStatsTests.swift
//  DayflowTests
//
//  The pure span-bucketing behind the Mini Timer: focused/distracted/idle
//  totals, exclusion of "System" error-placeholder cards (the 48-hour-timer
//  bug), live-segment tracking, and the trailing nudge-window overlap.
//

import XCTest

@testable import Dayflow

@MainActor
final class ProductivityStatsTests: XCTestCase {

  private func span(_ category: String, _ start: Int, _ end: Int) -> TimelineActivitySpan {
    TimelineActivitySpan(category: category, startTs: start, endTs: end)
  }

  private func aggregate(
    _ spans: [TimelineActivitySpan],
    now: Date = Date(timeIntervalSince1970: 1_000_000),
    nudgeWindowSeconds: TimeInterval = 3600
  ) -> ProductivityStats.Aggregation {
    ProductivityStats.aggregate(
      spans: spans,
      idleKey: "idle",
      distractionKey: "distraction",
      systemKey: "system",
      now: now,
      nudgeWindowSeconds: nudgeWindowSeconds)
  }

  func testBucketsByCategory() {
    let result = aggregate([
      span("Work", 0, 100),
      span("Idle", 100, 150),
      span("Distraction", 150, 180),
    ])
    XCTAssertEqual(result.focused, 100)
    XCTAssertEqual(result.idle, 50)
    XCTAssertEqual(result.distracted, 30)
  }

  func testCategoryMatchingIsCaseAndWhitespaceInsensitive() {
    let result = aggregate([span("  WORK  ", 0, 60), span("  idle ", 60, 90)])
    XCTAssertEqual(result.focused, 60)
    XCTAssertEqual(result.idle, 30)
  }

  /// The 48-hour-timer regression: "System" error cards must not count as
  /// focused, and must not become the live segment even when they're latest.
  func testExcludesSystemCardsEntirely() {
    let result = aggregate([
      span("Work", 0, 100),       // ends at 100
      span("System", 200, 5000),  // latest-ending, but an error placeholder
    ])
    XCTAssertEqual(result.focused, 100)
    XCTAssertEqual(result.distracted, 0)
    XCTAssertEqual(result.idle, 0)
    // Live cursor stays on the real work segment, not the System card.
    XCTAssertEqual(result.lastSegmentEnd, Date(timeIntervalSince1970: 100))
    XCTAssertTrue(result.lastSegmentIsFocused)
  }

  func testLatestSegmentDeterminesLiveCursor() {
    let result = aggregate([
      span("Work", 0, 300),
      span("Distraction", 300, 500),  // latest, and not focused
    ])
    XCTAssertEqual(result.lastSegmentEnd, Date(timeIntervalSince1970: 500))
    XCTAssertFalse(result.lastSegmentIsFocused)
  }

  func testSkipsNonPositiveDurations() {
    let result = aggregate([span("Work", 500, 500), span("Work", 600, 400)])
    XCTAssertEqual(result.focused, 0)
    XCTAssertNil(result.lastSegmentEnd)
  }

  func testNudgeWindowCountsOnlyRecentDistraction() {
    let now = Date(timeIntervalSince1970: 10_000)  // window start = 6_400
    let result = aggregate(
      [
        span("Distraction", 6_000, 7_000),  // overlaps window from 6_400 → 600s
        span("Distraction", 9_000, 9_500),  // fully inside → 500s
        span("Distraction", 1_000, 2_000),  // before the window → 0s
      ],
      now: now,
      nudgeWindowSeconds: 3600)
    XCTAssertEqual(result.distracted, 2_500)  // all three count toward the daily total
    XCTAssertEqual(result.distractedInNudgeWindow, 1_100)  // only the recent overlap
  }
}
