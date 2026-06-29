//
//  TaskCompletionServiceTests.swift
//  DayflowTests
//
//  Behavior of the AI task-completion pass: which open tasks get marked done
//  from activity, when the LLM is (not) consulted, and how the per-batch
//  trigger is gated + debounced.
//

import XCTest

@testable import Dayflow

@MainActor
final class TaskCompletionServiceTests: XCTestCase {

  private let day = "2026-06-26"

  // MARK: - Test doubles

  /// Records how often it was asked to generate, and returns a canned reply.
  private final class FakeLLM {
    var response: String
    private(set) var callCount = 0
    init(response: String) { self.response = response }
    func generate(_ prompt: String) async throws -> String {
      callCount += 1
      return response
    }
  }

  /// A clock the test can advance by hand.
  private final class TestClock {
    var current: Date
    init(_ start: Date) { current = start }
    func date() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
  }

  /// A TodoStore backed by a throwaway defaults suite (auto-cleaned).
  private func makeStore() -> TodoStore {
    let suiteName = "TaskCompletionTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return TodoStore(defaults: defaults)
  }

  private func isDone(_ title: String, in store: TodoStore) -> Bool {
    store.todos(for: day).first { $0.title == title }?.isDone ?? false
  }

  private func item(_ title: String, in store: TodoStore) -> TodoItem? {
    store.todos(for: day).first { $0.title == title }
  }

  // MARK: - parseNumberArray

  func testParseNumberArrayExtractsNumbers() {
    XCTAssertEqual(TaskCompletionService.parseNumberArray(from: "[1, 3]"), [1, 3])
  }

  func testParseNumberArrayToleratesCodeFenceAndProse() {
    let reply = "Sure, here you go:\n```json\n[2, 4, 5]\n```"
    XCTAssertEqual(TaskCompletionService.parseNumberArray(from: reply), [2, 4, 5])
  }

  func testParseNumberArrayReturnsEmptyWhenNoArray() {
    XCTAssertEqual(TaskCompletionService.parseNumberArray(from: "none were done"), [])
    XCTAssertEqual(TaskCompletionService.parseNumberArray(from: "[]"), [])
  }

  // MARK: - checkCompletion marking

  func testMarksOnlyTasksTheLLMReports() async {
    let store = makeStore()
    store.add(title: "Write report", day: day)
    store.add(title: "Email Bob", day: day)
    store.add(title: "Review PR", day: day)

    let fake = FakeLLM(response: "[1, 3]")
    let service = TaskCompletionService(
      store: store,
      fetchActivity: { _ in [("Wrote the report", "Finished the Q3 report")] },
      generate: fake.generate)

    let marked = await service.checkCompletion(forDay: day)

    XCTAssertEqual(marked, 2)
    XCTAssertTrue(isDone("Write report", in: store))
    XCTAssertFalse(isDone("Email Bob", in: store))
    XCTAssertTrue(isDone("Review PR", in: store))
    // Auto-detected completions are flagged as such (vs. a user check).
    XCTAssertEqual(item("Write report", in: store)?.autoCompleted, true)
  }

  func testIgnoresOutOfRangeTaskNumbers() async {
    let store = makeStore()
    store.add(title: "Only task", day: day)

    let fake = FakeLLM(response: "[9]")
    let service = TaskCompletionService(
      store: store,
      fetchActivity: { _ in [("Some activity", "")] },
      generate: fake.generate)

    let marked = await service.checkCompletion(forDay: day)

    XCTAssertEqual(marked, 0)
    XCTAssertFalse(isDone("Only task", in: store))
  }

  // MARK: - gating (don't waste an LLM call)

  func testSkipsLLMWhenNoOpenTasks() async {
    let store = makeStore()  // empty
    let fake = FakeLLM(response: "[1]")
    let service = TaskCompletionService(
      store: store,
      fetchActivity: { _ in [("Activity", "")] },
      generate: fake.generate)

    let marked = await service.checkCompletion(forDay: day)

    XCTAssertEqual(marked, 0)
    XCTAssertEqual(fake.callCount, 0, "must not call the LLM when there are no open tasks")
  }

  func testSkipsLLMWhenNoActivity() async {
    let store = makeStore()
    store.add(title: "A task", day: day)
    let fake = FakeLLM(response: "[1]")
    let service = TaskCompletionService(
      store: store,
      fetchActivity: { _ in [] },
      generate: fake.generate)

    let marked = await service.checkCompletion(forDay: day)

    XCTAssertEqual(marked, 0)
    XCTAssertEqual(fake.callCount, 0, "must not call the LLM when there is no activity")
  }

  // MARK: - per-batch trigger: gate + debounce

  func testHandleBatchProcessedSkipsWhenNoOpenTasks() async {
    let store = makeStore()  // no open tasks
    let fake = FakeLLM(response: "[]")
    let service = TaskCompletionService(
      store: store,
      fetchActivity: { _ in [("Activity", "")] },
      generate: fake.generate)

    _ = await service.handleBatchProcessed(forDay: day)

    XCTAssertEqual(fake.callCount, 0)
  }

  func testHandleBatchProcessedDebouncesWithinInterval() async {
    let store = makeStore()
    store.add(title: "Ongoing task", day: day)

    let fake = FakeLLM(response: "[]")  // never marks done, so the task stays open
    let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
    let service = TaskCompletionService(
      store: store,
      fetchActivity: { _ in [("Activity", "")] },
      generate: fake.generate,
      now: clock.date,
      debounceInterval: 300)

    _ = await service.handleBatchProcessed(forDay: day)  // runs
    _ = await service.handleBatchProcessed(forDay: day)  // debounced
    XCTAssertEqual(fake.callCount, 1, "second batch within the interval should be debounced")

    clock.advance(301)
    _ = await service.handleBatchProcessed(forDay: day)  // interval elapsed → runs again
    XCTAssertEqual(fake.callCount, 2)
  }
}
