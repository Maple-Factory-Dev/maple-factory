import SwiftUI
import MapleKit

/// Recurring tasks: a goal's saved prompts that start a new task every N hours, days or weeks, on
/// whichever runner is online. The goal header's button, with a count, opens the sheet that lists them.
struct RecurringButton: View {
    let goal: Wire.Goal
    @Environment(FactoryClient.self) private var client
    @State private var showing = false

    var body: some View {
        let items = client.recurring(goalId: goal.id)
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                Text("Recurring")
                if !items.isEmpty {
                    Text("\(items.count)").foregroundStyle(Theme.textMuted)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Tasks this goal starts on a schedule, from a saved prompt")
        .sheet(isPresented: $showing) { RecurringSheet(goal: goal) }
    }
}

struct RecurringSheet: View {
    let goal: Wire.Goal
    @Environment(FactoryClient.self) private var client
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Wire.Recurring?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editing {
                RecurringEditor(goal: goal, item: editing) { saved in
                    if let saved { client.saveRecurring(saved) }
                    self.editing = nil
                }
            } else {
                list
            }
        }
        .frame(width: 560)
        .frame(minHeight: 340)
    }

    private var list: some View {
        let items = client.recurring(goalId: goal.id)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recurring tasks").font(.system(size: 17, weight: .semibold))
                Text("Each run starts a new task in \(goal.name) from its prompt and sends it to planning, on whichever runner is online. A run is skipped while the last one's task is still open.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 26)).foregroundStyle(Theme.textMuted)
                    Text("Nothing recurring yet").foregroundStyle(Theme.textMuted)
                    Text("Say, a weekly check for dependency updates.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.id) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Button { editing = Self.blank(goal: goal) } label: { Label("Add Recurring Task", systemImage: "plus") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private func row(_ item: Wire.Recurring) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    if item.paused {
                        Text("Paused")
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.fill))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Text(Self.everyText(item) + (item.repo.map { " · \($0)" } ?? "") + " · \(item.agent)")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                HStack(spacing: 10) {
                    Text(item.paused ? "Not running" : "Next: \(Self.when(item.nextAt))")
                    if let last = item.lastTask {
                        Button {
                            dismiss()
                            state.openTask(last)
                        } label: {
                            Text("Last: \(last)").underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help(item.lastRunAt.map { "Started \(Self.when($0))" } ?? "")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 4) {
                iconButton(item.paused ? "play.fill" : "pause.fill", help: item.paused ? "Resume" : "Pause") {
                    client.pauseRecurring(id: item.id, paused: !item.paused)
                }
                iconButton("bolt.fill", help: "Run now: start a task now; the schedule stays") { client.runRecurringNow(id: item.id) }
                iconButton("pencil", help: "Edit") { editing = item }
                iconButton("trash", help: "Delete") { client.deleteRecurring(id: item.id) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11)).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    static func blank(goal: Wire.Goal) -> Wire.Recurring {
        // Tomorrow at 9:00, here.
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let first = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return Wire.Recurring(id: "", goal: goal.id, title: "", brief: "", repo: nil, agent: "claude", every: 7 * 24 * 60, unit: .weeks,
                              firstAt: UInt64(first.timeIntervalSince1970 * 1000), timeZone: TimeZone.current.identifier,
                              nextAt: 0, paused: false, by: "")
    }

    static func unitMinutes(_ unit: Wire.RecurringUnit) -> UInt32 {
        switch unit {
        case .hours: return 60
        case .days: return 24 * 60
        case .weeks: return 7 * 24 * 60
        default: return 60
        }
    }

    static func everyText(_ item: Wire.Recurring) -> String {
        let n = max(1, Int(item.every / unitMinutes(item.unit)))
        let name: String
        switch item.unit {
        case .hours: name = "hour"
        case .days: name = "day"
        default: name = "week"
        }
        return n == 1 ? "Every \(name)" : "Every \(n) \(name)s"
    }

    static func when(_ ms: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

/// Add or edit one recurring task.
struct RecurringEditor: View {
    let goal: Wire.Goal
    @State private var item: Wire.Recurring
    @State private var count: Int
    @State private var first: Date
    let done: (Wire.Recurring?) -> Void

    init(goal: Wire.Goal, item: Wire.Recurring, done: @escaping (Wire.Recurring?) -> Void) {
        self.goal = goal
        self.done = done
        _item = State(initialValue: item)
        _count = State(initialValue: max(1, Int(item.every / RecurringSheet.unitMinutes(item.unit))))
        _first = State(initialValue: Date(timeIntervalSince1970: Double(item.firstAt) / 1000))
    }

    private var repos: [String] { goal.repos }
    private var valid: Bool { !item.title.trimmingCharacters(in: .whitespaces).isEmpty && !item.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.id.isEmpty ? "New recurring task" : "Edit recurring task")
                .font(.system(size: 17, weight: .semibold))
                .padding(20)
            Divider()
            Form {
                TextField("Title", text: $item.title, prompt: Text("Check for dependency updates"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt")
                    TextEditor(text: $item.brief)
                        .font(.system(size: 12.5))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
                    Text("Each run's task brief. Its planner writes a plan from it, and your risk policy says whether that needs approval.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                if repos.count > 1 {
                    Picker("Repo", selection: Binding(get: { item.repo ?? repos.first ?? "" }, set: { item.repo = $0 })) {
                        ForEach(repos, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Agent", selection: $item.agent) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }
                HStack {
                    Stepper(value: $count, in: 1...(item.unit == .hours ? 168 : item.unit == .days ? 90 : 52)) {
                        Text("Every \(count)")
                    }
                    Picker("", selection: $item.unit) {
                        Text(count == 1 ? "hour" : "hours").tag(Wire.RecurringUnit.hours)
                        Text(count == 1 ? "day" : "days").tag(Wire.RecurringUnit.days)
                        Text(count == 1 ? "week" : "weeks").tag(Wire.RecurringUnit.weeks)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DatePicker("First run", selection: $first)
                Text("Later runs keep this time of day in \(item.timeZone), across daylight saving.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(item.id.isEmpty ? "Add" : "Save") {
                    var saved = item
                    if saved.id.isEmpty { saved.id = UUID().uuidString.lowercased() }
                    saved.title = saved.title.trimmingCharacters(in: .whitespaces)
                    saved.every = UInt32(count) * RecurringSheet.unitMinutes(saved.unit)
                    saved.firstAt = UInt64(first.timeIntervalSince1970 * 1000)
                    if repos.count <= 1 { saved.repo = nil }
                    done(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(16)
        }
    }
}
