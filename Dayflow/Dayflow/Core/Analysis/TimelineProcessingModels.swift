import Foundation

typealias ProcessingAttemptID = String

enum ProcessingAttemptContext {
  @TaskLocal static var id: ProcessingAttemptID?
}

enum AnalysisBatchStatus: String, Sendable {
  case pending
  case processing
  case analyzed
  case completed
  case failed
  case failedEmpty = "failed_empty"
  case skippedShort = "skipped_short"

  var isSuccessful: Bool {
    self == .analyzed || self == .completed
  }
}

enum TimelineFailureCard {
  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func isCanonical(category: String, subcategory: String, title: String) -> Bool {
    normalized(category) == "system"
      && normalized(subcategory) == "error"
      && normalized(title) == "processing failed"
  }

  static func isCanonical(_ card: TimelineCard) -> Bool {
    isCanonical(category: card.category, subcategory: card.subcategory, title: card.title)
  }

  static func isCanonical(_ card: TimelineCardShell) -> Bool {
    isCanonical(category: card.category, subcategory: card.subcategory, title: card.title)
  }

  static func isGeneratedFailureShaped(_ card: ActivityCardData) -> Bool {
    normalized(card.category) == "system"
      || normalized(card.subcategory) == "error"
      || normalized(card.title) == "processing failed"
  }
}

struct ResolvedTimelineClockRange: Sendable, Equatable {
  let start: Date
  let end: Date
}

enum TimelineClockRangeResolver {
  static func resolve(
    start startText: String,
    end endText: String,
    from windowStart: Date,
    to windowEnd: Date,
    calendar: Calendar = .current
  ) -> ResolvedTimelineClockRange? {
    guard windowEnd > windowStart,
      let startMinute = parseTimeHMMA(timeString: startText),
      let endMinute = parseTimeHMMA(timeString: endText)
    else { return nil }

    let anchor = windowStart.addingTimeInterval(windowEnd.timeIntervalSince(windowStart) / 2)

    func closestDate(for minuteOfDay: Int) -> Date? {
      let hour = minuteOfDay / 60
      let minute = minuteOfDay % 60
      guard
        let sameDay = calendar.date(
          bySettingHour: hour, minute: minute, second: 0, of: anchor)
      else { return nil }

      let candidates = [-1, 0, 1].compactMap {
        calendar.date(byAdding: .day, value: $0, to: sameDay)
      }
      return candidates.min {
        abs($0.timeIntervalSince(anchor)) < abs($1.timeIntervalSince(anchor))
      }
    }

    guard let startDate = closestDate(for: startMinute),
      var endDate = closestDate(for: endMinute)
    else { return nil }

    if endDate <= startDate {
      endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
    }
    guard endDate > startDate else { return nil }

    return ResolvedTimelineClockRange(start: startDate, end: endDate)
  }
}

enum TimelineCardSourceAttributor {
  static func sourceBatchId(
    for range: ResolvedTimelineClockRange,
    observations: [Observation],
    processingBatchId: Int64
  ) -> Int64 {
    struct Contribution {
      var overlap: TimeInterval = 0
      var latestEnd: Int = .min
    }

    var contributions: [Int64: Contribution] = [:]
    for observation in observations {
      let observationStart = Date(timeIntervalSince1970: TimeInterval(observation.startTs))
      let observationEnd = Date(timeIntervalSince1970: TimeInterval(observation.endTs))
      let overlapStart = max(range.start, observationStart)
      let overlapEnd = min(range.end, observationEnd)
      guard overlapEnd > overlapStart else { continue }

      // Freshly transcribed observations carry a placeholder batchId of 0
      // ("will be set when saved"). Attributing a card to batch 0 would fail
      // the timeline_cards → analysis_batches foreign key on insert, so fold
      // them into the batch being processed — that's whose transcription
      // produced them.
      let contributingBatchId = observation.batchId > 0 ? observation.batchId : processingBatchId

      var contribution = contributions[contributingBatchId, default: Contribution()]
      contribution.overlap += overlapEnd.timeIntervalSince(overlapStart)
      contribution.latestEnd = max(contribution.latestEnd, observation.endTs)
      contributions[contributingBatchId] = contribution
    }

    guard !contributions.isEmpty else { return processingBatchId }

    return contributions.max { lhs, rhs in
      if lhs.value.overlap != rhs.value.overlap {
        return lhs.value.overlap < rhs.value.overlap
      }
      if lhs.value.latestEnd != rhs.value.latestEnd {
        return lhs.value.latestEnd < rhs.value.latestEnd
      }
      if (lhs.key == processingBatchId) != (rhs.key == processingBatchId) {
        return rhs.key == processingBatchId
      }
      return lhs.key < rhs.key
    }?.key ?? processingBatchId
  }
}

struct ResolvedTimelineCard: Sendable {
  let shell: TimelineCardShell
  let range: ResolvedTimelineClockRange
  let sourceBatchId: Int64
}

