//
//  ProductivityPreferences.swift
//  Dayflow
//
//  UserDefaults-backed settings for the focus Mini Timer and distraction nudges.
//  Kept separate from NotificationPreferences (which is journal-reminder specific).
//

import Foundation

enum ProductivityPreferences {
  private static let defaults = UserDefaults.standard

  // MARK: - Keys
  private static let miniTimerEnabledKey = "miniTimerEnabled"
  private static let miniTimerOriginXKey = "miniTimerOriginX"
  private static let miniTimerOriginYKey = "miniTimerOriginY"
  private static let distractionNudgesEnabledKey = "distractionNudgesEnabled"
  private static let nudgeThresholdMinutesKey = "nudgeThresholdMinutes"
  private static let nudgeCooldownMinutesKey = "nudgeCooldownMinutes"

  // MARK: - Nudge tuning (user-configurable in Settings)

  /// Choices shown in Settings for how much distraction triggers a nudge.
  static let nudgeThresholdMinuteOptions = [5, 10, 15, 20, 30, 45, 60]
  /// Choices shown in Settings for the minimum gap between nudges.
  static let nudgeCooldownMinuteOptions = [15, 30, 60, 120, 240]

  /// Minutes of distraction (within the trailing window) before a nudge. Default 20.
  static var nudgeThresholdMinutes: Int {
    get {
      if defaults.object(forKey: nudgeThresholdMinutesKey) == nil { return 20 }
      return defaults.integer(forKey: nudgeThresholdMinutesKey)
    }
    set { defaults.set(newValue, forKey: nudgeThresholdMinutesKey) }
  }

  /// Minimum minutes between two nudges. Default 60.
  static var nudgeCooldownMinutes: Int {
    get {
      if defaults.object(forKey: nudgeCooldownMinutesKey) == nil { return 60 }
      return defaults.integer(forKey: nudgeCooldownMinutesKey)
    }
    set { defaults.set(newValue, forKey: nudgeCooldownMinutesKey) }
  }

  /// Distraction within the trailing window required to fire a nudge.
  static var nudgeThresholdSeconds: Double { Double(nudgeThresholdMinutes * 60) }
  /// Trailing window the nudge looks back over — at least 30 min, and never
  /// shorter than the threshold (so a high threshold can still fire).
  static var nudgeWindowSeconds: Double { max(30 * 60, nudgeThresholdSeconds) }
  /// Minimum gap between two nudges so we never spam the user.
  static var nudgeCooldownSeconds: Double { Double(nudgeCooldownMinutes * 60) }

  // MARK: - Mini Timer

  /// Whether the floating focus timer is shown. Default off so the app stays
  /// unobtrusive until the user opts in from the menu bar or Settings.
  static var miniTimerEnabled: Bool {
    get { defaults.bool(forKey: miniTimerEnabledKey) }
    set { defaults.set(newValue, forKey: miniTimerEnabledKey) }
  }

  /// Saved bottom-left origin of the timer panel, or nil if never moved.
  static var miniTimerOrigin: CGPoint? {
    get {
      guard
        defaults.object(forKey: miniTimerOriginXKey) != nil,
        defaults.object(forKey: miniTimerOriginYKey) != nil
      else { return nil }
      return CGPoint(
        x: defaults.double(forKey: miniTimerOriginXKey),
        y: defaults.double(forKey: miniTimerOriginYKey)
      )
    }
    set {
      if let point = newValue {
        defaults.set(point.x, forKey: miniTimerOriginXKey)
        defaults.set(point.y, forKey: miniTimerOriginYKey)
      } else {
        defaults.removeObject(forKey: miniTimerOriginXKey)
        defaults.removeObject(forKey: miniTimerOriginYKey)
      }
    }
  }

  // MARK: - Distraction nudges

  /// Gentle distraction nudges. Default on, per the chosen profile.
  static var distractionNudgesEnabled: Bool {
    get {
      if defaults.object(forKey: distractionNudgesEnabledKey) == nil { return true }
      return defaults.bool(forKey: distractionNudgesEnabledKey)
    }
    set { defaults.set(newValue, forKey: distractionNudgesEnabledKey) }
  }
}
