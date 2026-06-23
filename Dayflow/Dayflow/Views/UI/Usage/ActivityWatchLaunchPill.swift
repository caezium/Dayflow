//
//  ActivityWatchLaunchPill.swift
//  Dayflow
//
//  A small pill shown next to the recording control when ActivityWatch is
//  installed but not running, so the user can launch it in one click for richer
//  tracking. Hides itself once ActivityWatch is up.
//

import SwiftUI

struct ActivityWatchLaunchPill: View {
  @ObservedObject private var launcher = ActivityWatchLauncher.shared
  @State private var hovering = false

  private var shouldShow: Bool {
    launcher.isInstalled && !launcher.isRunning
  }

  var body: some View {
    Group {
      if shouldShow {
        Button(action: { launcher.launch() }) {
          HStack(spacing: 6) {
            if launcher.isLaunching {
              ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
            } else {
              Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            }
            Text(launcher.isLaunching ? "Launching…" : "Launch ActivityWatch")
              .font(.custom("Figtree-Medium", size: 12))
              .lineLimit(1)
              .fixedSize()
          }
          .foregroundColor(Color(hex: "786655"))
          .padding(.horizontal, 12)
          .frame(height: 32)
          .background(
            Capsule().fill(Color(hex: "FFF3E8").opacity(hovering ? 1 : 0.85))
          )
          .overlay(
            Capsule().strokeBorder(Color(hex: "FFE1C9"), lineWidth: 1.25)
          )
        }
        .buttonStyle(.plain)
        .disabled(launcher.isLaunching)
        .pointingHandCursor()
        .onHover { hovering = $0 }
        .help("ActivityWatch isn't running — launch it for richer activity tracking.")
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
      }
    }
    .animation(.spring(duration: 0.3, bounce: 0.1), value: shouldShow)
    .animation(.easeInOut(duration: 0.2), value: launcher.isLaunching)
  }
}
