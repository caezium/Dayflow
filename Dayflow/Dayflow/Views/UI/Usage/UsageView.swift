//
//  UsageView.swift
//  Dayflow
//
//  Phase 1: shows accurate, local ground-truth foreground usage (macOS Screen
//  Time, plus ActivityWatch when running) for the current day. Read-only — does
//  not affect the analysis pipeline yet.
//
//  Uses explicit dark colors (SettingsStyle) rather than adaptive .primary/
//  .secondary, because Dayflow paints a fixed light background regardless of the
//  system appearance — adaptive colors would render white-on-cream and vanish.
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

  private let barColor = Color(red: 0.976, green: 0.431, blue: 0.0)  // Dayflow orange

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header

        if !fullDiskAccess {
          fullDiskAccessCard
        }

        if isLoading {
          ProgressView().padding(.top, 24)
        } else {
          if fullDiskAccess {
            usageSection(title: "Apps", subtitle: "macOS Screen Time", entries: screenTimeApps)
            if !screenTimeWeb.isEmpty {
              usageSection(
                title: "Websites", subtitle: "macOS Screen Time", entries: screenTimeWeb)
            }
          }
          if activityWatchRunning {
            usageSection(title: "Windows", subtitle: "ActivityWatch", entries: activityWatchApps)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
    .task { await load() }
  }

  // MARK: - Sections

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Usage")
          .font(.system(size: 22, weight: .bold))
          .foregroundColor(SettingsStyle.ink)
        Text("Accurate foreground time today, measured directly — not inferred from screenshots.")
          .font(.system(size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }
      Spacer()
      sourceBadge("Screen Time", on: fullDiskAccess)
      sourceBadge("ActivityWatch", on: activityWatchRunning)
      Button {
        Task { await load() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(SettingsStyle.secondary)
      }
      .buttonStyle(.borderless)
      .help("Refresh")
    }
  }

  private func sourceBadge(_ name: String, on: Bool) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(on ? SettingsStyle.statusGood : SettingsStyle.statusIdle)
        .frame(width: 7, height: 7)
      Text(name).font(.system(size: 11, weight: .medium)).foregroundColor(SettingsStyle.text)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(Color.black.opacity(0.05), in: Capsule())
    .help(on ? "\(name) is providing data" : "\(name) is not available")
  }

  private var fullDiskAccessCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Full Disk Access needed", systemImage: "lock.shield")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(SettingsStyle.text)
      Text(
        "To read macOS Screen Time, grant Dayflow Full Disk Access in System Settings, then come back and refresh."
      )
      .font(.system(size: 12))
      .foregroundColor(SettingsStyle.secondary)
      Button("Open Full Disk Access settings") {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        {
          NSWorkspace.shared.open(url)
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
  }

  private func usageSection(title: String, subtitle: String, entries: [UsageEntry]) -> some View {
    let maxSeconds = entries.map(\.seconds).max() ?? 1
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(SettingsStyle.text)
        Text(subtitle).font(.system(size: 11)).foregroundColor(SettingsStyle.meta)
        Spacer()
        Text(Self.formatDuration(entries.reduce(0) { $0 + $1.seconds }))
          .font(.system(size: 12, weight: .medium).monospacedDigit())
          .foregroundColor(SettingsStyle.secondary)
      }
      if entries.isEmpty {
        Text("No activity recorded yet today.")
          .font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
      } else {
        ForEach(entries.prefix(25)) { entry in
          usageRow(entry, maxSeconds: maxSeconds)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
  }

  private func usageRow(_ entry: UsageEntry, maxSeconds: Double) -> some View {
    HStack(spacing: 10) {
      Text(entry.displayName)
        .font(.system(size: 13))
        .foregroundColor(SettingsStyle.text)
        .lineLimit(1)
        .frame(width: 160, alignment: .leading)
      GeometryReader { geo in
        Capsule()
          .fill(barColor)
          .frame(width: max(2, geo.size.width * (entry.seconds / max(maxSeconds, 1))))
      }
      .frame(height: 8)
      Text(Self.formatDuration(entry.seconds))
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundColor(SettingsStyle.secondary)
        .frame(width: 64, alignment: .trailing)
    }
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
