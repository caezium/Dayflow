import Foundation

enum TimelineMode: String, CaseIterable, Identifiable {
  case day
  case week
  case month

  var id: String { rawValue }

  var title: String {
    switch self {
    case .day:
      return "Day"
    case .week:
      return "Week"
    case .month:
      return "Month"
    }
  }
}

struct TimelineMonthDay: Identifiable, Equatable, Sendable {
  let date: Date
  let dayString: String
  let dayNumber: String
  /// False for the leading/trailing padding days that fill out whole weeks.
  let isInMonth: Bool

  var id: String { dayString }
}

struct TimelineMonthRange: Equatable, Sendable {
  /// First of the month at the 4 AM day boundary.
  let monthStart: Date
  /// First of the following month at 4 AM (exclusive).
  let monthEnd: Date
  /// The month's days padded with adjacent-month days to whole weeks, ordered
  /// to start on the user's configured first weekday. Always a multiple of 7.
  let gridDays: [TimelineMonthDay]

  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = WeekPreferences.weekStartWeekday
    return calendar
  }

  private static let titleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"
    return formatter
  }()

  private static let dayNumberFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d"
    return formatter
  }()

  private init(monthStart: Date, monthEnd: Date) {
    self.monthStart = monthStart
    self.monthEnd = monthEnd
    self.gridDays = Self.buildGridDays(monthStart: monthStart, monthEnd: monthEnd)
  }

  static func containing(_ date: Date, calendar: Calendar = Self.calendar) -> TimelineMonthRange {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let components = calendar.dateComponents([.year, .month], from: timelineDate)
    let firstOfMonth = calendar.date(from: components) ?? calendar.startOfDay(for: timelineDate)
    let monthStart =
      calendar.date(bySettingHour: 4, minute: 0, second: 0, of: firstOfMonth) ?? firstOfMonth
    let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
    return TimelineMonthRange(monthStart: monthStart, monthEnd: monthEnd)
  }

  func shifted(byMonths months: Int, calendar: Calendar = Self.calendar) -> TimelineMonthRange {
    let shiftedStart =
      calendar.date(byAdding: .month, value: months, to: monthStart) ?? monthStart
    return Self.containing(shiftedStart, calendar: calendar)
  }

  private static func buildGridDays(monthStart: Date, monthEnd: Date) -> [TimelineMonthDay] {
    let calendar = Self.calendar
    let firstDay = calendar.startOfDay(for: monthStart)
    let weekday = calendar.component(.weekday, from: firstDay)
    let leadingPadding = (weekday - calendar.firstWeekday + 7) % 7
    guard
      let gridStart = calendar.date(byAdding: .day, value: -leadingPadding, to: firstDay)
    else { return [] }

    // Compare against midnights: monthStart/monthEnd are 4 AM-anchored, and
    // the grid walks calendar days.
    let firstInMonthDay = calendar.startOfDay(for: monthStart)
    let firstOutOfMonthDay = calendar.startOfDay(for: monthEnd)

    var days: [TimelineMonthDay] = []
    var cursor = gridStart
    // Fill whole weeks until the month is fully covered (max 6 weeks).
    while (cursor < firstOutOfMonthDay || days.count % 7 != 0) && days.count < 42 {
      let dayStart = calendar.startOfDay(for: cursor)
      days.append(
        TimelineMonthDay(
          date: normalizedTimelineDate(cursor),
          dayString: DateFormatter.yyyyMMdd.string(from: cursor),
          dayNumber: Self.dayNumberFormatter.string(from: cursor),
          isInMonth: dayStart >= firstInMonthDay && dayStart < firstOutOfMonthDay
        ))
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
      cursor = next
    }
    return days
  }

  /// Weekday header labels ordered to match gridDays columns.
  static var weekdayHeaders: [String] {
    let calendar = Self.calendar
    let symbols = DateFormatter().shortWeekdaySymbols ?? calendar.shortWeekdaySymbols
    guard symbols.count == 7 else { return [] }
    return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
  }

  var title: String {
    Self.titleFormatter.string(from: monthStart)
  }

  var canNavigateForward: Bool {
    monthStart < Self.containing(Date()).monthStart
  }

  var containsToday: Bool {
    contains(Date())
  }

  func contains(_ date: Date) -> Bool {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let dayStart = timelineDate.getDayInfoFor4AMBoundary().startOfDay
    return dayStart >= monthStart && dayStart < monthEnd
  }
}

struct TimelineWeekDay: Identifiable, Equatable, Sendable {
  let date: Date
  let dayString: String
  let weekdayLabel: String
  let dayNumber: String

  var id: String { dayString }
}

struct TimelineWeekRange: Equatable, Sendable {
  let weekStart: Date
  let weekEnd: Date
  let days: [TimelineWeekDay]

  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = WeekPreferences.weekStartWeekday
    return calendar
  }

  private static let titleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d"
    return formatter
  }()

  private static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "E"
    return formatter
  }()

  private static let dayNumberFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d"
    return formatter
  }()

  private init(weekStart: Date, weekEnd: Date) {
    self.weekStart = weekStart
    self.weekEnd = weekEnd
    self.days = Self.buildDays(weekStart: weekStart)
  }

  private static func buildDays(weekStart: Date) -> [TimelineWeekDay] {
    let calendar = Self.calendar
    return (0..<7).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }
      let normalizedDate = normalizedTimelineDate(date)
      return TimelineWeekDay(
        date: normalizedDate,
        dayString: DateFormatter.yyyyMMdd.string(from: normalizedDate),
        weekdayLabel: Self.weekdayFormatter.string(from: normalizedDate),
        dayNumber: Self.dayNumberFormatter.string(from: normalizedDate)
      )
    }
  }

  static func containing(_ date: Date, calendar: Calendar = Self.calendar) -> TimelineWeekRange {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let anchorDay = calendar.startOfDay(for: timelineDate)
    let weekday = calendar.component(.weekday, from: anchorDay)
    let daysFromWeekStart = (weekday - calendar.firstWeekday + 7) % 7
    let weekStartDay =
      calendar.date(byAdding: .day, value: -daysFromWeekStart, to: anchorDay)
      ?? anchorDay
    let weekStart =
      calendar.date(bySettingHour: 4, minute: 0, second: 0, of: weekStartDay) ?? weekStartDay
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    return TimelineWeekRange(weekStart: weekStart, weekEnd: weekEnd)
  }

  func shifted(byWeeks weeks: Int, calendar: Calendar = Self.calendar) -> TimelineWeekRange {
    let shiftedStart = calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) ?? weekStart
    let shiftedEnd = calendar.date(byAdding: .day, value: 7, to: shiftedStart) ?? shiftedStart
    return TimelineWeekRange(weekStart: shiftedStart, weekEnd: shiftedEnd)
  }

  var title: String {
    let displayedWeekEnd = Self.calendar.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd
    return
      "\(Self.titleFormatter.string(from: weekStart)) - \(Self.titleFormatter.string(from: displayedWeekEnd))"
  }

  var canNavigateForward: Bool {
    weekStart < Self.containing(Date()).weekStart
  }

  var containsToday: Bool {
    contains(Date())
  }

  func contains(_ date: Date) -> Bool {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let dayStart = timelineDate.getDayInfoFor4AMBoundary().startOfDay
    return dayStart >= weekStart && dayStart < weekEnd
  }
}
