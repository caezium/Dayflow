//
//  TodoStoreTests.swift
//  DayflowTests
//
//  The daily task list: add/order/toggle semantics, the auto-done flag, the
//  carry-forward roll of unfinished tasks, and JSON persistence. Each test runs
//  against an isolated UserDefaults suite so nothing touches the real app state.
//

import XCTest

@testable import Dayflow

@MainActor
final class TodoStoreTests: XCTestCase {

  private let day = "2026-06-26"

  /// A throwaway defaults suite + a store on top of it (suite auto-cleaned).
  private func makeStore() -> (store: TodoStore, defaults: UserDefaults, suite: String) {
    let suite = "TodoStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return (TodoStore(defaults: defaults), defaults, suite)
  }

  private func id(of title: String, in store: TodoStore, day: String) -> UUID {
    store.todos(for: day).first { $0.title == title }!.id
  }

  // MARK: - add

  func testAddTrimsWhitespaceAndIgnoresEmpty() {
    let (store, _, _) = makeStore()
    store.add(title: "  Write report  ", day: day)
    store.add(title: "   ", day: day)

    XCTAssertEqual(store.todos(for: day).map { $0.title }, ["Write report"])
  }

  func testAddAssignsIncrementingOrder() {
    let (store, _, _) = makeStore()
    store.add(title: "first", day: day)
    store.add(title: "second", day: day)
    store.add(title: "third", day: day)

    XCTAssertEqual(store.todos(for: day).map { $0.title }, ["first", "second", "third"])
  }

  // MARK: - ordering

  func testOpenTasksSortBeforeDoneTasks() {
    let (store, _, _) = makeStore()
    store.add(title: "first", day: day)
    store.add(title: "second", day: day)
    store.add(title: "third", day: day)

    store.setAutoDone(id(of: "first", in: store, day: day), done: true)

    // "first" is done, so it drops below the still-open tasks.
    XCTAssertEqual(store.todos(for: day).map { $0.title }, ["second", "third", "first"])
  }

  // MARK: - toggle / setAutoDone

  func testToggleClearsAutoCompletedFlag() {
    let (store, _, _) = makeStore()
    store.add(title: "task", day: day)
    let taskId = id(of: "task", in: store, day: day)

    store.setAutoDone(taskId, done: true)
    XCTAssertEqual(store.todos(for: day).first?.autoCompleted, true)

    // A user toggle is an explicit override — it clears the auto flag.
    store.toggle(taskId)
    let item = store.todos(for: day).first { $0.id == taskId }
    XCTAssertEqual(item?.isDone, false)
    XCTAssertEqual(item?.autoCompleted, false)
  }

  func testSetAutoDoneIsNoOpWhenStateUnchanged() {
    let (store, _, _) = makeStore()
    store.add(title: "task", day: day)
    let taskId = id(of: "task", in: store, day: day)

    // Marking an already-open task "not done" changes nothing.
    store.setAutoDone(taskId, done: false)
    let item = store.todos(for: day).first { $0.id == taskId }
    XCTAssertEqual(item?.isDone, false)
    XCTAssertEqual(item?.autoCompleted, false)
  }

  // MARK: - carry forward

  func testCarryForwardMovesOnlyUnfinishedTasksAndIsIdempotent() {
    let (store, _, _) = makeStore()
    let past = "2026-06-24"
    store.add(title: "unfinished", day: past)
    store.add(title: "finished", day: past)
    store.setAutoDone(id(of: "finished", in: store, day: past), done: true)

    let moved = store.carryForwardIncomplete(to: day)
    XCTAssertEqual(moved, 1)

    // The open task rolled forward and is flagged carried; the done one stayed put.
    let today = store.todos(for: day)
    XCTAssertEqual(today.map { $0.title }, ["unfinished"])
    XCTAssertEqual(today.first?.carriedOver, true)
    XCTAssertEqual(store.todos(for: past).map { $0.title }, ["finished"])

    // Running it again moves nothing.
    XCTAssertEqual(store.carryForwardIncomplete(to: day), 0)
  }

  // MARK: - persistence

  func testItemsPersistAcrossReload() {
    let (store, defaults, _) = makeStore()
    store.add(title: "persisted", day: day)

    // A fresh store on the same backing defaults sees the saved item.
    let reloaded = TodoStore(defaults: defaults)
    XCTAssertEqual(reloaded.todos(for: day).map { $0.title }, ["persisted"])
  }
}
