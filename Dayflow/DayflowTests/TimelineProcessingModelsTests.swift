import XCTest

@testable import Dayflow

final class TimelineProcessingModelsTests: XCTestCase {
  func testCanonicalFailureRequiresAllReservedFields() {
    XCTAssertTrue(
      TimelineFailureCard.isCanonical(
        category: " System ", subcategory: "ERROR", title: "processing FAILED"))
    XCTAssertFalse(
      TimelineFailureCard.isCanonical(
        category: "Work", subcategory: "Error", title: "Processing failed"))
    XCTAssertFalse(
      TimelineFailureCard.isCanonical(
        category: "System", subcategory: "", title: "Processing failed"))
  }

  func testGeneratedFailureShapeRejectsAnyReservedComponent() {
    XCTAssertTrue(TimelineFailureCard.isGeneratedFailureShaped(card(category: "System")))
    XCTAssertTrue(TimelineFailureCard.isGeneratedFailureShaped(card(subcategory: "Error")))
    XCTAssertTrue(TimelineFailureCard.isGeneratedFailureShaped(card(title: "Processing failed")))
    XCTAssertFalse(TimelineFailureCard.isGeneratedFailureShaped(card()))
  }

  func testClockResolverHandlesMidnightCrossing() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let windowStart = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 7, day: 16, hour: 23, minute: 30)))
    let windowEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: windowStart))

    let range = try XCTUnwrap(TimelineClockRangeResolver.resolve(
      start: "11:55 PM", end: "12:10 AM", from: windowStart, to: windowEnd,
      calendar: calendar))

    XCTAssertEqual(range.end.timeIntervalSince(range.start), 15 * 60, accuracy: 0.1)
    XCTAssertEqual(calendar.component(.day, from: range.start), 16)
    XCTAssertEqual(calendar.component(.day, from: range.end), 17)
  }

  func testSourceAttributionUsesLargestAggregatedOverlap() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let range = ResolvedTimelineClockRange(
      start: base, end: base.addingTimeInterval(15 * 60))
    let observations = [
      observation(batch: 10, start: base, end: base.addingTimeInterval(6 * 60)),
      observation(
        batch: 10, start: base.addingTimeInterval(6 * 60),
        end: base.addingTimeInterval(12 * 60)),
      observation(
        batch: 11, start: base.addingTimeInterval(12 * 60),
        end: base.addingTimeInterval(15 * 60)),
    ]

    XCTAssertEqual(
      TimelineCardSourceAttributor.sourceBatchId(
        for: range, observations: observations, processingBatchId: 11),
      10)
  }

  func testSourceAttributionPrefersProcessingBatchOnExactTie() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let range = ResolvedTimelineClockRange(
      start: base, end: base.addingTimeInterval(10 * 60))
    let observations = [
      observation(batch: 10, start: base, end: base.addingTimeInterval(5 * 60)),
      observation(
        batch: 11, start: base.addingTimeInterval(5 * 60),
        end: base.addingTimeInterval(10 * 60)),
    ]

    XCTAssertEqual(
      TimelineCardSourceAttributor.sourceBatchId(
        for: range, observations: observations, processingBatchId: 11),
      11)
  }

  func testSourceAttributionFallsBackToProcessingBatch() {
    let range = ResolvedTimelineClockRange(
      start: Date(timeIntervalSince1970: 1_000_000),
      end: Date(timeIntervalSince1970: 1_000_600))
    XCTAssertEqual(
      TimelineCardSourceAttributor.sourceBatchId(
        for: range, observations: [], processingBatchId: 42),
      42)
  }

  func testFailureFamilyClassifiesDistinctCauses() {
    XCTAssertEqual(
      TimelineFailureCardCopy.family(forDescription: "The network connection was lost."),
      .connection)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(forDescription: "The request timed out."),
      .timeout)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(forDescription: "Failed to parse Gemini's response."),
      .invalidResponse)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(forDescription: "The AI produced no observations."),
      .semanticEmpty)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(forDescription: "No screenshots in batch"),
      .missingSource)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(forDescription: "Something inexplicable"),
      .other)
  }

  func testFailureFamilyPrefersTimeoutOverConnectionWording() {
    XCTAssertEqual(
      TimelineFailureCardCopy.family(
        forDescription: "Connection to Ollama timed out after 60 seconds"),
      .timeout)
  }

  func testFailureFamilyMapsProcessingErrorsDirectly() {
    XCTAssertEqual(
      TimelineFailureCardCopy.family(for: TimelineProcessingError.noSemanticOutput(frameCount: 9)),
      .semanticEmpty)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(for: TimelineProcessingError.retrySourceUnavailable),
      .missingSource)
    XCTAssertEqual(
      TimelineFailureCardCopy.family(for: TimelineProcessingError.generatedFailurePlaceholder),
      .invalidResponse)
  }

  func testMissingSourceSummaryDoesNotPromiseReprocessing() {
    let summary = TimelineFailureCardCopy.cardSummary(
      family: .missingSource, durationMinutes: 15, startTime: "9:00 AM", endTime: "9:15 AM",
      fallbackDetail: "ignored")

    XCTAssertTrue(summary.contains("can't be reprocessed"))
    XCTAssertFalse(summary.contains("can be reprocessed"))
  }

  func testConnectionAndTimeoutSummariesReadDifferently() {
    let connection = TimelineFailureCardCopy.cardSummary(
      family: .connection, durationMinutes: 15, startTime: "9:00 AM", endTime: "9:15 AM",
      fallbackDetail: "")
    let timeout = TimelineFailureCardCopy.cardSummary(
      family: .timeout, durationMinutes: 15, startTime: "9:00 AM", endTime: "9:15 AM",
      fallbackDetail: "")

    XCTAssertNotEqual(connection, timeout)
    XCTAssertTrue(connection.contains("couldn't reach"))
    XCTAssertTrue(timeout.contains("too long"))
  }

  func testDominantCausePicksMostFrequentAndIgnoresBlanks() {
    XCTAssertEqual(
      TimelineFrameFailures.dominantCause(
        ["Connection refused", "  ", "Connection refused", "Timed out"]),
      "Connection refused")
    XCTAssertNil(TimelineFrameFailures.dominantCause(["", "   "]))
    XCTAssertNil(TimelineFrameFailures.dominantCause([]))
  }

  func testSourceAttributionNeverReturnsPlaceholderBatchZero() {
    // Fresh (unsaved) observations carry batchId 0; attributing a card to
    // batch 0 breaks the timeline_cards foreign key. Regression for the
    // "SQLite error 19: FOREIGN KEY constraint failed" retry failure.
    let range = ResolvedTimelineClockRange(
      start: Date(timeIntervalSince1970: 1_000_000),
      end: Date(timeIntervalSince1970: 1_000_600))
    let fresh = observation(
      batch: 0,
      start: Date(timeIntervalSince1970: 1_000_000),
      end: Date(timeIntervalSince1970: 1_000_600))

    XCTAssertEqual(
      TimelineCardSourceAttributor.sourceBatchId(
        for: range, observations: [fresh], processingBatchId: 8005),
      8005)
  }

  func testSourceAttributionMergesPlaceholderWithExplicitProcessingBatch() {
    let range = ResolvedTimelineClockRange(
      start: Date(timeIntervalSince1970: 1_000_000),
      end: Date(timeIntervalSince1970: 1_000_700))
    // 300s from a stored batch, 200s placeholder + 200s explicit current-batch:
    // the placeholder folds into the current batch (400s total), which wins.
    let stored = observation(
      batch: 5,
      start: Date(timeIntervalSince1970: 1_000_000),
      end: Date(timeIntervalSince1970: 1_000_300))
    let fresh = observation(
      batch: 0,
      start: Date(timeIntervalSince1970: 1_000_300),
      end: Date(timeIntervalSince1970: 1_000_500))
    let current = observation(
      batch: 8005,
      start: Date(timeIntervalSince1970: 1_000_500),
      end: Date(timeIntervalSince1970: 1_000_700))

    XCTAssertEqual(
      TimelineCardSourceAttributor.sourceBatchId(
        for: range, observations: [stored, fresh, current], processingBatchId: 8005),
      8005)
  }

  // MARK: - Partial salvage

  private func obs(start: Int, end: Int, text: String = "VS Code open, editing tests.")
    -> Observation
  {
    Observation(
      id: nil, batchId: 1, startTs: start, endTs: end, observation: text,
      metadata: nil, llmModel: nil, createdAt: nil)
  }

  func testSalvageClustersMergeAcrossSmallGapsAndSplitOnLargeOnes() {
    let clusters = TimelinePartialSalvage.clusters(
      from: [
        obs(start: 1000, end: 1120),
        obs(start: 1180, end: 1300),  // 60s gap — same cluster
        obs(start: 2000, end: 2200),  // 700s gap — new cluster
      ],
      maxGap: 300, minDuration: 60)

    XCTAssertEqual(clusters.count, 2)
    XCTAssertEqual(Int(clusters[0].start.timeIntervalSince1970), 1000)
    XCTAssertEqual(Int(clusters[0].end.timeIntervalSince1970), 1300)
    XCTAssertEqual(clusters[0].texts.count, 2)
    XCTAssertEqual(Int(clusters[1].start.timeIntervalSince1970), 2000)
  }

  func testSalvageClustersDropShortAndEmptyObservations() {
    let clusters = TimelinePartialSalvage.clusters(
      from: [
        obs(start: 1000, end: 1030),  // 30s — below minDuration
        obs(start: 5000, end: 5400, text: "   "),  // blank — ignored
      ],
      maxGap: 300, minDuration: 60)

    XCTAssertTrue(clusters.isEmpty)
  }

  func testUncoveredSpansFindLargestHoleFirstAndIgnoreSmallOnes() {
    let windowStart = Date(timeIntervalSince1970: 0)
    let windowEnd = Date(timeIntervalSince1970: 900)
    let clusters = [
      TimelineSalvageCluster(
        start: Date(timeIntervalSince1970: 100),
        end: Date(timeIntervalSince1970: 400), texts: ["a"]),
      TimelineSalvageCluster(
        start: Date(timeIntervalSince1970: 450),
        end: Date(timeIntervalSince1970: 500), texts: ["b"]),
    ]

    let spans = TimelinePartialSalvage.uncoveredSpans(
      windowStart: windowStart, windowEnd: windowEnd, clusters: clusters, minSpan: 180)

    // Leading 100s hole and the 50s gap are below threshold; only the 400s tail counts.
    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(Int(spans[0].start.timeIntervalSince1970), 500)
    XCTAssertEqual(Int(spans[0].end.timeIntervalSince1970), 900)
  }

  func testUncoveredSpansFullWindowWhenNoClusters() {
    let spans = TimelinePartialSalvage.uncoveredSpans(
      windowStart: Date(timeIntervalSince1970: 0),
      windowEnd: Date(timeIntervalSince1970: 900),
      clusters: [], minSpan: 180)

    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(Int(spans[0].end.timeIntervalSince1970) - Int(spans[0].start.timeIntervalSince1970), 900)
  }

  func testSalvageTitleUsesFirstSentenceAndTruncatesOnWordBoundary() {
    let short = TimelineSalvageCluster(
      start: Date(), end: Date(), texts: ["Gmail compose window open. Writing to a client."])
    XCTAssertEqual(TimelinePartialSalvage.title(for: short), "Gmail compose window open")

    let long = TimelineSalvageCluster(
      start: Date(), end: Date(),
      texts: [String(repeating: "word ", count: 30)])
    let title = TimelinePartialSalvage.title(for: long)
    XCTAssertTrue(title.hasSuffix("…"))
    XCTAssertLessThanOrEqual(title.count, 62)
  }

  func testSalvageSummaryCapsLength() {
    let cluster = TimelineSalvageCluster(
      start: Date(), end: Date(), texts: Array(repeating: String(repeating: "x", count: 100), count: 10))
    XCTAssertLessThanOrEqual(TimelinePartialSalvage.summary(for: cluster).count, 601)
  }

  private func card(
    category: String = "Work", subcategory: String = "Coding", title: String = "Build feature"
  ) -> ActivityCardData {
    ActivityCardData(
      startTime: "9:00 AM", endTime: "9:15 AM", category: category,
      subcategory: subcategory, title: title, summary: "Summary", detailedSummary: "Details",
      distractions: nil, appSites: nil)
  }

  private func observation(batch: Int64, start: Date, end: Date) -> Observation {
    Observation(
      id: nil, batchId: batch, startTs: Int(start.timeIntervalSince1970),
      endTs: Int(end.timeIntervalSince1970), observation: "Work", metadata: nil,
      llmModel: nil, createdAt: nil)
  }
}
