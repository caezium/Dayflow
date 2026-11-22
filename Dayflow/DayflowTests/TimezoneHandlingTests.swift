import XCTest

@testable import Dayflow

/// Timezone and daylight saving behaviour of the timeline.
///
/// Changing the Mac's timezone is simulated by setting `NSTimeZone.default`, which
/// `Calendar.current` and formatters with no timezone set follow. `tearDown` restores it.
///
/// `TimeZone.autoupdatingCurrent` does NOT follow `NSTimeZone.default`, so a fix that sets a
/// formatter's zone to `.autoupdatingCurrent` still fails these tests. Leave the formatter's
/// zone unset, or take it from `Calendar.current` on every call; both follow real system changes.
final class TimezoneHandlingTests: XCTestCase {
  private var originalDefaultZone: TimeZone!

  override func setUp() {
    super.setUp()
    originalDefaultZone = NSTimeZone.default
  }

  override func tearDown() {
    NSTimeZone.default = originalDefaultZone
    super.tearDown()
  }

  // MARK: - Logical day (4 AM boundary)

  func testLateNightWorkBelongsToThePreviousDay() {
    let zone = zone("America/Los_Angeles")
    NSTimeZone.default = zone

    let oneThirtyAM = date(2026, 11, 17, hour: 1, minute: 30, in: zone)
    let fourAM = date(2026, 11, 17, hour: 4, minute: 0, in: zone)

    XCTAssertEqual(oneThirtyAM.getDayInfoFor4AMBoundary().dayString, "2026-11-16")
    XCTAssertEqual(fourAM.getDayInfoFor4AMBoundary().dayString, "2026-11-17")
  }

  /// A timezone change must affect the stored logical day without an app relaunch.
  func testDayKeyFollowsTimezoneChangeWhileAppIsRunning() {
    NSTimeZone.default = zone("America/Los_Angeles")
    let tokyo = zone("Asia/Tokyo")
    let tenAMTuesday = date(2026, 11, 17, hour: 10, minute: 0, in: tokyo)

    XCTAssertEqual(tenAMTuesday.getDayInfoFor4AMBoundary().dayString, "2026-11-16")

    NSTimeZone.default = tokyo

    XCTAssertEqual(tenAMTuesday.getDayInfoFor4AMBoundary().dayString, "2026-11-17")
  }

  /// Moving west must preserve the card's stored day and wall-clock time.
  func testTimelineDrawsCardOnItsStoredDayAfterMovingWest() throws {
    NSTimeZone.default = zone("America/Los_Angeles")
    let honolulu = zone("Pacific/Honolulu")
    let card = timelineCard(day: "2026-11-16", start: "3:34 PM", end: "3:49 PM")
    // Warm all formatters before the simulated trip.
    let before = try XCTUnwrap(TimelineActivityLoader.buildActivities(from: [card]).first)
    XCTAssertEqual(Calendar.current.component(.hour, from: before.startTime), 15)

    NSTimeZone.default = honolulu

    let activity = try XCTUnwrap(TimelineActivityLoader.buildActivities(from: [card]).first)
    let parts = calendar(honolulu).dateComponents([.day, .hour, .minute], from: activity.startTime)

    XCTAssertEqual(parts.day, 16)
    XCTAssertEqual(parts.hour, 15)
    XCTAssertEqual(parts.minute, 34)
  }

  // MARK: - Clock label to timestamp

