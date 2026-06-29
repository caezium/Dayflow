//
//  TaskCompletionService.swift
//  Dayflow
//
//  Uses the configured LLM to infer which of the day's open tasks the user
//  actually completed, based on that day's analyzed activity (timeline cards).
//  Conservative by design — only marks a task done when the activity clearly
//  shows it. Unfinished tasks are left to carry forward.
//
//  Triggered two ways:
//   • `handleBatchProcessed(forDay:)` — fired automatically each time the
//     analysis pipeline finishes a batch, so completions show up shortly after
//     the work happens (not just once a day). Debounced + gated so a burst of
//     processed batches can't spam the LLM.
//   • `checkCompletion(forDay:)` — the unconditional check behind the manual
//     "Detect done" button and the once-a-day catch-up flow.
//
//  Dependencies are injected (defaulting to the live singletons) so the
//  completion logic is testable with a fake LLM and in-memory activity.
//

import Foundation

@MainActor
final class TaskCompletionService {
  static let shared = TaskCompletionService()

  /// A single line of analyzed activity the LLM reasons over.
  typealias Activity = (title: String, summary: String)

  private let store: TodoStore
  private let fetchActivity: (String) -> [Activity]
  private let generate: (String) async throws -> String
  private let now: () -> Date
  private let debounceInterval: TimeInterval

  /// Per-day timestamp of the last auto check we *started*, used to debounce the
  /// per-batch trigger. Manual/daily checks bypass this.
  private var lastAutoCheckAt: [String: Date] = [:]

  init(
    store: TodoStore = .shared,
    fetchActivity: @escaping (String) -> [Activity] = { day in
      StorageManager.shared.fetchTimelineCards(forDay: day).map { ($0.title, $0.summary) }
    },
    generate: @escaping (String) async throws -> String = { prompt in
      try await LLMService.shared.generateText(prompt: prompt)
    },
    now: @escaping () -> Date = Date.init,
    debounceInterval: TimeInterval = 5 * 60
  ) {
    self.store = store
    self.fetchActivity = fetchActivity
    self.generate = generate
    self.now = now
    self.debounceInterval = debounceInterval
  }

  /// Called when the analysis pipeline finishes a batch for `day`. Gated so it
  /// only hits the LLM when there are open tasks, and debounced so at most one
  /// check runs per `debounceInterval` per day. Returns the number newly marked
  /// done (0 when skipped).
  @discardableResult
  func handleBatchProcessed(forDay day: String) async -> Int {
    // Gate: nothing to infer if there are no open tasks for the day.
    guard store.todos(for: day).contains(where: { !$0.isDone }) else { return 0 }

    // Debounce: skip if we already kicked off a check for this day recently.
    if let last = lastAutoCheckAt[day], now().timeIntervalSince(last) < debounceInterval {
      return 0
    }
    lastAutoCheckAt[day] = now()
    return await checkCompletion(forDay: day)
  }

  /// Evaluate the open tasks for `day` against that day's activity and mark the
  /// ones that look done. Returns the number marked complete. Always runs (no
  /// debounce) — this is the explicit "check now" path.
  @discardableResult
  func checkCompletion(forDay day: String) async -> Int {
    let openTodos = store.todos(for: day).filter { !$0.isDone }
    guard !openTodos.isEmpty else { return 0 }

    let activity = fetchActivity(day)
    guard !activity.isEmpty else { return 0 }

    let activityText =
      activity.prefix(60)
      .map { item in
        let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "- \(item.title)\(summary.isEmpty ? "" : ": \(summary)")"
      }
      .joined(separator: "\n")

    let taskLines = openTodos.enumerated()
      .map { "\($0.offset + 1). \($0.element.title)" }
      .joined(separator: "\n")

    let prompt = """
      You are checking which of the user's planned tasks they actually completed today, based on what they did.

      TASKS (by number):
      \(taskLines)

      WHAT THEY DID TODAY (activity):
      \(activityText)

      Return ONLY a JSON array of the task numbers that the activity clearly shows were completed. Be conservative: include a task only if there is clear evidence it was done. If unsure, leave it out. If none, return [].
      Example: [1, 3]
      """

    guard let response = try? await generate(prompt) else { return 0 }

    let doneNumbers = Self.parseNumberArray(from: response)
    var marked = 0
    for number in Set(doneNumbers) {
      let index = number - 1
      guard openTodos.indices.contains(index) else { continue }
      store.setAutoDone(openTodos[index].id, done: true)
      marked += 1
    }
    return marked
  }

  /// Extract a JSON array of integers from an LLM response, tolerating code
  /// fences and surrounding prose.
  static func parseNumberArray(from text: String) -> [Int] {
    guard
      let open = text.firstIndex(of: "["),
      let close = text[open...].firstIndex(of: "]")
    else { return [] }
    let inner = text[text.index(after: open)..<close]
    return
      inner
      .split(whereSeparator: { !$0.isNumber })
      .compactMap { Int($0) }
  }
}
