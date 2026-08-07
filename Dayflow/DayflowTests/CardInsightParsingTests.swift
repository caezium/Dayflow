//
//  CardInsightParsingTests.swift
//  DayflowTests
//
//  Best-effort extraction of the model's `reasoning` field from a raw
//  card-generation response — bare JSON, code-fenced JSON, and the OpenAI /
//  Gemini envelope shapes — plus graceful nils for junk.
//

import XCTest

@testable import Dayflow

@MainActor
final class CardInsightParsingTests: XCTestCase {

  private func reasoning(_ raw: String?) -> String? {
    CardInsight.extractReasoning(fromModelResponse: raw)
  }

  func testExtractsFromBareJSONObject() {
    XCTAssertEqual(reasoning(#"{"reasoning": "grouped by app"}"#), "grouped by app")
  }

  func testExtractsFromCodeFencedJSON() {
    let raw = "```json\n{\"reasoning\": \"fenced value\"}\n```"
    XCTAssertEqual(reasoning(raw), "fenced value")
  }

  func testExtractsFromOpenAIEnvelope() {
    let raw = #"{"choices":[{"message":{"content":"{\"reasoning\":\"from openai\"}"}}]}"#
    XCTAssertEqual(reasoning(raw), "from openai")
  }

  func testExtractsFromGeminiEnvelope() {
    let raw = #"{"candidates":[{"content":{"parts":[{"text":"{\"reasoning\":\"from gemini\"}"}]}}]}"#
    XCTAssertEqual(reasoning(raw), "from gemini")
  }

  func testReturnsNilForNilOrEmpty() {
    XCTAssertNil(reasoning(nil))
    XCTAssertNil(reasoning(""))
  }

  func testReturnsNilWhenNoReasoningField() {
    XCTAssertNil(reasoning(#"{"title": "Something"}"#))
    XCTAssertNil(reasoning("not json at all"))
  }

  func testReturnsNilForWhitespaceOnlyReasoning() {
    XCTAssertNil(reasoning(#"{"reasoning": "   "}"#))
  }

  // MARK: - Attempt grouping

  private func entry(id: Int64, attemptId: String?, operation: String = "transcribe")
    -> LLMCallDebugEntry
  {
    LLMCallDebugEntry(
      id: id, createdAt: nil, batchId: 7, processingAttemptId: attemptId, callGroupId: nil,
      attempt: 1, provider: "gemini", model: "gemini-2.0", operation: operation,
      status: "success", latencyMs: nil, httpStatus: nil, requestMethod: nil, requestURL: nil,
      requestBody: nil, responseBody: nil, errorDomain: nil, errorCode: nil, errorMessage: nil)
  }

  func testGroupsCallsByAttemptInChronologicalOrder() {
    let calls = [
      entry(id: 30, attemptId: "attempt-B"),
      entry(id: 10, attemptId: "attempt-A"),
      entry(id: 31, attemptId: "attempt-B"),
      entry(id: 11, attemptId: "attempt-A"),
    ]

    let groups = CardInsight.groupCallsByAttempt(calls)

    XCTAssertEqual(groups.map(\.attemptId), ["attempt-A", "attempt-B"])
    XCTAssertEqual(groups[0].calls.map(\.id), [10, 11])
    XCTAssertEqual(groups[1].calls.map(\.id), [30, 31])
  }

  func testLegacyCallsWithoutAttemptIdFormTheirOwnGroup() {
    let calls = [
      entry(id: 1, attemptId: nil),
      entry(id: 2, attemptId: "attempt-A"),
    ]

    let groups = CardInsight.groupCallsByAttempt(calls)

    XCTAssertEqual(groups.count, 2)
    XCTAssertNil(groups[0].attemptId)
    XCTAssertEqual(groups[1].attemptId, "attempt-A")
  }

  func testEmptyCallListGroupsToNothing() {
    XCTAssertTrue(CardInsight.groupCallsByAttempt([]).isEmpty)
  }
}
