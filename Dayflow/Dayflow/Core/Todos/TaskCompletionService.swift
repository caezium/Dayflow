//
//  TaskCompletionService.swift
//  Dayflow
//
//  Uses the configured LLM to infer which of the day's open tasks the user
//  actually completed, based on that day's analyzed activity (timeline cards).
//  Conservative by design — only marks a task done when the activity clearly
//  shows it. Unfinished tasks are left to carry forward.
//

import Foundation

@MainActor
final class TaskCompletionService {
  static let shared = TaskCompletionService()
  private init() {}

  /// Evaluate the open tasks for `day` against that day's activity and mark the
  /// ones that look done. Returns the number marked complete.
  @discardableResult
  func checkCompletion(forDay day: String) async -> Int {
    let openTodos = TodoStore.shared.todos(for: day).filter { !$0.isDone }
    guard !openTodos.isEmpty else { return 0 }

    let cards = StorageManager.shared.fetchTimelineCards(forDay: day)
    guard !cards.isEmpty else { return 0 }

    let activity =
      cards.prefix(60)
      .map { card in
        let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "- \(card.title)\(summary.isEmpty ? "" : ": \(summary)")"
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
      \(activity)

      Return ONLY a JSON array of the task numbers that the activity clearly shows were completed. Be conservative: include a task only if there is clear evidence it was done. If unsure, leave it out. If none, return [].
      Example: [1, 3]
      """

    guard let response = try? await LLMService.shared.generateText(prompt: prompt) else {
      return 0
    }

    let doneNumbers = Self.parseNumberArray(from: response)
    var marked = 0
    for number in doneNumbers {
      let index = number - 1
      guard openTodos.indices.contains(index) else { continue }
      TodoStore.shared.setAutoDone(openTodos[index].id, done: true)
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
