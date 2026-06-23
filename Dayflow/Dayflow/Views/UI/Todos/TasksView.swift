//
//  TasksView.swift
//  Dayflow
//
//  A daily task list. Unfinished tasks roll forward to today automatically; the
//  end-of-day AI pass can mark items done (shown with an "auto" badge). Uses
//  explicit dark colors (Dayflow paints a fixed light background).
//

import SwiftUI

struct TasksView: View {
  @ObservedObject private var store = TodoStore.shared
  @State private var newTitle = ""
  @State private var isDetecting = false
  @FocusState private var addFocused: Bool

  private let titleColor = Color(red: 0.2, green: 0.2, blue: 0.2)  // #333333
  private let subtitleColor = Color(red: 0.44, green: 0.44, blue: 0.44)  // #707070
  private let accent = Color(red: 0.976, green: 0.431, blue: 0.0)  // Dayflow orange

  private var today: String { TodoStore.todayString }
  private var todays: [TodoItem] { store.todos(for: today) }
  private var openCount: Int { todays.filter { !$0.isDone }.count }
  private var doneCount: Int { todays.filter { $0.isDone }.count }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        addRow
        card {
          if todays.isEmpty {
            Text("No tasks yet today. Add one above to get started.")
              .font(.custom("Figtree", size: 13)).foregroundColor(subtitleColor)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            VStack(spacing: 0) {
              ForEach(todays) { item in
                taskRow(item)
                if item.id != todays.last?.id {
                  Divider().background(Color.black.opacity(0.06))
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
    .onAppear { Task { await runDailyAutoFlow() } }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Tasks")
          .font(.custom("InstrumentSerif-Regular", size: 30))
          .foregroundColor(titleColor)
        Text(
          openCount == 0 && doneCount == 0
            ? "Plan today's work. Unfinished tasks carry over to tomorrow."
            : "\(openCount) to do · \(doneCount) done today"
        )
        .font(.custom("Figtree", size: 12)).foregroundColor(subtitleColor)
      }
      Spacer()
      if openCount > 0 {
        Button(action: detectDone) {
          HStack(spacing: 5) {
            if isDetecting {
              ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
              Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
            }
            Text(isDetecting ? "Checking…" : "Detect done")
              .font(.custom("Figtree", size: 12).weight(.medium))
          }
          .foregroundColor(titleColor)
          .padding(.horizontal, 11).frame(height: 30)
          .background(Color.white, in: Capsule())
          .overlay(Capsule().strokeBorder(Color.black.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(isDetecting)
        .pointingHandCursor()
        .help("Use AI to mark tasks your activity shows you've completed")
      }
    }
  }

  private func detectDone() {
    guard !isDetecting else { return }
    isDetecting = true
    Task {
      await TaskCompletionService.shared.checkCompletion(forDay: today)
      isDetecting = false
    }
  }

  /// Once per day: detect what got done yesterday (before carrying it forward),
  /// then roll any still-unfinished tasks onto today.
  private func runDailyAutoFlow() async {
    let key = "lastTaskAutoCheckDay"
    if UserDefaults.standard.string(forKey: key) != today {
      let yesterday = Date().addingTimeInterval(-24 * 3600)
        .getDayInfoFor4AMBoundary().dayString
      await TaskCompletionService.shared.checkCompletion(forDay: yesterday)
      UserDefaults.standard.set(today, forKey: key)
    }
    store.carryForwardIncomplete(to: today)
  }

  // MARK: - Add row

  private var addRow: some View {
    HStack(spacing: 10) {
      TextField("Add a task…", text: $newTitle)
        .textFieldStyle(.plain)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(titleColor)
        .focused($addFocused)
        .onSubmit(addTask)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.08)))
      Button(action: addTask) {
        Image(systemName: "plus")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(.white)
          .frame(width: 38, height: 38)
          .background(accent.opacity(newTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1))
          .cornerRadius(12)
      }
      .buttonStyle(.plain)
      .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
      .pointingHandCursor()
    }
  }

  private func addTask() {
    store.add(title: newTitle)
    newTitle = ""
    addFocused = true
  }

  // MARK: - Task row

  private func taskRow(_ item: TodoItem) -> some View {
    HStack(spacing: 12) {
      Button(action: { store.toggle(item.id) }) {
        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18))
          .foregroundColor(item.isDone ? accent : Color.black.opacity(0.3))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.custom("Figtree", size: 14))
          .foregroundColor(item.isDone ? subtitleColor : titleColor)
          .strikethrough(item.isDone, color: subtitleColor)
          .lineLimit(2)
        if item.carriedOver || item.autoCompleted {
          HStack(spacing: 6) {
            if item.carriedOver {
              badge("carried over", system: "arrow.uturn.forward")
            }
            if item.autoCompleted {
              badge("auto-detected", system: "sparkles")
            }
          }
        }
      }
      Spacer(minLength: 8)

      Button(action: { store.remove(item.id) }) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(subtitleColor)
          .frame(width: 22, height: 22)
          .background(Color.black.opacity(0.05), in: Circle())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .help("Delete task")
    }
    .padding(.vertical, 10)
  }

  private func badge(_ text: String, system: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: system).font(.system(size: 8, weight: .semibold))
      Text(text).font(.custom("Figtree", size: 10).weight(.medium))
    }
    .foregroundColor(subtitleColor)
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(Color.black.opacity(0.04), in: Capsule())
  }

  // MARK: - Card chrome

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white)
      .cornerRadius(16)
      .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.10), radius: 8, x: 0, y: 2)
  }
}
