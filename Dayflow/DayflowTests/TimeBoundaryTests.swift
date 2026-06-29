//
//  TimeBoundaryTests.swift
//  DayflowTests
//
//  The 4 AM "logical day" boundary used across timeline, productivity, and
//  tasks: times before 4 AM belong to the previous day. Dates are built with
//  Calendar.current so the test is timezone-independent.
//

import XCTest

@testable import Dayflow

@MainActor
final class TimeBoundaryTests: XCTestCase {

  private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute, c.second) = (y, mo, d, h, mi, 0)
    return Calendar.current.date(from: c)!
  }

  private func dayString(_ y: Int, _ mo: Int, _ d: Int) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = Calendar.current.timeZone
    return f.string(from: Calendar.current.startOfDay(for: date(y, mo, d, 12)))
  }

  func testBefore4AMBelongsToPreviousDay() {
    XCTAssertEqual(date(2026, 6, 15, 2, 30).getDayInfoFor4AMBoundary().dayString,
      dayString(2026, 6, 14))
  }

  func testAt4AMBelongsToSameDay() {
    XCTAssertEqual(date(2026, 6, 15, 4, 0).getDayInfoFor4AMBoundary().dayString,
      dayString(2026, 6, 15))
  }

  func testAfter4AMBelongsToSameDay() {
    XCTAssertEqual(date(2026, 6, 15, 10, 0).getDayInfoFor4AMBoundary().dayString,
      dayString(2026, 6, 15))
  }

  func testBoundaryCrossesMonthBoundary() {
    // 1 July, 1 AM is still part of the 30 June logical day.
    XCTAssertEqual(date(2026, 7, 1, 1, 0).getDayInfoFor4AMBoundary().dayString,
      dayString(2026, 6, 30))
  }

  func testStartOfDayIsFourAMAndEndIsTwentyFourHoursLater() {
    let info = date(2026, 6, 15, 10, 0).getDayInfoFor4AMBoundary()
    let cal = Calendar.current
    XCTAssertEqual(cal.component(.hour, from: info.startOfDay), 4)
    XCTAssertEqual(info.endOfDay, cal.date(byAdding: .day, value: 1, to: info.startOfDay))
  }
}
