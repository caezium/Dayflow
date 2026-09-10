//
//  ProcessingStatusPill.swift
//  Dayflow
//
//  In-app control to stop/resume the AI analysis pipeline, sitting in the timeline
//  header next to the recording controls. Recording is unaffected — this only
//  pauses turning screenshots into timeline cards. Mirrors the menu-bar control
//  via ProcessingControl.shared, so the two stay in sync. When running it's a
//  quiet neutral pill; when paused it turns amber so it's obvious processing is off.
//

import SwiftUI

struct ProcessingStatusPill: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var processing = ProcessingControl.shared
  @State private var hovering = false

  var body: some View {
    Button(action: { processing.toggle() }) {
      HStack(spacing: 6) {
        Image(systemName: processing.isStopped ? "play.circle.fill" : "stop.circle.fill")
          .font(.system(size: 12, weight: .semibold))
        Text(processing.isStopped ? "Processing paused" : "Stop processing")
          .font(.custom("Figtree-Medium", size: 12))
          .lineLimit(1)
          .fixedSize()
      }
      .foregroundColor(foreground)
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(Capsule().fill(fill.opacity(hovering ? 1 : 0.85)))
      .overlay(Capsule().strokeBorder(border, lineWidth: 1.25))
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering = $0 }
    .help(
      processing.isStopped
        ? "AI processing is paused. Recording still runs. Click to resume."
        : "Pause AI analysis of your screenshots into timeline cards. Recording keeps running."
    )
    .animation(.easeInOut(duration: 0.2), value: processing.isStopped)
  }

  // Running: quiet neutral control chrome. Paused: amber, kept readable per theme.
  private var foreground: Color {
    processing.isStopped
      ? Color.dayflowAdaptive(
        light: NSColor(red: 0.54, green: 0.35, blue: 0.0, alpha: 1),
        dark: NSColor(red: 1.0, green: 0.8, blue: 0.45, alpha: 1))
      : theme.controlText
  }
  private var fill: Color {
    processing.isStopped
      ? Color.dayflowAdaptive(
        light: NSColor(red: 1.0, green: 0.91, blue: 0.76, alpha: 1),
        dark: NSColor(red: 0.35, green: 0.26, blue: 0.08, alpha: 1))
      : theme.controlFill
  }
  private var border: Color {
    processing.isStopped
      ? Color.dayflowAdaptive(
        light: NSColor(red: 0.95, green: 0.78, blue: 0.47, alpha: 1),
        dark: NSColor(red: 0.55, green: 0.42, blue: 0.15, alpha: 1))
      : theme.controlBorder
  }
}
