//
//  ProcessingControl.swift
//  Dayflow
//
//  User-facing on/off switch for the AI analysis pipeline ("Stop all processing").
//  Recording is unaffected — this only halts the LLM processing of captured
//  screenshots. The choice persists across launches so a stop sticks until the
//  user resumes. The actual halt/restart is delegated to AnalysisManager.
//

import Combine
import Foundation

@MainActor
final class ProcessingControl: ObservableObject {
  static let shared = ProcessingControl()
  private let key = "processingStopped"

  @Published private(set) var isStopped: Bool

  private init() {
    isStopped = UserDefaults.standard.bool(forKey: key)
  }

  /// Reconcile AnalysisManager with the persisted state. Call at launch *before*
  /// AnalysisManager.startAnalysisJob() so a persisted stop is honored.
  func applyOnLaunch() {
    if isStopped { AnalysisManager.shared.stopAllProcessing() }
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    UserDefaults.standard.set(true, forKey: key)
    AnalysisManager.shared.stopAllProcessing()
    AnalyticsService.shared.capture("processing_stopped")
  }

  func resume() {
    guard isStopped else { return }
    isStopped = false
    UserDefaults.standard.set(false, forKey: key)
    AnalysisManager.shared.resumeProcessing()
    AnalyticsService.shared.capture("processing_resumed")
  }

  func toggle() { isStopped ? resume() : stop() }
}
