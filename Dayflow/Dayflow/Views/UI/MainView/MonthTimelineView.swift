//
//  MonthTimelineView.swift
//  Dayflow
//
//  Month mode for the timeline: a zoomed-out, per-day digest of the month.
//  One dashboard: a calendar of per-day radial dials (each hour tinted by its
//  dominant category, total in the centre) over a scrollable agenda list.
//  Clicking a dial highlights and scrolls to its agenda row; clicking an
//  agenda row dives into Day mode.
//

import SwiftUI

// MARK: - Per-day aggregation (pure, testable)

struct MonthCategorySlice: Equatable, Sendable {
  let category: String
  let minutes: Int
}

/// Dominant category (and its minutes) inside one clock hour of a day.
struct MonthHourCell: Equatable, Sendable {
  let category: String?
  let minutes: Int
}

/// A contiguous same-category block, on a wall-clock hour axis (0–24).
struct MonthSession: Equatable, Sendable {
  let category: String
  let startHour: Double
  let endHour: Double
  let minutes: Int
  let deep: Bool
}

struct MonthDaySummary: Equatable, Sendable {
  let totalMinutes: Int
  let categorySlices: [MonthCategorySlice]
  let topActivityTitle: String?
  /// 24 clock-hour cells (index 0 = 00:00), dominant category per hour.
  let hourly: [MonthHourCell]
  /// Merged same-category focus blocks, ordered by start.
  let sessions: [MonthSession]
  /// Adjacent category changes across the day.
  let contextSwitches: Int
  /// Minutes spent in sessions that clear the "deep" threshold.
  let deepMinutes: Int
}

enum MonthOverviewBuilder {
  /// A session is "deep" once it runs this long uninterrupted (minutes).
  static let deepSessionMinutes = 45
  /// Same-category activities this close (seconds) or closer merge into a session.
  private static let sessionJoinGap: TimeInterval = 300

