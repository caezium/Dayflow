//
//  ProductivityStats.swift
//  Dayflow
//
//  Aggregates today's processed timeline cards into focused / distracted / idle
//  totals and exposes a live-optimistic focused count-up for the Mini Timer.
//
//  Dayflow categorizes activity in batches (~15 min lag), so "live" here means:
//  take everything already analyzed today, then optimistically extend the most
//  recent segment forward to *now* while the user is actively at the machine
//  (recording on, not paused, not idle). When the next batch lands, the processed
//  total absorbs that gap and the live extension shrinks back.
//
//  All time math uses epoch start_ts/end_ts (ground truth) — NOT the display
//  "h:mm a" text, which is timezone-skewed on some cards and otherwise placed the
//  live cursor in the future, freezing the count.
//

import Combine
import CoreGraphics
import Foundation

/// Epoch-based activity span for a timeline card.
struct TimelineActivitySpan: Sendable {
  let category: String
  let startTs: Int
  let endTs: Int
}

@MainActor
final class ProductivityStats: ObservableObject {
  static let shared = ProductivityStats()

  /// Focused seconds from analyzed cards for the current (4 AM boundary) day.
  @Published private(set) var focusedSecondsToday: Double = 0
  /// Distraction seconds from analyzed cards for the current day.
  @Published private(set) var distractedSecondsToday: Double = 0
  /// Idle seconds from analyzed cards for the current day.
  @Published private(set) var idleSecondsToday: Double = 0
  /// Distraction seconds within the trailing nudge window. Drives nudges.
  @Published private(set) var distractedSecondsInNudgeWindow: Double = 0

  /// End of the most recent analyzed card today, used to extend the live count.
  private(set) var lastSegmentEnd: Date?
  /// Whether that most recent segment was focused (so we keep counting up).
  private(set) var lastSegmentIsFocused: Bool = false

  /// Cap on the optimistic forward extension so a stalled analysis pipeline can't
  /// run the counter away indefinitely (slightly above typical batch cadence).
  private let liveExtensionCapSeconds: Double = 30 * 60
  /// Treat the user as away after this much system-wide input inactivity.
  private let idleThresholdSeconds: Double = 5 * 60

  private var timer: Timer?
  private var observer: NSObjectProtocol?

  private init() {}

  func start() {
    recompute()
    let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.recompute() }
    }
    self.timer = timer

    observer = NotificationCenter.default.addObserver(
      forName: .timelineDataUpdated,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.recompute() }
    }
  }

  /// Focused seconds to display, including the live-optimistic extension.
  func liveFocusedSeconds(asOf now: Date) -> Double {
    focusedSecondsToday + liveExtensionSeconds(asOf: now)
  }

  /// Whether the timer is actively counting up right now (for the live dot).
  func isActivelyCounting(asOf now: Date) -> Bool {
    liveExtensionSeconds(asOf: now) > 0
  }

  private func liveExtensionSeconds(asOf now: Date) -> Double {
    guard
      lastSegmentIsFocused,
      let end = lastSegmentEnd,
      AppState.shared.isRecording,
      !PauseManager.shared.isPaused,
      !userIsIdle()
    else { return 0 }
    return min(max(0, now.timeIntervalSince(end)), liveExtensionCapSeconds)
  }

  /// System-wide input idle, via CGEventSource — no permission, no latch.
  /// (Replaces InactivityMonitor.pendingReset, which never clears when the main
  /// window is closed, i.e. in menu-bar-only mode.)
  private func userIsIdle() -> Bool {
    let types: [CGEventType] = [
      .mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel,
    ]
    let idle =
      types
      .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
      .min() ?? .greatestFiniteMagnitude
    return idle >= idleThresholdSeconds
  }

  // MARK: - Recompute

  private func recompute() {
    let now = Date()
    let dayInfo = now.getDayInfoFor4AMBoundary()
    let spans = StorageManager.shared.fetchTimelineActivity(forDay: dayInfo.dayString)

    let idleKey = normalizedCategoryKey(CategoryStore.shared.idleCategory?.name ?? "Idle")
    let distractionKey = normalizedCategoryKey("Distraction")
    // "System" is the category for error/placeholder cards ("Processing failed").
    // They aren't real activity, so they must not count toward any total — otherwise
    // a stalled/failed pipeline (e.g. disk full) inflates the focus timer with dozens
    // of overlapping error cards.
    let systemKey = normalizedCategoryKey("System")

    let result = Self.aggregate(
      spans: spans,
      idleKey: idleKey,
      distractionKey: distractionKey,
      systemKey: systemKey,
      now: now,
      nudgeWindowSeconds: ProductivityPreferences.nudgeWindowSeconds)

    focusedSecondsToday = result.focused
    distractedSecondsToday = result.distracted
    idleSecondsToday = result.idle
    lastSegmentEnd = result.lastSegmentEnd
    lastSegmentIsFocused = result.lastSegmentIsFocused
    distractedSecondsInNudgeWindow = result.distractedInNudgeWindow
  }

  /// The totals a recompute produces. Equatable for straightforward assertions.
  struct Aggregation: Equatable {
    var focused: Double = 0
    var distracted: Double = 0
    var idle: Double = 0
    var distractedInNudgeWindow: Double = 0
    var lastSegmentEnd: Date?
    var lastSegmentIsFocused: Bool = false
  }

  /// Pure aggregation of activity spans into productivity totals — extracted from
  /// `recompute()` so the bucketing can be unit-tested without the storage and
  /// category singletons. "System" (error placeholder) cards are excluded
  /// entirely: they contribute to no total and never become the live segment.
  static func aggregate(
    spans: [TimelineActivitySpan],
    idleKey: String,
    distractionKey: String,
    systemKey: String,
    now: Date,
    nudgeWindowSeconds: TimeInterval
  ) -> Aggregation {
    var result = Aggregation()
    var distractionSpans: [(start: Date, end: Date)] = []
    var latestEnd: Date?

    for span in spans {
      let duration = Double(span.endTs - span.startTs)
      guard duration > 0 else { continue }

      let categoryKey = normalizedCategoryKey(
        span.category.trimmingCharacters(in: .whitespacesAndNewlines))
      // Skip error/system placeholder cards entirely — no total, no live cursor.
      if categoryKey == systemKey { continue }
      let isIdle = categoryKey == idleKey
      let isDistraction = categoryKey == distractionKey

      if isIdle {
        result.idle += duration
      } else if isDistraction {
        result.distracted += duration
        distractionSpans.append(
          (Date(timeIntervalSince1970: TimeInterval(span.startTs)),
            Date(timeIntervalSince1970: TimeInterval(span.endTs))))
      } else {
        result.focused += duration
      }

      let endDate = Date(timeIntervalSince1970: TimeInterval(span.endTs))
      if latestEnd == nil || endDate > latestEnd! {
        latestEnd = endDate
        result.lastSegmentIsFocused = !isIdle && !isDistraction
      }
    }

    result.lastSegmentEnd = latestEnd

    let windowStart = now.addingTimeInterval(-nudgeWindowSeconds)
    result.distractedInNudgeWindow = distractionSpans.reduce(0) { acc, span in
      let overlapStart = max(span.start, windowStart)
      let overlapEnd = min(span.end, now)
      return acc + max(0, overlapEnd.timeIntervalSince(overlapStart))
    }
    return result
  }
}
