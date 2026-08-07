import XCTest

@testable import Dayflow

final class TimelineActivityLoaderTests: XCTestCase {
  func testResolveDisplaySegmentsGroupsConsecutiveFailures() {
    let activities = [
      activity(
        id: "failure-3", startMinute: 31, endMinute: 46, title: "Processing failed", batchId: 3),
      activity(
        id: "failure-1", startMinute: 0, endMinute: 15, title: "Processing failed", batchId: 1),
      activity(
        id: "failure-2", startMinute: 15, endMinute: 30, title: "Processing failed", batchId: 2),
    ]

    let segments = TimelineActivityLoader.resolveDisplaySegments(from: activities)

    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].activity.id, "failure-1")
    XCTAssertEqual(segments[0].failureCount, 3)
    XCTAssertEqual(segments[0].batchIds, [1, 2, 3])
    XCTAssertEqual(segments[0].start, date(minute: 0))
    XCTAssertEqual(segments[0].end, date(minute: 46))
  }

  func testResolveDisplaySegmentsDoesNotGroupAcrossAnotherActivity() {
    let activities = [
      activity(
        id: "failure-1", startMinute: 0, endMinute: 15, title: "Processing failed", batchId: 1),
      activity(id: "idle", startMinute: 15, endMinute: 30, title: "Idle"),
      activity(
        id: "failure-2", startMinute: 30, endMinute: 45, title: "Processing failed", batchId: 2),
    ]

    let segments = TimelineActivityLoader.resolveDisplaySegments(from: activities)

    XCTAssertEqual(segments.count, 3)
    XCTAssertEqual(segments.map(\.failureCount), [1, 0, 1])
  }

  func testResolveDisplaySegmentsDoesNotGroupFailuresSeparatedByMoreThanOneMinute() {
    let activities = [
      activity(
        id: "failure-1", startMinute: 0, endMinute: 15, title: "Processing failed", batchId: 1),
      activity(
        id: "failure-2", startMinute: 17, endMinute: 32, title: "Processing failed", batchId: 2),
    ]

    let segments = TimelineActivityLoader.resolveDisplaySegments(from: activities)

    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments.map(\.failureCount), [1, 1])
  }

  private func activity(
    id: String,
    startMinute: Int,
    endMinute: Int,
    title: String,
    batchId: Int64? = nil
  ) -> TimelineActivity {
    TimelineActivity(
      id: id,
      recordId: nil,
      batchId: batchId,
      startTime: date(minute: startMinute),
      endTime: date(minute: endMinute),
      title: title,
      summary: "",
      detailedSummary: "",
      category: title == "Idle" ? "Idle" : "System",
      subcategory: "",
      distractions: nil,
      videoSummaryURL: nil,
      screenshot: nil,
      appSites: nil,
      isBackupGenerated: false
    )
  }

  private func date(minute: Int) -> Date {
    Date(timeIntervalSinceReferenceDate: TimeInterval(minute * 60))
  }

  private func makeCard(
    title: String = "Coding",
    category: String = "Work",
    subcategory: String = "",
    batchId: Int64? = 42,
    summary: String = "Original summary",
    batchStatus: String? = nil
  ) -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: batchId,
      startTimestamp: "9:00 AM",
      endTimestamp: "9:15 AM",
      category: category,
      subcategory: subcategory,
      title: title,
      summary: summary,
      detailedSummary: "Details",
      day: "2026-07-16",
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil,
      batchStatus: batchStatus
    )
  }

  private func makeCanonicalFailureCard(batchStatus: String?) -> TimelineCard {
    makeCard(
      title: "Processing failed", category: "System", subcategory: "Error",
      batchStatus: batchStatus)
  }

  func testFailedCardWithoutSourceFilesIsShownButNotRetryable() {
    let card = makeCard(title: "Processing failed", category: "System")
    let activities = TimelineActivityLoader.buildActivities(
      from: [card], isRetryableFailure: { _ in false })

    XCTAssertEqual(activities.count, 1, "Permanent failures must stay visible, not be hidden")
    XCTAssertFalse(activities[0].isRetryableFailure)
  }

  func testFailedCardWithoutSourceFilesGetsHonestSummary() {
    let card = makeCard(
      title: "Processing failed", category: "System",
      summary: "Your recording is safe and can be reprocessed.")
    let activities = TimelineActivityLoader.buildActivities(
      from: [card], isRetryableFailure: { _ in false })

    XCTAssertTrue(activities[0].summary.contains("can't be reprocessed"))
    XCTAssertFalse(activities[0].summary.contains("can be reprocessed."))
  }

  func testFailedCardWithSourceFilesKeepsRetryAndOriginalSummary() {
    let card = makeCard(title: "Processing failed", category: "System")
    let activities = TimelineActivityLoader.buildActivities(
      from: [card], isRetryableFailure: { _ in true })

    XCTAssertTrue(activities[0].isRetryableFailure)
    XCTAssertEqual(activities[0].summary, "Original summary")
  }

  func testNormalCardNeverConsultsRetryCheckerAndStaysRetryable() {
    var checkerCalls = 0
    let card = makeCard()
    let activities = TimelineActivityLoader.buildActivities(
      from: [card],
      isRetryableFailure: { _ in
        checkerCalls += 1
        return false
      })

    XCTAssertEqual(checkerCalls, 0)
    XCTAssertTrue(activities[0].isRetryableFailure)
    XCTAssertEqual(activities[0].summary, "Original summary")
  }

  func testStaleFailureCardFromSucceededBatchIsHidden() {
    let card = makeCanonicalFailureCard(batchStatus: "analyzed")
    let activities = TimelineActivityLoader.buildActivities(from: [card])

    XCTAssertTrue(
      activities.isEmpty,
      "A failure placeholder left over from a batch that later succeeded must not render")
  }

  func testFailureCardFromStillFailedBatchStaysVisible() {
    let card = makeCanonicalFailureCard(batchStatus: "failed")
    let activities = TimelineActivityLoader.buildActivities(from: [card])

    XCTAssertEqual(activities.count, 1)
  }

  func testFailureCardWithUnknownBatchStatusStaysVisible() {
    let card = makeCanonicalFailureCard(batchStatus: nil)
    let activities = TimelineActivityLoader.buildActivities(from: [card])

    XCTAssertEqual(activities.count, 1)
  }

  func testRetryableFlagSurvivesCategoryChange() {
    let card = makeCard(title: "Processing failed", category: "System")
    let activity = TimelineActivityLoader.buildActivities(
      from: [card], isRetryableFailure: { _ in false })[0]

    XCTAssertFalse(activity.withCategory("Work").isRetryableFailure)
  }
}