  private static var wallClockCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }

  /// Aggregates timeline activities into one rich summary per 4 AM-bounded day.
  /// System cards (failure placeholders etc.) are excluded entirely; Idle
  /// counts toward its category slice and hourly cells but not the headline
  /// total. `idleCategoryName` is passed in because CategoryStore is main-actor-
  /// bound and this runs on a background task.
  static func build(
    activities: [TimelineActivity],
    idleCategoryName: String = "Idle"
  ) -> [String: MonthDaySummary] {
    let calendar = wallClockCalendar
    let idleName =
      idleCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    // Group first so per-day sequencing (sessions, switches) is well-defined.
    var byDay: [String: [TimelineActivity]] = [:]
    for activity in activities {
      let category = activity.category.trimmingCharacters(in: .whitespacesAndNewlines)
      guard category.caseInsensitiveCompare("System") != .orderedSame else { continue }
      guard activity.endTime.timeIntervalSince(activity.startTime) > 0 else { continue }
      let dayString = activity.startTime.getDayInfoFor4AMBoundary().dayString
      byDay[dayString, default: []].append(activity)
    }

    var result: [String: MonthDaySummary] = [:]
    for (dayString, unordered) in byDay {
      let sorted = unordered.sorted { $0.startTime < $1.startTime }

      var minutesByCategory: [String: Int] = [:]
      var totalMinutes = 0
      var topTitle: String? = nil
      var topDuration: TimeInterval = 0
      var hourAccum: [[String: Double]] = Array(repeating: [:], count: 24)

      for activity in sorted {
        let raw = activity.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = raw.isEmpty ? "Uncategorized" : raw
        let duration = activity.endTime.timeIntervalSince(activity.startTime)
        let minutes = Int((duration / 60).rounded())
        minutesByCategory[category, default: 0] += minutes

        if category.lowercased() != idleName {
          totalMinutes += minutes
          if duration > topDuration {
            topDuration = duration
            topTitle = activity.title
          }
        }
        for segment in hourSegments(start: activity.startTime, end: activity.endTime, calendar: calendar) {
          hourAccum[segment.hour][category, default: 0] += segment.minutes
        }
      }

      let hourly: [MonthHourCell] = hourAccum.map { bucket in
        var best: String? = nil
        var bestMinutes = 0.0
        for (category, minutes) in bucket where minutes > bestMinutes {
          bestMinutes = minutes
          best = category
        }
        return MonthHourCell(category: best, minutes: Int(bestMinutes.rounded()))
      }

      var sessions: [MonthSession] = []
      var currentCategory: String? = nil
      var currentStart = Date.distantPast
      var currentEnd = Date.distantPast
      for activity in sorted {
        let raw = activity.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = raw.isEmpty ? "Uncategorized" : raw
        if let open = currentCategory, open == category,
          activity.startTime.timeIntervalSince(currentEnd) <= sessionJoinGap {
          currentEnd = max(currentEnd, activity.endTime)
        } else {
          if let open = currentCategory {
            sessions.append(makeSession(open, currentStart, currentEnd, calendar))
          }
          currentCategory = category
          currentStart = activity.startTime
          currentEnd = activity.endTime
        }
      }
      if let open = currentCategory {
        sessions.append(makeSession(open, currentStart, currentEnd, calendar))
      }

      var contextSwitches = 0
      if sorted.count > 1 {
        for i in 1..<sorted.count {
          let a = sorted[i].category.trimmingCharacters(in: .whitespacesAndNewlines)
          let b = sorted[i - 1].category.trimmingCharacters(in: .whitespacesAndNewlines)
          if a != b { contextSwitches += 1 }
        }
      }
      let deepMinutes = sessions.reduce(0) { $0 + ($1.deep ? $1.minutes : 0) }

      result[dayString] = MonthDaySummary(
        totalMinutes: totalMinutes,
        categorySlices:
          minutesByCategory
          .map { MonthCategorySlice(category: $0.key, minutes: $0.value) }
          .sorted {
            $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.category < $1.category
          },
        topActivityTitle: topTitle,
        hourly: hourly,
        sessions: sessions,
        contextSwitches: contextSwitches,
        deepMinutes: deepMinutes)
    }
    return result
  }

  private static func makeSession(
    _ category: String, _ start: Date, _ end: Date, _ calendar: Calendar
  ) -> MonthSession {
    let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
    return MonthSession(
      category: category,
      startHour: clockHour(start, calendar),
      endHour: clockHour(end, calendar),
      minutes: minutes,
      deep: minutes >= deepSessionMinutes)
  }

  private static func clockHour(_ date: Date, _ calendar: Calendar) -> Double {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
  }

  /// Split [start, end] into (clock-hour, minutes) pieces at hour boundaries.
  private static func hourSegments(
    start: Date, end: Date, calendar: Calendar
  ) -> [(hour: Int, minutes: Double)] {
    var out: [(Int, Double)] = []
    var cursor = start
    var guardCount = 0
    while cursor < end && guardCount < 48 {
      guardCount += 1
      let hour = calendar.component(.hour, from: cursor)
      let startOfHour =
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: cursor) ?? cursor
      let nextBoundary = calendar.date(byAdding: .hour, value: 1, to: startOfHour) ?? end
      let segmentEnd = min(nextBoundary, end)
      let minutes = segmentEnd.timeIntervalSince(cursor) / 60
      if minutes > 0 { out.append((hour, minutes)) }
      cursor = segmentEnd
    }
    return out
  }
}

// MARK: - Month view

struct MonthTimelineView: View {
  let monthRange: TimelineMonthRange
  let onSelectDay: (Date) -> Void

  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var summaries: [String: MonthDaySummary] = [:]
  @State private var hasLoaded = false

  var body: some View {
    MonthOverviewComboDraft(
      monthRange: monthRange, summaries: summaries,
      colorForCategory: color(for:), onSelectDay: onSelectDay
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .opacity(hasLoaded ? 1 : 0)
    .animation(.easeOut(duration: 0.18), value: hasLoaded)
    .padding(.top, 4)
    .task(id: monthRange.monthStart) {
      let range = monthRange
      let idleName = categoryStore.idleCategory?.name ?? "Idle"
      let loaded = await Task.detached(priority: .userInitiated) { () -> [String: MonthDaySummary]
        in
        let activities = TimelineActivityLoader.activities(
          from: range.monthStart, to: range.monthEnd)
        return MonthOverviewBuilder.build(activities: activities, idleCategoryName: idleName)
      }.value
      summaries = loaded
      hasLoaded = true
    }
  }

  private func color(for category: String) -> Color {
    let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let match = categoryStore.categories.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return Color(hex: match.colorHex.replacingOccurrences(of: "#", with: ""))
    }
    return Color(hex: "D8D3CC")
  }
}

// MARK: - Shared helpers