  func testClockLabelResolvesExactlyOnAnOrdinaryDay() {
    // Monday Nov 2, 2026, 3:00 PM in Los Angeles (PST).
    let anchor = epoch("2026-11-02T23:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  func testClockLabelJustAfterMidnightResolvesToTheNextDay() {
    // Batch starts 11:55 PM Nov 2 in Los Angeles; the label is 10 minutes later.
    let anchor = epoch("2026-11-03T07:55:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "12:05 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor + 10 * 60)
  }

  /// Fall-back labels are clock times, not elapsed minutes since midnight.
  func testClockLabelResolvesExactlyOnFallBackDay() {
    // Sunday Nov 1, 2026, 3:00 PM in Los Angeles (PST, after falling back).
    let anchor = epoch("2026-11-01T23:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Spring-forward labels must account for the missing hour.
  func testClockLabelResolvesExactlyOnSpringForwardDay() {
    // Sunday Mar 8, 2026, 3:00 PM in Los Angeles (PDT, after springing forward).
    let anchor = epoch("2026-03-08T22:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// 1:30 AM happens twice on fall-back night. A batch recorded during the second
  /// 1:30 AM should resolve to that one, not the first one an hour earlier.
  func testClockLabelInTheRepeatedHourResolvesToTheNearestOne() {
    // Second 1:30 AM on Nov 1, 2026 in Los Angeles (PST).
    let anchor = epoch("2026-11-01T09:30:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "1:30 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Guards the other half of the repeated hour: a fix that always picks the
  /// second 1:30 AM would break batches recorded during the first one.
  func testClockLabelInTheFirstRepeatedHourStaysOnTheFirstOne() {
    // First 1:30 AM on Nov 1, 2026 in Los Angeles (PDT, before falling back).
    let anchor = epoch("2026-11-01T08:30:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "1:30 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Adjacent-day candidates must use that day's timezone offset.
  func testClockLabelJustBeforeMidnightResolvesToThePreviousDayAfterFallBack() {
    // Batch starts 12:05 AM Monday Nov 2 in Los Angeles (PST); the label is 10 minutes earlier,
    // 11:55 PM on Sunday Nov 1, the day clocks fell back.
    let anchor = epoch("2026-11-02T08:05:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "11:55 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor - 10 * 60)
  }

  // MARK: - Observations

  /// Spring-forward detail lines must stay within the original batch window.
  func testObservationsAreKeptOnSpringForwardDay() {
    NSTimeZone.default = zone("America/Los_Angeles")
    // 3:00 to 3:15 PM PDT on Sunday Mar 8, 2026.
    let windowStart = epoch("2026-03-08T22:00:00Z")
    let windowEnd = windowStart + 15 * 60
    let card = codeReviewCard()

    let observations = OneStepTimelineObservations.make(
      from: [card], windowStart: windowStart, windowEnd: windowEnd, batchId: 1, model: "test")

    XCTAssertEqual(observations.count, 2)
    XCTAssertEqual(observations.first?.startTs, windowStart)
    XCTAssertEqual(observations.last?.endTs, windowEnd)
  }

  /// Fall-back detail lines must stay within the original batch window.
  func testObservationsAreKeptOnFallBackDay() {
    NSTimeZone.default = zone("America/Los_Angeles")
    // 3:00 to 3:15 PM PST on Sunday Nov 1, 2026.
    let windowStart = epoch("2026-11-01T23:00:00Z")
    let windowEnd = windowStart + 15 * 60
    let card = codeReviewCard()

    let observations = OneStepTimelineObservations.make(
      from: [card], windowStart: windowStart, windowEnd: windowEnd, batchId: 1, model: "test")

    XCTAssertEqual(observations.count, 2)
    XCTAssertEqual(observations.first?.startTs, windowStart)
    XCTAssertEqual(observations.last?.endTs, windowEnd)
  }

  // MARK: - Helpers

  private func zone(_ identifier: String) -> TimeZone {
    TimeZone(identifier: identifier)!
  }

  private func calendar(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  private func date(
    _ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int, in zone: TimeZone
  )
    -> Date
  {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return calendar(zone).date(from: components)!
  }

  private func epoch(_ iso8601: String) -> Int {
    Int(ISO8601DateFormatter().date(from: iso8601)!.timeIntervalSince1970)
  }

  /// A 3:00 to 3:15 PM card with two detail lines.
  private func codeReviewCard() -> ActivityCardData {
    ActivityCardData(
      startTime: "3:00 PM",
      endTime: "3:15 PM",
      category: "Work",
      subcategory: "",
      title: "Code review",
      summary: "Reviewed a pull request.",
      detailedSummary: "3:00 PM - 3:05 PM: Read the pull request\n3:05 PM - 3:15 PM: Left comments",
      distractions: nil,
      appSites: nil
    )
  }

  private func timelineCard(day: String, start: String, end: String) -> TimelineCard {
    TimelineCard(
      recordId: 1,
      batchId: 1,
      startTimestamp: start,
      endTimestamp: end,
      category: "Work",
      subcategory: "",
      title: "Review PR",
      summary: "",
      detailedSummary: "",
      day: day,
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil
    )
  }
}