struct TimelineSalvageCluster: Sendable, Equatable {
  let start: Date
  let end: Date
  let texts: [String]
}

/// When card generation fails but transcription succeeded, the observations
/// still describe most of the window. These helpers turn them into
/// deterministic "salvage" cards so the processed time isn't lost behind a
/// full-window failure card.
enum TimelinePartialSalvage {
  /// Merges observations into contiguous clusters. A gap larger than `maxGap`
  /// starts a new cluster; clusters shorter than `minDuration` are dropped.
  static func clusters(
    from observations: [Observation],
    maxGap: TimeInterval = 300,
    minDuration: TimeInterval = 60
  ) -> [TimelineSalvageCluster] {
    let usable =
      observations
      .filter { !$0.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { $0.startTs < $1.startTs }
    guard !usable.isEmpty else { return [] }

    var clusters: [TimelineSalvageCluster] = []
    var clusterStart = usable[0].startTs
    var clusterEnd = usable[0].endTs
    var texts = [usable[0].observation.trimmingCharacters(in: .whitespacesAndNewlines)]

    func flush() {
      if TimeInterval(clusterEnd - clusterStart) >= minDuration {
        clusters.append(
          TimelineSalvageCluster(
            start: Date(timeIntervalSince1970: TimeInterval(clusterStart)),
            end: Date(timeIntervalSince1970: TimeInterval(clusterEnd)),
            texts: texts))
      }
    }

    for observation in usable.dropFirst() {
      if TimeInterval(observation.startTs - clusterEnd) > maxGap {
        flush()
        clusterStart = observation.startTs
        clusterEnd = observation.endTs
        texts = [observation.observation.trimmingCharacters(in: .whitespacesAndNewlines)]
      } else {
        clusterEnd = max(clusterEnd, observation.endTs)
        texts.append(observation.observation.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    flush()
    return clusters
  }

  /// Portions of the batch window not covered by any cluster, largest first.
  /// Spans shorter than `minSpan` are ignored — a 2-minute hole isn't worth a
  /// failure card.
  static func uncoveredSpans(
    windowStart: Date,
    windowEnd: Date,
    clusters: [TimelineSalvageCluster],
    minSpan: TimeInterval = 180
  ) -> [ResolvedTimelineClockRange] {
    guard windowEnd > windowStart else { return [] }

    var spans: [ResolvedTimelineClockRange] = []
    var cursor = windowStart
    for cluster in clusters.sorted(by: { $0.start < $1.start }) {
      if cluster.start.timeIntervalSince(cursor) >= minSpan {
        spans.append(ResolvedTimelineClockRange(start: cursor, end: cluster.start))
      }
      cursor = max(cursor, cluster.end)
    }
    if windowEnd.timeIntervalSince(cursor) >= minSpan {
      spans.append(ResolvedTimelineClockRange(start: cursor, end: windowEnd))
    }

    return spans.sorted {
      $0.end.timeIntervalSince($0.start) > $1.end.timeIntervalSince($1.start)
    }
  }

  /// Card title derived from the first observation: its first sentence,
  /// truncated to something that fits a card header.
  static func title(for cluster: TimelineSalvageCluster, maxLength: Int = 60) -> String {
    guard let first = cluster.texts.first, !first.isEmpty else { return "Recovered activity" }
    let sentence =
      first.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
      .first.map(String.init) ?? first
    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxLength else { return trimmed }
    let cut = trimmed.prefix(maxLength)
    let clipped = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
    return clipped + "…"
  }

  /// Card summary: the observations joined, capped so a 15-minute cluster of
  /// verbose notes doesn't overflow the card.
  static func summary(for cluster: TimelineSalvageCluster, maxLength: Int = 600) -> String {
    let joined = cluster.texts.joined(separator: " ")
    guard joined.count > maxLength else { return joined }
    return String(joined.prefix(maxLength)) + "…"
  }
}

struct SuccessfulProcessingCommit: Sendable {
  let processingBatchId: Int64
  let processingAttemptId: ProcessingAttemptID
  let windowStart: Date
  let windowEnd: Date
  let observations: [Observation]
  let cards: [ResolvedTimelineCard]
}

struct FailedProcessingCommit: Sendable {
  let processingBatchId: Int64
  let processingAttemptId: ProcessingAttemptID
  let windowStart: Date
  let windowEnd: Date
  let observations: [Observation]
  /// Nil when salvage cards cover (nearly) the whole window — there is no
  /// meaningful unprocessed span left to hang a Retry on.
  let errorCard: ResolvedTimelineCard?
  /// Deterministic cards built from the successfully transcribed observations,
  /// so the processed portion of a failed batch still shows on the timeline.
  let salvagedCards: [ResolvedTimelineCard]
  let reason: String
}

enum ProcessingCommitOutcome: Sendable {
  case committed(insertedCardIds: [Int64], deletedVideoPaths: [String])
  case stale
}

enum TimelineFailureCauseFamily: String, Sendable {
  case connection
  case timeout
  case invalidResponse = "invalid_response"
  case semanticEmpty = "semantic_empty"
  case missingSource = "missing_source"
  case other
}

enum TimelineFailureCardCopy {
  static func family(for error: Error) -> TimelineFailureCauseFamily {
    if let processingError = error as? TimelineProcessingError {
      switch processingError {
      case .noSemanticOutput: return .semanticEmpty
      case .retrySourceUnavailable: return .missingSource
      case .generatedFailurePlaceholder, .invalidGeneratedCardTime: return .invalidResponse
      case .supersededAttempt: return .other
      }
    }
    return family(forDescription: error.localizedDescription)
  }

  /// Ordered most-specific first: a message like "connection to Ollama timed
  /// out" should classify as timeout, not connection.
  static func family(forDescription description: String) -> TimelineFailureCauseFamily {
    let lower = description.lowercased()

    let missingSource = [
      "no screenshots in batch", "no video recordings found", "no valid screenshot",
      "recordings have been deleted", "no frame descriptions",
    ]
    if missingSource.contains(where: lower.contains) { return .missingSource }

    let semanticEmpty = [
      "no usable activity descriptions", "couldn't identify any activities",
      "produced no observations", "no observations",
    ]
    if semanticEmpty.contains(where: lower.contains) { return .semanticEmpty }

    let timeout = ["timed out", "timeout", "took too long"]
    if timeout.contains(where: lower.contains) { return .timeout }

    let connection = [
      "network connection", "internet connection", "could not connect",
      "unable to connect", "connection refused", "connection reset", "econnreset",
      "socket", "hostname", "tls error", "ssl error", "ollama/lmstudio is running",
      "service unavailable", "502", "503",
    ]
    if connection.contains(where: lower.contains) { return .connection }

    let invalidResponse = [
      "failed to parse", "failed to decode", "unexpected response", "invalid response",
      "processing-failure placeholder", "invalid activity time range", "json",
    ]
    if invalidResponse.contains(where: lower.contains) { return .invalidResponse }

    return .other
  }

  /// Full error-card summary with copy specific to the failure family, so a
  /// connection outage, a hung request, and garbage model output read
  /// differently on the timeline — and a missing-source failure doesn't
  /// promise a reprocess that can never happen.
  static func cardSummary(
    family: TimelineFailureCauseFamily,
    durationMinutes: Int,
    startTime: String,
    endTime: String,
    fallbackDetail: String
  ) -> String {
    let window = "\(durationMinutes) minutes of recording from \(startTime) to \(endTime)"

    switch family {
    case .connection:
      return
        "Dayflow couldn't reach the AI service while processing \(window). Check your internet connection — or that your local model server is running — then press Retry."
    case .timeout:
      return
        "The AI service took too long to respond while processing \(window). This is usually temporary — press Retry to reprocess it."
    case .invalidResponse:
      return
        "The AI returned a response Dayflow couldn't use while processing \(window). This is usually a one-off model glitch — press Retry to reprocess it."
    case .semanticEmpty:
      return
        "The AI examined \(window) but couldn't describe any activity in it. Press Retry to reprocess it — a second pass often succeeds."
    case .missingSource:
      return
        "Dayflow couldn't process \(window), and the original screen recordings are no longer available — so this period can't be reprocessed."
    case .other:
      return
        "Failed to process \(window). \(fallbackDetail) Your recording is safe and can be reprocessed."
    }
  }
}

enum TimelineFrameFailures {
  /// Collapses per-frame error messages into the most common cause so a batch
  /// where every frame failed surfaces why, instead of a generic
  /// "couldn't describe any screenshots".
  static func dominantCause(_ causes: [String]) -> String? {
    let trimmed = causes
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !trimmed.isEmpty else { return nil }

    var counts: [String: Int] = [:]
    for cause in trimmed { counts[cause, default: 0] += 1 }
    return counts.max { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value < rhs.value }
      return lhs.key > rhs.key
    }?.key
  }
}

enum TimelineProcessingError: LocalizedError {
  case generatedFailurePlaceholder
  case noSemanticOutput(frameCount: Int)
  case invalidGeneratedCardTime(start: String, end: String)
  case supersededAttempt
  case retrySourceUnavailable

  var errorDescription: String? {
    switch self {
    case .generatedFailurePlaceholder:
      return "The AI returned a reserved processing-failure placeholder instead of an activity."
    case .noSemanticOutput(let frameCount):
      return "The AI examined \(frameCount) frames but returned no usable activity descriptions."
    case .invalidGeneratedCardTime(let start, let end):
      return "The AI returned an invalid activity time range: \(start)–\(end)."
    case .supersededAttempt:
      return "A newer processing attempt has already replaced this one."
    case .retrySourceUnavailable:
      return "The original screen recordings have been deleted, so this period can't be reprocessed."
    }
  }
}