private func hoursLabel(minutes: Int) -> String {
  guard minutes > 0 else { return "" }
  if minutes < 60 { return "\(minutes)m" }
  let hours = Double(minutes) / 60
  return hours >= 10
    ? "\(Int(hours.rounded()))h"
    : String(format: "%.1fh", hours).replacingOccurrences(of: ".0h", with: "h")
}

private func isTimelineToday(_ dayString: String) -> Bool {
  Date().getDayInfoFor4AMBoundary().dayString == dayString
}
// MARK: - Shared helpers for the new drafts

private enum MonthDraft {
  static let label = Color(hex: "796E64")
  static let strong = Color(hex: "3A3530")
  static let accent = Color(hex: "FF7A2F")
  static let today = Color(hex: "FF7506")
  static let faintFill = Color.black.opacity(0.05)

  static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .custom("Figtree", size: size).weight(weight)
  }

  static func drawEmpty(_ context: GraphicsContext, _ size: CGSize) {
    context.draw(
      Text("No activity this month").font(font(13)).foregroundColor(label.opacity(0.6)),
      at: CGPoint(x: size.width / 2, y: size.height / 2))
  }

  /// Angle (radians) for a clock hour on a dial with midnight at the top.
  static func dialAngle(_ hour: Double) -> Double { -.pi / 2 + hour / 24 * 2 * .pi }

  /// A short polyline approximating a ring arc, for stroking.
  static func arc(center: CGPoint, radius: CGFloat, from a0: Double, to a1: Double, steps: Int = 4) -> Path {
    var path = Path()
    for i in 0...steps {
      let t = a0 + (a1 - a0) * Double(i) / Double(steps)
      let point = CGPoint(x: center.x + radius * CGFloat(cos(t)), y: center.y + radius * CGFloat(sin(t)))
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }

  static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }
}
// MARK: - Draft: Overview (calendar of ribbons/dials + agenda list, linked)

private struct MonthOverviewComboDraft: View {
  let monthRange: TimelineMonthRange
  let summaries: [String: MonthDaySummary]
  let colorForCategory: (String) -> Color
  let onSelectDay: (Date) -> Void

  @State private var selectedDay: String? = nil

