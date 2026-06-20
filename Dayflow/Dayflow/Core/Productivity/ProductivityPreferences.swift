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

  // MARK: - Tunables (fixed defaults, matching the "gentle" nudge profile)

  /// Distraction within the trailing window required to fire a nudge.
  static let nudgeThresholdSeconds: Double = 20 * 60
  /// Length of the trailing window the nudge looks back over.
  static let nudgeWindowSeconds: Double = 30 * 60
  /// Minimum gap between two nudges so we never spam the user.
  static let nudgeCooldownSeconds: Double = 60 * 60

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
