//
//  UsageView.swift
//  Dayflow
//
//  Accurate, local ground-truth foreground usage (macOS Screen Time +
//  ActivityWatch) for the current day. Mirrors the Daily/Weekly visual language:
//  a donut summary + white cards, Figtree/InstrumentSerif fonts, soft warm
//  shadows, and explicit dark text (Dayflow paints a fixed light background, so
//  adaptive .primary/.secondary would render invisible under system dark mode).
//

import AppKit
import SwiftUI

struct UsageView: View {
  @State private var screenTimeApps: [UsageEntry] = []
  @State private var screenTimeWeb: [UsageEntry] = []
  @State private var activityWatchApps: [UsageEntry] = []
  @State private var fullDiskAccess = true
  @State private var activityWatchRunning = false
  @State private var isLoading = true

  // Palette borrowed from the category presets, for the donut/legend.
  private static let palette = [
    "#6A7EFF", "#56CFEE", "#C787F7", "#FFAE8C", "#FF5950", "#6AADFF", "#88E5DF", "#B984FF",
  ]
  private let barColor = Color(red: 0.976, green: 0.431, blue: 0.0)  // Dayflow orange
  private let titleColor = Color(red: 0.2, green: 0.2, blue: 0.2)  // #333333
  private let subtitleColor = Color(red: 0.44, green: 0.44, blue: 0.44)  // #707070

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header

        if !fullDiskAccess {
          fullDiskAccessCard
        }

        if isLoading {
          ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
        } else {
          if fullDiskAccess && !screenTimeApps.isEmpty {
            donutCard
          }
          if fullDiskAccess {
            listCard(title: "Apps", subtitle: "macOS Screen Time", entries: screenTimeApps)
            if !screenTimeWeb.isEmpty {
              listCard(title: "Websites", subtitle: "macOS Screen Time", entries: screenTimeWeb)
            }
          }
          if activityWatchRunning {
            listCard(title: "Windows", subtitle: "ActivityWatch", entries: activityWatchApps)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
    .task { await load() }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Usage")
          .font(.custom("InstrumentSerif-Regular", size: 30))
          .foregroundColor(titleColor)
        Text("Accurate foreground time today, measured directly — not inferred from screenshots.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(subtitleColor)
      }
      Spacer()
      sourceBadge("Screen Time", on: fullDiskAccess)
      sourceBadge("ActivityWatch", on: activityWatchRunning)
      Button { Task { await load() } } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(subtitleColor)
      }
      .buttonStyle(.borderless)
      .help("Refresh")
    }
  }

  private func sourceBadge(_ name: String, on: Bool) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(on ? Color(red: 0.25, green: 0.62, blue: 0.32) : Color.black.opacity(0.25))
        .frame(width: 7, height: 7)
      Text(name).font(.custom("Figtree", size: 11).weight(.medium)).foregroundColor(titleColor)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(Color.white.opacity(0.7), in: Capsule())
    .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
    .help(on ? "\(name) is providing data" : "\(name) is not available")
  }

  // MARK: - Donut

  private var donutCard: some View {
    card {
      VStack(alignment: .leading, spacing: 4) {
        Text("Top apps today").font(.custom("Figtree", size: 15).weight(.semibold))
          .foregroundColor(titleColor)
        HStack { Spacer(); CategoryDonutChart(data: donutData); Spacer() }
          .padding(.top, 8)
      }
    }
  }

  private var donutData: [CategoryTimeData] {
    let top = Array(screenTimeApps.prefix(6))
    var data = top.enumerated().map { index, entry in
      CategoryTimeData(
        name: entry.displayName,
        colorHex: Self.palette[index % Self.palette.count],
        duration: entry.seconds)
    }
    let rest = screenTimeApps.dropFirst(6).reduce(0) { $0 + $1.seconds }
    if rest > 0 {
      data.append(CategoryTimeData(name: "Other", colorHex: "#C9C4C0", duration: rest))
    }
    return data
  }

  // MARK: - List card

  private func listCard(title: String, subtitle: String, entries: [UsageEntry]) -> some View {
    let maxSeconds = entries.map(\.seconds).max() ?? 1
    return card {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text(title).font(.custom("Figtree", size: 15).weight(.semibold)).foregroundColor(
            titleColor)
          Text(subtitle).font(.custom("Figtree", size: 11)).foregroundColor(subtitleColor)
          Spacer()
          Text(Self.formatDuration(entries.reduce(0) { $0 + $1.seconds }))
            .font(.custom("Figtree", size: 12).weight(.medium).monospacedDigit())
            .foregroundColor(subtitleColor)
        }
        if entries.isEmpty {
          Text("No activity recorded yet today.")
            .font(.custom("Figtree", size: 12)).foregroundColor(subtitleColor)
        } else {
          ForEach(entries.prefix(25)) { entry in
            usageRow(entry, maxSeconds: maxSeconds)
          }
        }
      }
    }
  }

  private func usageRow(_ entry: UsageEntry, maxSeconds: Double) -> some View {
    HStack(spacing: 10) {
      Text(entry.displayName)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(titleColor)
        .lineLimit(1)
        .frame(width: 170, alignment: .leading)
      GeometryReader { geo in
        Capsule()
          .fill(barColor.opacity(0.85))
          .frame(width: max(3, geo.size.width * (entry.seconds / max(maxSeconds, 1))))
          .frame(maxHeight: .infinity, alignment: .leading)
      }
      .frame(height: 9)
      Text(Self.formatDuration(entry.seconds))
        .font(.custom("Figtree", size: 12).weight(.medium).monospacedDigit())
        .foregroundColor(subtitleColor)
        .frame(width: 66, alignment: .trailing)
    }
  }

  // MARK: - FDA card

  private var fullDiskAccessCard: some View {
    card {
      VStack(alignment: .leading, spacing: 8) {
        Label("Full Disk Access needed", systemImage: "lock.shield")
          .font(.custom("Figtree", size: 14).weight(.semibold))
          .foregroundColor(titleColor)
        Text(
          "To read macOS Screen Time, grant Dayflow Full Disk Access in System Settings, then come back and refresh."
        )
        .font(.custom("Figtree", size: 12))
        .foregroundColor(subtitleColor)
        Button("Open Full Disk Access settings") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
          {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(barColor)
      }
    }
  }

  // MARK: - Card chrome

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white)
      .cornerRadius(16)
      .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.10), radius: 8, x: 0, y: 2)
  }

  // MARK: - Load

  private func load() async {
    isLoading = true
    let dayInfo = Date().getDayInfoFor4AMBoundary()
    let start = dayInfo.startOfDay
    let end = Date()

    let readable = await Task.detached { UsageGroundTruth.shared.screenTimeReadable() }.value
    let screenTime =
      readable
      ? await Task.detached { UsageGroundTruth.shared.usage(from: start, to: end) }.value
      : []
    let awRunning = await UsageGroundTruth.shared.activityWatchRunning()
    let aw = awRunning ? await UsageGroundTruth.shared.activityWatchUsage(from: start, to: end) : []

    fullDiskAccess = readable
    screenTimeApps = screenTime.filter { $0.kind == .app }
    screenTimeWeb = screenTime.filter { $0.kind == .web }
    activityWatchRunning = awRunning
    activityWatchApps = aw
    isLoading = false
  }

  static func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
  }
}
