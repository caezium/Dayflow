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

  private var foreground: Color {
    processing.isStopped ? Color(hex: "8A5A00") : Color(hex: "786655")
  }
  private var fill: Color {
    processing.isStopped ? Color(hex: "FFE9C2") : Color(hex: "F3EEE7")
  }
  private var border: Color {
    processing.isStopped ? Color(hex: "F2C879") : Color(hex: "E7DED2")
  }
}
