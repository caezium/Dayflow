import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @ObservedObject private var miniTimer = MiniTimerWindowController.shared
  @ObservedObject private var awLauncher = ActivityWatchLauncher.shared
  @FocusState private var isOutputLanguageFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      appPreferencesSection
      outputLanguageSection
    }
  }

  // MARK: - App preferences

  private var appPreferencesSection: some View {
    SettingsSection(
      title: "App preferences",
      subtitle: "General toggles and telemetry settings."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: "Launch Dayflow at login",
          subtitle:
            "Keeps the menu bar controller running right after you sign in so capture can resume instantly."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          )
        }

        SettingsRow(label: "Share crash reports and anonymous usage data") {
          SettingsToggle(isOn: $viewModel.analyticsEnabled)
        }

        SettingsRow(
          label: "Show Dock icon",
          subtitle: "When off, Dayflow runs as a menu bar-only app."
        ) {
          SettingsToggle(isOn: $viewModel.showDockIcon)
        }

        SettingsRow(
          label: "Show app/website icons in timeline",
          subtitle: "When off, timeline cards won't show app or website icons."
        ) {
          SettingsToggle(isOn: $viewModel.showTimelineAppIcons)
        }

        SettingsRow(
          label: "Show daily goal popups",
          subtitle:
            "When off, Dayflow won't automatically open goal setup or yesterday's review after 4am."
        ) {
          SettingsToggle(isOn: $viewModel.showDailyGoalPopups)
        }

        SettingsRow(
          label: "Save all timelapses to disk",
          subtitle:
            "New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing."
        ) {
          SettingsToggle(isOn: $viewModel.saveAllTimelapsesToDisk)
        }

        SettingsRow(
          label: "Show focus timer",
          subtitle:
            "A small floating pill that counts up today's focused time live. Drag it anywhere; toggle it from the menu bar too."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { miniTimer.isVisible },
              set: { miniTimer.setVisible($0) }
            )
          )
        }

        SettingsRow(
          label: "Distraction nudges",
          subtitle:
            "A gentle reminder when you've spent too long distracted. Never blocks anything.",
          showsDivider: true
        ) {
          SettingsToggle(isOn: $viewModel.distractionNudgesEnabled)
        }

        if viewModel.distractionNudgesEnabled {
          SettingsRow(
            label: "Nudge after",
            subtitle: "Distraction time that triggers a nudge."
          ) {
            MinuteMenuPicker(
              selection: $viewModel.nudgeThresholdMinutes,
              options: ProductivityPreferences.nudgeThresholdMinuteOptions)
          }

          SettingsRow(
            label: "Wait between nudges",
            subtitle: "Minimum quiet time after a nudge before the next one."
          ) {
            MinuteMenuPicker(
              selection: $viewModel.nudgeCooldownMinutes,
              options: ProductivityPreferences.nudgeCooldownMinuteOptions)
          }
        }

        SettingsRow(
          label: "Use measured usage to improve accuracy",
          subtitle:
            "Adds your Mac's actual app and website foreground time (Screen Time / ActivityWatch) to the AI's input so it categorizes from facts, not just screenshots. Local only.",
          showsDivider: awLauncher.isInstalled
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { UsagePreferences.feedGroundTruthToAI },
              set: { UsagePreferences.feedGroundTruthToAI = $0 }
            ))
        }

        if awLauncher.isInstalled {
          SettingsRow(
            label: "Auto-launch ActivityWatch",
            subtitle:
              "Start ActivityWatch automatically when Dayflow launches, so its richer tracking is always available."
              + (awLauncher.isRunning ? " It's running now." : " It isn't running right now."),
            showsDivider: false
          ) {
            SettingsToggle(
              isOn: Binding(
                get: { UsagePreferences.autoLaunchActivityWatch },
                set: { UsagePreferences.autoLaunchActivityWatch = $0 }
              ))
          }
        }
      }
    }
  }

  // MARK: - Output language override

  private var outputLanguageSection: some View {
    SettingsSection(
      title: "Output language override",
      subtitle:
        "The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français)."
    ) {
      HStack(spacing: 10) {
        TextField("English", text: $viewModel.outputLanguageOverride)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
          .frame(maxWidth: 220)
          .focused($isOutputLanguageFocused)
          .onChange(of: viewModel.outputLanguageOverride) {
            viewModel.markOutputLanguageOverrideEdited()
          }

        SettingsSecondaryButton(
          title: viewModel.isOutputLanguageOverrideSaved ? "Saved" : "Save",
          systemImage: viewModel.isOutputLanguageOverrideSaved
            ? "checkmark" : nil,
          isDisabled: viewModel.isOutputLanguageOverrideSaved,
          action: {
            viewModel.saveOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        SettingsSecondaryButton(
          title: "Reset",
          action: {
            viewModel.resetOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        Spacer()
      }
    }
  }
}

/// Compact dropdown for picking a minutes value, styled like the other
/// Settings menus.
private struct MinuteMenuPicker: View {
  @Binding var selection: Int
  let options: [Int]

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { minutes in
        Button(Self.label(minutes)) { selection = minutes }
      }
    } label: {
      HStack(spacing: 5) {
        Text(Self.label(selection))
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundColor(SettingsStyle.ink)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.black.opacity(0.05))
      )
    }
    .menuStyle(BorderlessButtonMenuStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .pointingHandCursor()
  }

  static func label(_ minutes: Int) -> String {
    if minutes >= 60 && minutes % 60 == 0 {
      let hours = minutes / 60
      return "\(hours) hr"
    }
    return "\(minutes) min"
  }
}
