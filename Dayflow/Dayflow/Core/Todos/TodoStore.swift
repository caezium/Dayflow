//
//  TodoStore.swift
//  Dayflow
//
//  A lightweight daily task list. Persisted as JSON in UserDefaults (like
//  CategoryStore) — todos are low-volume, so this avoids a schema migration on
//  the live timeline database. Tasks are scoped to a 4 AM-boundary "day"; undone
//  tasks can be carried forward, and the AI pass (auto task-done) can mark items
//  complete.
//

import Combine
import Foundation

struct TodoItem: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var title: String
  var day: String  // yyyy-MM-dd (4 AM boundary) this task is planned for
  var isDone: Bool = false
  var order: Int = 0
  var createdAt: Date = Date()
  var completedAt: Date? = nil
  /// Marked done by the automatic end-of-day AI pass (vs. checked by the user).
  var autoCompleted: Bool = false
  /// Rolled forward from an earlier day because it wasn't finished.
  var carriedOver: Bool = false
}

@MainActor
final class TodoStore: ObservableObject {
  static let shared = TodoStore()

  private static let storeKey = "todoItems"

  @Published private(set) var items: [TodoItem] = []

  /// Backing store for persistence. Injectable so tests can use an isolated
  /// suite instead of the app-wide standard defaults.
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    load()
  }

  // MARK: - Queries

  /// Today's 4 AM-boundary day string.
  nonisolated static var todayString: String { Date().getDayInfoFor4AMBoundary().dayString }

  func todos(for day: String) -> [TodoItem] {
    items.filter { $0.day == day }.sorted {
      if $0.isDone != $1.isDone { return !$0.isDone }  // open tasks first
      return $0.order < $1.order
    }
  }

  // MARK: - Mutations

  func add(title: String, day: String = TodoStore.todayString) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let nextOrder = (items.filter { $0.day == day }.map { $0.order }.max() ?? -1) + 1
    items.append(TodoItem(title: trimmed, day: day, order: nextOrder))
    save()
  }

  func toggle(_ id: UUID) {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].isDone.toggle()
    items[idx].completedAt = items[idx].isDone ? Date() : nil
    items[idx].autoCompleted = false  // user override
    save()
  }

  func remove(_ id: UUID) {
    items.removeAll { $0.id == id }
    save()
  }

  func rename(_ id: UUID, to title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].title = trimmed
    save()
  }

  /// Mark an item done/undone from the automatic AI pass (won't override a user
  /// who has already explicitly toggled it within the same day).
  func setAutoDone(_ id: UUID, done: Bool) {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    guard items[idx].isDone != done else { return }
    items[idx].isDone = done
    items[idx].completedAt = done ? Date() : nil
    items[idx].autoCompleted = done
    save()
  }

  /// Roll every unfinished task from days before `day` forward onto `day`.
  /// Returns how many were carried. Safe to call repeatedly (idempotent).
  @discardableResult
  func carryForwardIncomplete(to day: String = TodoStore.todayString) -> Int {
    var moved = 0
    for idx in items.indices where !items[idx].isDone && items[idx].day < day {
      items[idx].day = day
      items[idx].carriedOver = true
      moved += 1
    }
    if moved > 0 { save() }
    return moved
  }

  // MARK: - Persistence

  private func load() {
    guard let data = defaults.data(forKey: Self.storeKey) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let decoded = try? decoder.decode([TodoItem].self, from: data) {
      items = decoded
    }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(items) {
      defaults.set(data, forKey: Self.storeKey)
    }
  }
}