  private static let rowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d"
    return formatter
  }()

  private var maxMinutes: Int {
    max(summaries.values.map(\.totalMinutes).max() ?? 0, 1)
  }

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 10) {
        // ---- Calendar of day-dials ----
        VStack(spacing: 6) {
          HStack(spacing: 6) {
            ForEach(TimelineMonthRange.weekdayHeaders, id: \.self) { header in
              Text(header.uppercased())
                .font(MonthDraft.font(9.5, .semibold))
                .foregroundColor(MonthDraft.label)
                .frame(maxWidth: .infinity)
            }
          }
          let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
          LazyVGrid(columns: columns, spacing: 6) {
            ForEach(monthRange.gridDays) { day in
              calendarCell(day) {
                guard day.isInMonth else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                  selectedDay = day.dayString
                  proxy.scrollTo(day.dayString, anchor: .center)
                }
              }
            }
          }
        }
        .padding(.horizontal, 24)

        Divider().padding(.horizontal, 24)

        // ---- Agenda list ----
        ScrollView(.vertical, showsIndicators: true) {
          VStack(spacing: 3) {
            ForEach(monthRange.gridDays.filter(\.isInMonth)) { day in
              agendaRow(day).id(day.dayString)
            }
          }
          .padding(.horizontal, 24)
          .padding(.top, 2)
          .padding(.bottom, 24)
        }
        // Bottom fade hints that the list scrolls.
        .overlay(alignment: .bottom) {
          LinearGradient(
            colors: [Color(hex: "FBF4EA").opacity(0), Color(hex: "FBF4EA").opacity(0.92)],
            startPoint: .top, endPoint: .bottom
          )
          .frame(height: 22)
          .allowsHitTesting(false)
        }
      }
      .padding(.top, 2)
    }
  }

  // MARK: Calendar cell — a radial day-dial

  @ViewBuilder
  private func calendarCell(_ day: TimelineMonthDay, pick: @escaping () -> Void) -> some View {
    let summary = summaries[day.dayString]
    let minutes = summary?.totalMinutes ?? 0
    let today = isTimelineToday(day.dayString)
    let selected = selectedDay == day.dayString

    Button(action: pick) {
      VStack(spacing: 3) {
        HStack(spacing: 2) {
          Text(day.dayNumber)
            .font(MonthDraft.font(10, today ? .bold : .medium))
            .foregroundColor(day.isInMonth ? MonthDraft.strong : MonthDraft.label.opacity(0.35))
          Spacer(minLength: 0)
          if today {
            Circle().fill(MonthDraft.today).frame(width: 5, height: 5)
          }
        }
        if day.isInMonth, minutes > 0, let hourly = summary?.hourly {
          dayDial(hourly: hourly, minutes: minutes, today: today)
        } else {
          Spacer(minLength: 0)
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity)
      .frame(height: 76)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(day.isInMonth ? Color.white.opacity(0.7) : Color.black.opacity(0.012))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(
                selected ? MonthDraft.accent
                  : (today ? MonthDraft.today.opacity(0.6) : Color.black.opacity(day.isInMonth ? 0.05 : 0.02)),
                lineWidth: selected ? 2 : (today ? 1.5 : 1)))
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(PlainButtonStyle())
    .hoverScaleEffect(scale: 1.03)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .help(summary?.topActivityTitle ?? "")
  }

  private func dayDial(hourly: [MonthHourCell], minutes: Int, today: Bool) -> some View {
    Canvas { context, size in
      let dim = min(size.width, size.height)
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let sw = dim * 0.15
      let radius = dim / 2 - sw / 2 - 1
      // Faint full-day track.
      context.stroke(
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
        with: .color(Color.black.opacity(0.05)), lineWidth: sw)
      // Colored hour arcs, midnight at top, small gaps between hours.
      for hour in 0..<24 {
        let entry = hourly[hour]
        guard let category = entry.category, entry.minutes > 0 else { continue }
        let a0 = MonthDraft.dialAngle(Double(hour)) + 0.03
        let a1 = MonthDraft.dialAngle(Double(hour + 1)) - 0.03
        context.stroke(MonthDraft.arc(center: center, radius: radius, from: a0, to: a1, steps: 5),
                       with: .color(colorForCategory(category)),
                       style: StrokeStyle(lineWidth: sw, lineCap: .butt))
      }
      // Total hours in the centre.
      context.draw(
        Text(hoursLabel(minutes: minutes))
          .font(MonthDraft.font(11.5, .bold).monospacedDigit())
          .foregroundColor(today ? MonthDraft.today : MonthDraft.strong),
        at: center)
    }
    .frame(height: 44)
  }

  @ViewBuilder
  private func agendaRow(_ day: TimelineMonthDay) -> some View {
    let summary = summaries[day.dayString]
    let minutes = summary?.totalMinutes ?? 0
    let today = isTimelineToday(day.dayString)
    let selected = selectedDay == day.dayString

    Button {
      onSelectDay(day.date)
    } label: {
      HStack(alignment: .center, spacing: 12) {
        Text(Self.rowDateFormatter.string(from: day.date))
          .font(MonthDraft.font(11, today ? .bold : .medium).monospacedDigit())
          .foregroundColor(today ? MonthDraft.today : MonthDraft.label)
          .frame(width: 52, alignment: .leading)

        if let summary, minutes > 0 {
          GeometryReader { geo in
            HStack(spacing: 1.5) {
              let total = max(summary.categorySlices.reduce(0) { $0 + $1.minutes }, 1)
              let barWidth = geo.size.width * CGFloat(minutes) / CGFloat(maxMinutes)
              ForEach(summary.categorySlices.prefix(5), id: \.category) { slice in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                  .fill(colorForCategory(slice.category))
                  .frame(width: max(3, barWidth * CGFloat(slice.minutes) / CGFloat(total) - 1.5))
              }
              Spacer(minLength: 0)
            }
            .frame(height: 10)
            .frame(maxHeight: .infinity, alignment: .center)
          }
          .frame(height: 18)

          Text(hoursLabel(minutes: minutes))
            .font(MonthDraft.font(11, .semibold).monospacedDigit())
            .foregroundColor(MonthDraft.strong)
            .frame(width: 38, alignment: .trailing)

          Text(summary.topActivityTitle ?? "")
            .font(MonthDraft.font(11))
            .foregroundColor(MonthDraft.label)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 220, alignment: .leading)
        } else {
          Text("—")
            .font(MonthDraft.font(11))
            .foregroundColor(MonthDraft.label.opacity(0.35))
          Spacer()
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? MonthDraft.accent.opacity(0.14)
            : (today ? MonthDraft.accent.opacity(0.06) : Color.white.opacity(0.001)))
      )
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(MonthDraft.accent.opacity(0.5), lineWidth: 1)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(PlainButtonStyle())
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }
}
