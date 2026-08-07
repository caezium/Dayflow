//
//  MonthTimelineTests.swift
//  DayflowTests
//
//  Month range grid math (padding to whole weeks, 4 AM boundaries) and the
//  per-day aggregation behind the Month view drafts.
//

import XCTest

@testable import Dayflow

@MainActor
final class MonthTimelineTests: XCTestCase {

  // MARK: - TimelineMonthRange

  func testGridDaysCoverWholeWeeksAndFlagInMonthDays() {
    let july = DateComponents(
      calendar: .current, year: 2026, month: 7, day: 15, hour: 12
    ).date!
    let range = TimelineMonthRange.containing(july)

    XCTAssertEqual(range.gridDays.count % 7, 0)
    XCTAssertEqual(range.gridDays.filter(\.isInMonth).count, 31)
    XCTAssertGreaterThanOrEqual(range.gridDays.count, 31)
    XCTAssertEqual(range.title, "July 2026")
  }

  func testGridInMonthDaysAreSequentialDayStrings() {
    let feb = DateComponents(
      calendar: .current, year: 2026, month: 2, day: 10, hour: 12
    ).date!
    let range = TimelineMonthRange.containing(feb)
    let inMonth = range.gridDays.filter(\.isInMonth)

    XCTAssertEqual(inMonth.count, 28)
    XCTAssertEqual(inMonth.first?.dayString, "2026-02-01")
    XCTAssertEqual(inMonth.last?.dayString, "2026-02-28")
  }

  func testShiftByMonthNavigatesAndContainsWork() {
    let july = DateComponents(
      calendar: .current, year: 2026, month: 7, day: 15, hour: 12
    ).date!
    let range = TimelineMonthRange.containing(july)
    let june = range.shifted(byMonths: -1)

    XCTAssertEqual(june.title, "June 2026")
    XCTAssertTrue(june.contains(DateComponents(
      calendar: .current, year: 2026, month: 6, day: 30, hour: 12).date!))
    XCTAssertFalse(june.contains(july))
  }

  func testEarlyMorningBelongsToPreviousMonthsLastDay() {
    // 2 AM on Aug 1 is still "July 31" under the 4 AM day boundary.
    let earlyAug = DateComponents(
      calendar: .current, year: 2026, month: 8, day: 1, hour: 2
    ).date!
    XCTAssertEqual(TimelineMonthRange.containing(earlyAug).title, "July 2026")
  }

  // MARK: - MonthOverviewBuilder

  private func activity(
    title: String = "Coding",
    category: String = "Work",
    dayHour: (day: Int, hour: Int) = (15, 10),
    minutes: Int = 60
  ) -> TimelineActivity {
    let start = DateComponents(
      calendar: .current, year: 2026, month: 7, day: dayHour.day, hour: dayHour.hour
    ).date!
    return TimelineActivity(
      id: UUID().uuidString, recordId: nil, batchId: nil,
      startTime: start, endTime: start.addingTimeInterval(TimeInterval(minutes * 60)),
      title: title, summary: "", detailedSummary: "",
      category: category, subcategory: "",
      distractions: nil, videoSummaryURL: nil, screenshot: nil, appSites: nil,
      isBackupGenerated: nil)
  }

  func testBuildAggregatesPerDayAndPicksLongestTitle() {
    let summaries = MonthOverviewBuilder.build(activities: [
      activity(title: "Short task", minutes: 30),
      activity(title: "Long task", minutes: 90),
      activity(title: "Other day", dayHour: (16, 10), minutes: 45),
    ])

    XCTAssertEqual(summaries["2026-07-15"]?.totalMinutes, 120)
    XCTAssertEqual(summaries["2026-07-15"]?.topActivityTitle, "Long task")
    XCTAssertEqual(summaries["2026-07-16"]?.totalMinutes, 45)
  }

  func testBuildExcludesSystemCardsEntirely() {
    let summaries = MonthOverviewBuilder.build(activities: [
      activity(title: "Processing failed", category: "System", minutes: 15)
    ])

    XCTAssertTrue(summaries.isEmpty)
  }

  func testBuildKeepsIdleOutOfTotalsButInSlices() {
    let summaries = MonthOverviewBuilder.build(activities: [
      activity(title: "Working", category: "Work", minutes: 60),
      activity(title: "Away", category: "Idle", minutes: 30),
    ])

    let day = summaries["2026-07-15"]
    XCTAssertEqual(day?.totalMinutes, 60)
    XCTAssertEqual(day?.topActivityTitle, "Working")
    XCTAssertTrue(day?.categorySlices.contains(where: { $0.category == "Idle" }) ?? false)
  }

  func testBuildGroupsEarlyMorningIntoPreviousDay() {
    let summaries = MonthOverviewBuilder.build(activities: [
      activity(title: "Late night", dayHour: (16, 2), minutes: 30)
    ])

    XCTAssertEqual(summaries["2026-07-15"]?.totalMinutes, 30)
    XCTAssertNil(summaries["2026-07-16"])
  }
}
