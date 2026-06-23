import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @ObservedObject private var miniTimer = MiniTimerWindowController.shared
  @ObservedObject private var awLauncher = ActivityWatchLauncher.shared
  @FocusState private var isOutputLanguageFocused: Bool
  @State private var appLanguage = AppLanguagePreferences.selection()

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      appPreferencesSection
      outputLanguageSection
    }
  }

  // MARK: - App preferences

  private var appPreferencesSection: some View {
    SettingsSection(
      title: String(localized: "App preferences"),
      subtitle: String(localized: "General toggles and telemetry settings.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: String(localized: "App language"),
          subtitle: String(
            localized:
              "Choose a language for Dayflow only. Quit and reopen the app to apply a change.")
        ) {
          Picker("App language", selection: $appLanguage) {
            ForEach(AppLanguage.allCases) { language in
              Text(verbatim: language.title).tag(language)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(width: 210)
          .onChange(of: appLanguage) {
            AppLanguagePreferences.setSelection(appLanguage)
          }
        }

        SettingsRow(
          label: String(localized: "Light/Dark mode"),
          subtitle: String(localized: "Follow the system setting or pick light or dark.")
        ) {
          Picker("", selection: $appearance) {
            ForEach(DayflowAppearance.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 210)
          .onChange(of: appearance) { _, newValue in
            AnalyticsService.shared.capture(
              "appearance_changed", ["appearance": newValue.rawValue])
          }
        }

        SettingsRow(
          label: String(localized: "Launch Dayflow at login"),
          subtitle:
            String(
              localized:
                "Keeps the menu bar controller running right after you sign in so capture can resume instantly."
            )
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          )
        }

        SettingsRow(
          label: String(localized: "Pause lengths"),
          subtitle: String(localized: "The three timed options shown when you pause Dayflow.")
        ) {
          HStack(spacing: 6) {
            ForEach(viewModel.pausePresetMinutes.indices, id: \.self) { index in
              Picker("Pause length", selection: $viewModel.pausePresetMinutes[index]) {
                ForEach(PausePresets.minuteOptions, id: \.self) { minutes in
                  Text(verbatim: PauseDuration.timed(minutes: minutes).shortLabel).tag(minutes)
                }
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .frame(width: 78)
            }
          }
        }

        SettingsRow(label: String(localized: "Share crash reports and anonymous usage data")) {
          SettingsToggle(isOn: $viewModel.analyticsEnabled)
        }

        SettingsRow(
          label: String(localized: "Show Dock icon"),
          subtitle: String(localized: "When off, Dayflow runs as a menu bar-only app.")
        ) {
          SettingsToggle(isOn: $viewModel.showDockIcon)
        }

        SettingsRow(
          label: String(localized: "Show app/website icons in timeline"),
          subtitle: String(localized: "When off, timeline cards won't show app or website icons.")
        ) {
          SettingsToggle(isOn: $viewModel.showTimelineAppIcons)
        }

        SettingsRow(
          label: String(localized: "Show daily goal popups"),
          subtitle:
            String(
              localized:
                "When off, Dayflow won't automatically open goal setup or yesterday's review after 4am."
            )
        ) {
          SettingsToggle(isOn: $viewModel.showDailyGoalPopups)
        }

        SettingsRow(
          label: String(localized: "Save all timelapses to disk"),
          subtitle:
            String(
              localized:
                "New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing."
            )
        ) {
          SettingsToggle(isOn: $viewModel.saveAllTimelapsesToDisk)
        }

        SettingsRow(
          label: String(localized: "Getting started guide"),
          subtitle: String(
            localized:
              "Replay the welcome tour and bring back the first-day checklist on your timeline.")
        ) {
          SettingsSecondaryButton(
            title: String(localized: "Show again"),
            action: { GettingStarted.replay() }
          )
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
      title: String(localized: "Output language override"),
      subtitle:
        String(
          localized:
            "AI output follows the app language by default. Enter a language to override it, or reset to follow the app language. Existing summaries stay unchanged."
        )
    ) {
      HStack(spacing: 10) {
        TextField("App language", text: $viewModel.outputLanguageOverride)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
          .frame(maxWidth: 220)
          .focused($isOutputLanguageFocused)
          .onChange(of: viewModel.outputLanguageOverride) {
            viewModel.markOutputLanguageOverrideEdited()
          }

        SettingsSecondaryButton(
          title: viewModel.isOutputLanguageOverrideSaved
            ? String(localized: "Saved") : String(localized: "Save"),
          systemImage: viewModel.isOutputLanguageOverrideSaved
            ? "checkmark" : nil,
          isDisabled: viewModel.isOutputLanguageOverrideSaved,
          action: {
            viewModel.saveOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        SettingsSecondaryButton(
          title: String(localized: "Reset"),
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
