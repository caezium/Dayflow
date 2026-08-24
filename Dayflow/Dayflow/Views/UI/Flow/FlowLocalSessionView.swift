//
//  FlowLocalSessionView.swift
//  Dayflow
//
//  Fork-only: native Flow session controls that run entirely on-device, with
//  no Dayflow account and no beta whitelist. Drives FlowSessionMirror
//  directly, which is all the desktop overlay and the Codex distraction agent
//  need — the web bridge simply stays disconnected, so its backend events
//  no-op and nothing leaves the machine (the agent talks to the user's own
//  local codex CLI).
//

import SwiftUI

struct FlowLocalSessionView: View {
  @ObservedObject private var mirror = FlowSessionMirror.shared

  @State private var goalText = ""
  @State private var durationMinutes = 50
  @State private var alwaysOn = false
  @State private var alertStyle: FlowAlertStyle = .friendly

  private static let durationChoices = [15, 25, 50, 90]
  private static let accent = Color(hex: "F96E00")

  var body: some View {
    Group {
      switch mirror.snapshot.phase {
      case .idle:
        setupForm
      case .active:
        activeSession
      case .onBreak:
        breakView
      case .ended:
        endedView
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Idle: session setup

  private var setupForm: some View {
    VStack(spacing: 20) {
      Image(systemName: "water.waves")
        .font(.system(size: 40))
        .foregroundColor(Self.accent)
      Text("Start a flow session")
        .font(.custom("Figtree", size: 20).weight(.semibold))
        .foregroundColor(.black)
      Text("Runs locally — no account needed. The distraction agent watches through your own codex CLI.")
        .font(.custom("Figtree", size: 13))
        .foregroundColor(.black.opacity(0.6))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("What are you working on?")
            .font(.custom("Figtree", size: 13).weight(.medium))
            .foregroundColor(.black.opacity(0.8))
          TextField("One goal per line", text: $goalText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Length")
            .font(.custom("Figtree", size: 13).weight(.medium))
            .foregroundColor(.black.opacity(0.8))
          Picker("Length", selection: $durationMinutes) {
            ForEach(Self.durationChoices, id: \.self) { minutes in
              Text("\(minutes) min").tag(minutes)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .disabled(alwaysOn)
          Toggle("Always on (no end time)", isOn: $alwaysOn)
            .font(.custom("Figtree", size: 13))
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Nudge style")
            .font(.custom("Figtree", size: 13).weight(.medium))
            .foregroundColor(.black.opacity(0.8))
          Picker("Nudge style", selection: $alertStyle) {
            ForEach(FlowAlertStyle.allCases, id: \.self) { style in
              Text(style.rawValue.capitalized).tag(style)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }
      .frame(maxWidth: 380)

      Button("Start session") { startSession() }
        .buttonStyle(.borderedProminent)
        .tint(Self.accent)
        .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Active

  private var activeSession: some View {
    VStack(spacing: 20) {
      Image(systemName: "water.waves")
        .font(.system(size: 40))
        .foregroundColor(Self.accent)
        .symbolEffect(.variableColor.iterative, options: .repeating)

      countdown

      if let goals = mirror.snapshot.goals, !goals.isEmpty {
        VStack(spacing: 4) {
          ForEach(goals, id: \.self) { goal in
            Text(goal)
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.7))
          }
        }
      }

      if mirror.isDistracted {
        Text("Looks like you might be off track…")
          .font(.custom("Figtree", size: 13))
          .foregroundColor(Self.accent)
      }

      HStack(spacing: 12) {
        Button("Take a 5 min break") { startBreak(minutes: 5) }
          .buttonStyle(.bordered)
        Button("End session") { endSession() }
          .buttonStyle(.bordered)
          .tint(.red)
      }
    }
  }

  private var countdown: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if mirror.snapshot.alwaysOn {
        let elapsed = elapsedText(now: context.date)
        Text("In flow · \(elapsed)")
          .font(.custom("Figtree", size: 24).weight(.semibold))
          .foregroundColor(.black)
          .monospacedDigit()
      } else {
        Text(remainingText(now: context.date))
          .font(.custom("Figtree", size: 36).weight(.semibold))
          .foregroundColor(.black)
          .monospacedDigit()
      }
    }
  }

  // MARK: - Break

  private var breakView: some View {
    VStack(spacing: 20) {
      Image(systemName: "cup.and.saucer")
        .font(.system(size: 40))
        .foregroundColor(Self.accent)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text("On a break · \(breakRemainingText(now: context.date))")
          .font(.custom("Figtree", size: 20).weight(.semibold))
          .foregroundColor(.black)
          .monospacedDigit()
      }
      HStack(spacing: 12) {
        Button("Back to work") { resumeFromBreak() }
          .buttonStyle(.borderedProminent)
          .tint(Self.accent)
        Button("End session") { endSession() }
          .buttonStyle(.bordered)
          .tint(.red)
      }
    }
  }

  // MARK: - Ended

  private var endedView: some View {
    VStack(spacing: 20) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 40))
        .foregroundColor(Self.accent)
      Text("Session complete")
        .font(.custom("Figtree", size: 20).weight(.semibold))
        .foregroundColor(.black)
      if let startedAt = mirror.snapshot.sessionStartedAt {
        Text("You were in flow for \(sessionLengthText(startedAt: startedAt)).")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.black.opacity(0.6))
      }
      Button("Start another") { endSession() }
        .buttonStyle(.borderedProminent)
        .tint(Self.accent)
    }
  }

  // MARK: - Session transitions (all through the mirror)

  private func startSession() {
    var snapshot = FlowNativeSnapshot()
    snapshot.phase = .active
    snapshot.alertStyle = alertStyle
    snapshot.alwaysOn = alwaysOn
    let now = Int(Date().timeIntervalSince1970)
    snapshot.sessionStartedAt = now
    if !alwaysOn { snapshot.sessionEndsAt = now + durationMinutes * 60 }
    let goals = goalText
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    snapshot.goals = goals.isEmpty ? nil : goals
    mirror.apply(snapshot)
  }

  private func startBreak(minutes: Int) {
    var snapshot = mirror.snapshot
    snapshot.phase = .onBreak
    snapshot.breakEndsAt = Int(Date().timeIntervalSince1970) + minutes * 60
    mirror.apply(snapshot)
  }

  private func resumeFromBreak() {
    var snapshot = mirror.snapshot
    snapshot.phase = .active
    snapshot.breakEndsAt = nil
    mirror.apply(snapshot)
  }

  private func endSession() {
    mirror.apply(.idle)
  }

  // MARK: - Time formatting

  private func remainingText(now: Date) -> String {
    guard let endsAt = mirror.snapshot.sessionEndsAt else { return "--:--" }
    let remaining = max(0, endsAt - Int(now.timeIntervalSince1970))
    return String(format: "%d:%02d", remaining / 60, remaining % 60)
  }

  private func breakRemainingText(now: Date) -> String {
    guard let endsAt = mirror.snapshot.breakEndsAt else { return "--:--" }
    let remaining = max(0, endsAt - Int(now.timeIntervalSince1970))
    return String(format: "%d:%02d", remaining / 60, remaining % 60)
  }

  private func elapsedText(now: Date) -> String {
    let startedAt = mirror.snapshot.sessionStartedAt ?? Int(now.timeIntervalSince1970)
    let elapsed = max(0, Int(now.timeIntervalSince1970) - startedAt)
    return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
  }

  private func sessionLengthText(startedAt: Int) -> String {
    let end = mirror.snapshot.sessionEndsAt ?? Int(Date().timeIntervalSince1970)
    let minutes = max(1, (end - startedAt) / 60)
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }
}
