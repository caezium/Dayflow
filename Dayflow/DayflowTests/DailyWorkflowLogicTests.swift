//
//  DailyWorkflowLogicTests.swift
//  DayflowTests
//
//  The pure helpers behind the daily workflow grid: minute-range normalization
//  across the 4 AM / midnight wrap, distraction anchoring, category/hex
//  normalization, and the duration/count/hour-label formatters.
//

import XCTest

@testable import Dayflow

@MainActor
final class DailyWorkflowLogicTests: XCTestCase {

  // MARK: - normalizedMinuteRange (4 AM / midnight wrap)

  func testNormalizedMinuteRangeLeavesDaytimeUntouched() {
    let r = normalizedMinuteRange(start: 300, end: 360)  // 5:00–6:00
    XCTAssertEqual(r.start, 300)
    XCTAssertEqual(r.end, 360)
  }

  func testNormalizedMinuteRangeShiftsPostMidnightIntoNextDay() {
    // 23:00 (1380) → 01:00 (60). The end is before 4 AM, so it rolls forward.
    let r = normalizedMinuteRange(start: 1380, end: 60)
    XCTAssertEqual(r.start, 1380)
    XCTAssertEqual(r.end, 1500)  // 60 + 1440
    XCTAssertEqual(r.end - r.start, 120)
  }

  func testNormalizedMinuteRangeForcesEndAfterStart() {
    let r = normalizedMinuteRange(start: 600, end: 600)
    XCTAssertGreaterThan(r.end, r.start)
  }

  // MARK: - distraction anchoring

  func testDistanceToRange() {
    XCTAssertEqual(distanceToRange(5, start: 10, end: 20), 5)   // below
    XCTAssertEqual(distanceToRange(15, start: 10, end: 20), 0)  // inside
    XCTAssertEqual(distanceToRange(25, start: 10, end: 20), 5)  // above
  }

  func testAnchoredMinutePicksNearestDayShift() {
    // raw 10 with a parent late in the day → +1440 shift lands inside the parent.
    XCTAssertEqual(anchoredMinute(10, parentStart: 1400, parentEnd: 1450), 1450)
  }

  func testMiniDistractionRangeKeepsValidRangeInsideParent() {
    let r = normalizedMiniDistractionRange(start: 610, end: 620, parentStart: 600, parentEnd: 660)
    XCTAssertEqual(r?.start, 610)
    XCTAssertEqual(r?.end, 620)
  }

  func testMiniDistractionRangeNilWhenParentDegenerate() {
    XCTAssertNil(normalizedMiniDistractionRange(start: 1, end: 2, parentStart: 600, parentEnd: 600))
  }

  // MARK: - category / hex / distraction key

  func testNormalizedCategoryKeyTrimsAndLowercases() {
    XCTAssertEqual(normalizedCategoryKey("  Work "), "work")
  }

  func testIsDistractionCategoryKey() {
    XCTAssertTrue(isDistractionCategoryKey("Distraction"))
    XCTAssertTrue(isDistractionCategoryKey(" distractions "))
    XCTAssertFalse(isDistractionCategoryKey("Work"))
  }

  func testNormalizedHexStripsHash() {
    XCTAssertEqual(normalizedHex("#FFAA00"), "FFAA00")
    XCTAssertEqual(normalizedHex("FFAA00"), "FFAA00")
  }

  func testFallbackColorHexIsDeterministic() {
    XCTAssertEqual(fallbackColorHex(for: "Work"), fallbackColorHex(for: "Work"))
    XCTAssertFalse(fallbackColorHex(for: "Work").isEmpty)
  }

  // MARK: - parseCardMinute

  func testParseCardMinute() {
    XCTAssertEqual(parseCardMinute("9:00 AM"), 540)
    XCTAssertNil(parseCardMinute("not a time"))
  }

  // MARK: - formatters

  func testFormatAxisHourLabel() {
    XCTAssertEqual(formatAxisHourLabel(fromAbsoluteHour: 0), "12am")
    XCTAssertEqual(formatAxisHourLabel(fromAbsoluteHour: 9), "9am")
    XCTAssertEqual(formatAxisHourLabel(fromAbsoluteHour: 12), "12pm")
    XCTAssertEqual(formatAxisHourLabel(fromAbsoluteHour: 13), "1pm")
    XCTAssertEqual(formatAxisHourLabel(fromAbsoluteHour: 24), "12am")  // wraps
  }

  func testFormatCount() {
    XCTAssertEqual(formatCount(1), "1 time")
    XCTAssertEqual(formatCount(3), "3 times")
  }

  func testFormatDurationValue() {
    XCTAssertEqual(formatDurationValue(0), "0m")
    XCTAssertEqual(formatDurationValue(59), "59m")
    XCTAssertEqual(formatDurationValue(60), "1h")
    XCTAssertEqual(formatDurationValue(90), "1h 30m")
    XCTAssertEqual(formatDurationValue(125), "2h 5m")
  }
}
