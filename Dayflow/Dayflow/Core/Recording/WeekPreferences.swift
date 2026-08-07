import Foundation

enum WeekPreferences {
  private static let weekStartKey = "weekStartWeekday"

  /// Calendar weekday number (1 = Sunday … 7 = Saturday) for the first day
  /// shown in Week timeline and Weekly dashboard. Display grouping only —
  /// stored day strings and the 4 AM day boundary are unaffected.
  static var weekStartWeekday: Int {
    get {
      let value = UserDefaults.standard.integer(forKey: weekStartKey)
      return (1...7).contains(value) ? value : 2
    }
    set { UserDefaults.standard.set(newValue, forKey: weekStartKey) }
  }

  /// Localized weekday name for a Calendar weekday number (1 = Sunday).
  static func weekdayName(_ weekday: Int) -> String {
    let symbols = DateFormatter().weekdaySymbols ?? Calendar.current.weekdaySymbols
    guard (1...7).contains(weekday), symbols.count == 7 else { return "Monday" }
    return symbols[weekday - 1]
  }
}
