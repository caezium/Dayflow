import Foundation

/// Pure decision logic for recovering the recorder after a wake. Kept free of
/// ScreenRecorder's queues so it can be unit-tested directly.
///
/// Fork patch: upstream's wake handler only resumes a recorder it previously
/// paused (`state == .paused`). On a dark wake — or any sleep where
/// `willSleepNotification` never fired — the state still claims `.capturing`
/// while ScreenCaptureKit is dead, so the wake handler no-ops and the timeline
/// silently stops. This check catches that: a "capturing" recorder with no
/// display or no recent successful capture gets a full restart.
enum RecorderRecoveryPolicy {
  static func shouldRestartAfterWake(
    isCapturing: Bool,
    hasDisplay: Bool,
    lastSuccessfulCaptureAt: Date?,
    now: Date,
    staleAfter: TimeInterval
  ) -> Bool {
    guard isCapturing, hasDisplay, let lastSuccessfulCaptureAt else { return true }
    return now.timeIntervalSince(lastSuccessfulCaptureAt) > staleAfter
  }
}
