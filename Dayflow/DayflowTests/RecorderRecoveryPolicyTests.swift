import XCTest

@testable import Dayflow

final class RecorderRecoveryPolicyTests: XCTestCase {
  func testMissingDisplayRestartsRecorderEvenWhenStateClaimsCapturing() {
    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: false,
        lastSuccessfulCaptureAt: Date(),
        now: Date(),
        staleAfter: 30
      )
    )
  }

  func testStaleCaptureRestartsRecorderAfterWake() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: true,
        lastSuccessfulCaptureAt: now.addingTimeInterval(-31),
        now: now,
        staleAfter: 30
      )
    )
  }

  func testNonCapturingRecorderRestartsAfterWake() {
    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: false,
        hasDisplay: true,
        lastSuccessfulCaptureAt: Date(),
        now: Date(),
        staleAfter: 30
      )
    )
  }

  func testMissingSuccessfulCaptureRestartsRecorderAfterWake() {
    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: true,
        lastSuccessfulCaptureAt: nil,
        now: Date(),
        staleAfter: 30
      )
    )
  }

  func testRecentCaptureWithDisplayDoesNotRestartRecorder() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertFalse(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: true,
        lastSuccessfulCaptureAt: now.addingTimeInterval(-29),
        now: now,
        staleAfter: 30
      )
    )
  }
}
