//
//  SettingsProductivityTabView.swift
//  Dayflow
//
//  Settings for the fork's productivity/detection features (focus timer, nudges,
//  work reminder, measured-usage + OCR detection, ActivityWatch). Pulled out of
//  the "Other" tab so each feature has a clear home.
//

import SwiftUI

struct SettingsProductivityTabView: View {
  @ObservedObject private var miniTimer = MiniTimerWindowController.shared
  @ObservedObject private var awLauncher = ActivityWatchLauncher.shared

  @State private var nudgesEnabled = ProductivityPreferences.distractionNudgesEnabled
  @State private var nudgeThreshold = ProductivityPreferences.nudgeThresholdMinutes
  @State private var nudgeCooldown = ProductivityPreferences.nudgeCooldownMinutes
  @State private var workReminders = ProductivityPreferences.workRemindersEnabled
  @State private var feedGroundTruth = UsagePreferences.feedGroundTruthToAI
  @State private var ocrEnabled = UsagePreferences.useScreenTextOCR
  @State private var ocrProvider = UsagePreferences.ocrProvider
  @State private var ocrStatus: ScreenTextOCR.EngineStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      focusSection
      nudgesSection
      detectionSection
    }
  }

  // MARK: - Focus

  private var focusSection: some View {
    SettingsSection(title: "Focus", subtitle: "The floating timer and your daily start nudge.") {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: "Show focus timer",
          subtitle:
            "A small floating pill that counts up today's focused time live. Drag it anywhere; toggle it from the menu bar too."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { miniTimer.isVisible }, set: { miniTimer.setVisible($0) }))
        }
        SettingsRow(
          label: "Daily \"ready to start?\" reminder",
          subtitle:
            "Once a day, if you have open tasks and you're at your Mac, a gentle reminder to get going.",
          showsDivider: false
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { workReminders },
              set: { workReminders = $0; ProductivityPreferences.workRemindersEnabled = $0 }))
        }
      }
    }
  }

  // MARK: - Nudges

  private var nudgesSection: some View {
    SettingsSection(
      title: "Distraction nudges", subtitle: "A gentle reminder when you've drifted off."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: "Distraction nudges",
          subtitle: "Never blocks anything — just a nudge.",
          showsDivider: nudgesEnabled
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { nudgesEnabled },
              set: { nudgesEnabled = $0; ProductivityPreferences.distractionNudgesEnabled = $0 }))
        }
        if nudgesEnabled {
          SettingsRow(label: "Nudge after", subtitle: "Distraction time that triggers a nudge.") {
            MinuteMenuPicker(
              selection: Binding(
                get: { nudgeThreshold },
                set: { nudgeThreshold = $0; ProductivityPreferences.nudgeThresholdMinutes = $0 }),
              options: ProductivityPreferences.nudgeThresholdMinuteOptions)
          }
          SettingsRow(
            label: "Wait between nudges",
            subtitle: "Minimum quiet time after a nudge before the next one.",
            showsDivider: false
          ) {
            MinuteMenuPicker(
              selection: Binding(
                get: { nudgeCooldown },
                set: { nudgeCooldown = $0; ProductivityPreferences.nudgeCooldownMinutes = $0 }),
              options: ProductivityPreferences.nudgeCooldownMinuteOptions)
          }
        }
      }
    }
  }

  // MARK: - Detection

  private var detectionSection: some View {
    SettingsSection(
      title: "Detection accuracy",
      subtitle: "Ground-truth signals that sharpen what the AI logs."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: "Use measured usage to improve accuracy",
          subtitle:
            "Adds your Mac's actual app and website foreground time (Screen Time / ActivityWatch) to the AI's input. Local only."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { feedGroundTruth },
              set: { feedGroundTruth = $0; UsagePreferences.feedGroundTruthToAI = $0 }))
        }

        SettingsRow(
          label: "Read on-screen text (OCR)",
          subtitle: "Extracts the actual text on your screen and feeds it to the AI.",
          showsDivider: ocrEnabled || awLauncher.isInstalled
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { ocrEnabled },
              set: { ocrEnabled = $0; UsagePreferences.useScreenTextOCR = $0 }))
        }

        if ocrEnabled {
          SettingsRow(
            label: "OCR engine",
            subtitle: ocrStatus?.note
              ?? "Which engine reads your screen. Falls back to Apple Vision if it can't run.",
            showsDivider: awLauncher.isInstalled
          ) {
            HStack(spacing: 8) {
              if let status = ocrStatus {
                Image(
                  systemName: status.capable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12))
                .foregroundColor(
                  status.capable ? SettingsStyle.statusGood : SettingsStyle.statusWarn)
              }
              MinuteMenuLabelPicker(
                selection: Binding(
                  get: { ocrProvider },
                  set: {
                    ocrProvider = $0
                    UsagePreferences.ocrProvider = $0
                    Task { ocrStatus = await ScreenTextOCR.shared.activeEngineStatus() }
                  }),
                options: OCRProvider.allCases,
                title: { $0.displayName })
            }
          }
        }

        if awLauncher.isInstalled {
          SettingsRow(
            label: "Auto-launch ActivityWatch",
            subtitle:
              "Start ActivityWatch automatically when Dayflow launches."
              + (awLauncher.isRunning ? " It's running now." : " It isn't running right now."),
            showsDivider: false
          ) {
            SettingsToggle(
              isOn: Binding(
                get: { UsagePreferences.autoLaunchActivityWatch },
                set: { UsagePreferences.autoLaunchActivityWatch = $0 }))
          }
        }
      }
    }
    .task(id: ocrEnabled) {
      if ocrEnabled { ocrStatus = await ScreenTextOCR.shared.activeEngineStatus() }
    }
  }
}

// MARK: - Pickers (shared by productivity settings)

/// Compact minutes dropdown styled like the app's other menus.
struct MinuteMenuPicker: View {
  @Binding var selection: Int
  let options: [Int]

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { minutes in
        Button(Self.label(minutes)) { selection = minutes }
      }
    } label: {
      menuLabel(Self.label(selection))
    }
    .menuStyle(BorderlessButtonMenuStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .pointingHandCursor()
  }

  static func label(_ minutes: Int) -> String {
    if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60) hr" }
    return "\(minutes) min"
  }
}

/// Compact dropdown for any labeled option list.
struct MinuteMenuLabelPicker<Option: Hashable>: View {
  @Binding var selection: Option
  let options: [Option]
  let title: (Option) -> String

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button(title(option)) { selection = option }
      }
    } label: {
      menuLabel(title(selection))
    }
    .menuStyle(BorderlessButtonMenuStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .pointingHandCursor()
  }
}

private func menuLabel(_ text: String) -> some View {
  HStack(spacing: 5) {
    Text(text).font(.custom("Figtree", size: 13)).fontWeight(.semibold)
    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
  }
  .foregroundColor(SettingsStyle.ink)
  .padding(.horizontal, 12).padding(.vertical, 7)
  .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.05)))
}
