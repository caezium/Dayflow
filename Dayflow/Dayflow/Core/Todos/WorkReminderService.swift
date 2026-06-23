//
//  WorkReminderService.swift
//  Dayflow
//
//  A gentle, once-a-day "ready to start?" reminder when you have open tasks for
//  today and you're at the machine during work hours. Complements distraction
//  nudges (which fire while you're working): this fires the rest of the time.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class WorkReminderService {
  static let shared = WorkReminderService()

  private let lastReminderDayKey = "lastWorkReminderDay"
  private let workStartHour = 8
  private let workEndHour = 20
  private let activeWithinSeconds: Double = 5 * 60

  private var timer: Timer?

  private init() {}

  func start() {
    evaluate()
    let timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
    self.timer = timer
  }

  func evaluate() {
    guard ProductivityPreferences.workRemindersEnabled else { return }

    let today = TodoStore.todayString
    guard UserDefaults.standard.string(forKey: lastReminderDayKey) != today else { return }

    let hour = Calendar.current.component(.hour, from: Date())
    guard hour >= workStartHour, hour < workEndHour else { return }

    let openTasks = TodoStore.shared.todos(for: today).filter { !$0.isDone }.count
    guard openTasks > 0 else { return }

    // Only when the user is actually at the machine (recent input).
    guard userIsActive() else { return }

    UserDefaults.standard.set(today, forKey: lastReminderDayKey)
    NotificationService.shared.sendWorkStartReminder(openTasks: openTasks)
  }

  private func userIsActive() -> Bool {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
    let idle =
      types
      .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
      .min() ?? .greatestFiniteMagnitude
    return idle < activeWithinSeconds
  }
}
