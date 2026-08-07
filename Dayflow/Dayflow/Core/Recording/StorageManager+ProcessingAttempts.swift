import Foundation
import GRDB

extension StorageManager {
  func beginProcessingAttempt(batchId: Int64, attemptId: ProcessingAttemptID) throws {
    try timedWrite("beginProcessingAttempt") { db in
      try db.execute(
        sql: """
              UPDATE analysis_batches
              SET status = 'processing', reason = NULL, processing_attempt_id = ?
              WHERE id = ?
          """,
        arguments: [attemptId, batchId])
      guard db.changesCount == 1 else {
        throw TimelineProcessingError.supersededAttempt
      }
    }
  }

  func commitSuccessfulProcessing(_ commit: SuccessfulProcessingCommit) throws
    -> ProcessingCommitOutcome
  {
    try timedWrite("commitSuccessfulProcessing(\(commit.cards.count)_cards)") { db in
      guard try isCurrentAttempt(
        db: db, batchId: commit.processingBatchId, attemptId: commit.processingAttemptId)
      else { return .stale }

      let fromTs = Int(commit.windowStart.timeIntervalSince1970)
      let toTs = Int(commit.windowEnd.timeIntervalSince1970)
      let videoPaths = try replacementVideoPaths(
        db: db, fromTs: fromTs, toTs: toTs, processingBatchId: commit.processingBatchId)

      try softDeleteReplacementRange(
        db: db, fromTs: fromTs, toTs: toTs, processingBatchId: commit.processingBatchId)
      try softDeleteCanonicalFailures(db: db, batchId: commit.processingBatchId)
      try replaceObservations(db: db, batchId: commit.processingBatchId, with: commit.observations)

      let insertedIds = try insertResolvedCards(
        db: db, cards: commit.cards, processingAttemptId: commit.processingAttemptId)
      guard insertedIds.count == commit.cards.count else {
        throw NSError(
          domain: "TimelinePersistence", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Not all generated activity cards were saved."])
      }

      try db.execute(
        sql: """
              UPDATE analysis_batches
              SET status = 'analyzed', reason = NULL
              WHERE id = ? AND processing_attempt_id = ?
          """,
        arguments: [commit.processingBatchId, commit.processingAttemptId])
      guard db.changesCount == 1 else { throw TimelineProcessingError.supersededAttempt }

      return .committed(insertedCardIds: insertedIds, deletedVideoPaths: videoPaths)
    }
  }

  func commitFailedProcessing(_ commit: FailedProcessingCommit) throws -> ProcessingCommitOutcome {
    try timedWrite("commitFailedProcessing") { db in
      guard try isCurrentAttempt(
        db: db, batchId: commit.processingBatchId, attemptId: commit.processingAttemptId)
      else { return .stale }

      let fromTs = Int(commit.windowStart.timeIntervalSince1970)
      let toTs = Int(commit.windowEnd.timeIntervalSince1970)
      let videoPaths = try replacementVideoPaths(
        db: db, fromTs: fromTs, toTs: toTs, processingBatchId: commit.processingBatchId)

      try softDeleteReplacementRange(
        db: db, fromTs: fromTs, toTs: toTs, processingBatchId: commit.processingBatchId)
      try softDeleteCanonicalFailures(db: db, batchId: commit.processingBatchId)
      try replaceObservations(db: db, batchId: commit.processingBatchId, with: commit.observations)

      var cardsToInsert = commit.salvagedCards
      if let errorCard = commit.errorCard {
        cardsToInsert.append(errorCard)
      }
      let insertedIds = try insertResolvedCards(
        db: db, cards: cardsToInsert, processingAttemptId: commit.processingAttemptId)
      guard insertedIds.count == cardsToInsert.count else {
        throw NSError(
          domain: "TimelinePersistence", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The processing failure card wasn't saved."])
      }

      try db.execute(
        sql: """
              UPDATE analysis_batches
              SET status = 'failed', reason = ?
              WHERE id = ? AND processing_attempt_id = ?
          """,
        arguments: [commit.reason, commit.processingBatchId, commit.processingAttemptId])
      guard db.changesCount == 1 else { throw TimelineProcessingError.supersededAttempt }

      return .committed(insertedCardIds: insertedIds, deletedVideoPaths: videoPaths)
    }
  }

  private func isCurrentAttempt(
    db: Database, batchId: Int64, attemptId: ProcessingAttemptID
  ) throws -> Bool {
    let current: String? = try String.fetchOne(
      db,
      sql: "SELECT processing_attempt_id FROM analysis_batches WHERE id = ?",
      arguments: [batchId])
    return current == attemptId
  }

  private func replacementVideoPaths(
    db: Database, fromTs: Int, toTs: Int, processingBatchId: Int64
  ) throws -> [String] {
    try Row.fetchAll(
      db,
      sql: """
            SELECT video_summary_url FROM timeline_cards
            WHERE ((start_ts < ? AND end_ts > ?)
               OR (start_ts >= ? AND start_ts < ?))
              AND video_summary_url IS NOT NULL
              AND is_deleted = 0
              AND NOT (
                lower(trim(category)) = 'system'
                AND lower(trim(subcategory)) = 'error'
                AND lower(trim(title)) = 'processing failed'
                AND batch_id != ?
              )
        """,
      arguments: [toTs, fromTs, fromTs, toTs, processingBatchId]
    ).compactMap { $0["video_summary_url"] as? String }
  }

  private func softDeleteReplacementRange(
    db: Database, fromTs: Int, toTs: Int, processingBatchId: Int64
  ) throws {
    try db.execute(
      sql: """
            UPDATE timeline_cards
            SET is_deleted = 1
            WHERE ((start_ts < ? AND end_ts > ?)
               OR (start_ts >= ? AND start_ts < ?))
              AND is_deleted = 0
              AND NOT (
                lower(trim(category)) = 'system'
                AND lower(trim(subcategory)) = 'error'
                AND lower(trim(title)) = 'processing failed'
                AND batch_id != ?
              )
        """,
      arguments: [toTs, fromTs, fromTs, toTs, processingBatchId])
  }

  private func softDeleteCanonicalFailures(db: Database, batchId: Int64) throws {
    try db.execute(
      sql: """
            UPDATE timeline_cards
            SET is_deleted = 1
            WHERE batch_id = ?
              AND is_deleted = 0
              AND lower(trim(category)) = 'system'
              AND lower(trim(subcategory)) = 'error'
              AND lower(trim(title)) = 'processing failed'
        """,
      arguments: [batchId])
  }

  private func replaceObservations(
    db: Database, batchId: Int64, with observations: [Observation]
  ) throws {
    try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batchId])
    for observation in observations {
      try db.execute(
        sql: """
              INSERT INTO observations(
                batch_id, start_ts, end_ts, observation, metadata, llm_model
              ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          batchId, observation.startTs, observation.endTs, observation.observation,
          observation.metadata, observation.llmModel,
        ])
    }
  }

  private func insertResolvedCards(
    db: Database, cards: [ResolvedTimelineCard], processingAttemptId: ProcessingAttemptID
  ) throws -> [Int64] {
    let encoder = JSONEncoder()
    var insertedIds: [Int64] = []
    insertedIds.reserveCapacity(cards.count)

    for resolved in cards {
      let card = resolved.shell
      let metadata = TimelineMetadata(
        distractions: card.distractions,
        appSites: card.appSites,
        isBackupGenerated: card.isBackupGenerated,
        idle: card.idleMetadata,
        reasoning: card.reasoning)
      let metadataData = try encoder.encode(metadata)
      guard let metadataString = String(data: metadataData, encoding: .utf8) else {
        throw NSError(
          domain: "TimelinePersistence", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Timeline card metadata wasn't valid UTF-8."])
      }

      let startTs = Int(resolved.range.start.timeIntervalSince1970)
      let endTs = Int(resolved.range.end.timeIntervalSince1970)
      let dayString = resolved.range.start.getDayInfoFor4AMBoundary().dayString

      try db.execute(
        sql: """
              INSERT INTO timeline_cards(
                batch_id, start, end, start_ts, end_ts, day, title,
                summary, category, subcategory, detailed_summary, metadata,
                processing_attempt_id
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          resolved.sourceBatchId, card.startTimestamp, card.endTimestamp, startTs, endTs,
          dayString, card.title, card.summary, card.category, card.subcategory,
          card.detailedSummary, metadataString, processingAttemptId,
        ])
      insertedIds.append(db.lastInsertedRowID)
    }

    return insertedIds
  }
}
