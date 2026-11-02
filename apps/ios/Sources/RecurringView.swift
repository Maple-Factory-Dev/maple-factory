import MapleKit
import SwiftUI

/// Opens a goal's recurring tasks from its GoalView row.
struct RecurringRoute: Hashable { let goal: String }

/// Recurring / Scheduled: a goal's saved prompts that start a new task every N hours, days or weeks, on
/// whichever runner is online; or once, at a set time (a one-off, `once`, removed after it runs). Ported from the Mac's RecurringSheet. Like the server, only the goal's
/// lead or an admin can change them; anyone else sees the list read-only.
struct RecurringView: View {
    @Environment(FactoryStore.self) private var store
    let goalID: String

    /// The item the editor sheet is open on (a blank one with no id: adding).
    @State private var editing: Wire.Recurring?
    @State private var deleting: Wire.Recurring?
    @State private var openTask: String?

    var body: some View {
        if let goal = store.feed.goal(goalID) {
            let canLead = store.canLead(goal)
            let items = store.recurring(goal: goal.id)
            List {
                Section {
                    Text("Each run starts a new task in \(goal.name) from its prompt and sends it to planning, on whichever runner is online. A repeating run is skipped while the last one's task is still open; a one-off runs once at its time and is then removed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recurring-explainer")
                }
                Section {
                    if items.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing recurring or scheduled yet", systemImage: "clock.arrow.circlepath")
                        } description: {
                            Text("Say, a weekly check for dependency updates.")
                        }
                        .accessibilityIdentifier("recurring-empty")
                    }
                    ForEach(items, id: \.id) { item in
                        row(item, canLead: canLead)
                    }
                } footer: {
                    if !canLead {
                        Text("Only \(goal.lead) or an admin can change these.")
                            .accessibilityIdentifier("recurring-who")
                    }
                }
            }
            .navigationTitle("Recurring / Scheduled")
            .toolbar {
                if canLead {
                    ToolbarItem(placement: .primaryAction) {
                        Button { editing = .blank(goal: goal) } label: { Label("Add Scheduled Task", systemImage: "plus") }
                            .accessibilityIdentifier("recurring-add")
                    }
                }
            }
            .sheet(item: Binding(get: { editing.map(EditingItem.init) }, set: { editing = $0?.item })) { open in
                RecurringEditor(goal: goal, item: open.item) { saved in
                    if let saved { store.saveRecurring(saved) }
                    editing = nil
                }
            }
            .confirmationDialog(deleting.map { "Delete \($0.title)?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let deleting { store.deleteRecurring(id: deleting.id) }
                    deleting = nil
                }
                .accessibilityIdentifier("recurring-delete-confirm")
            } message: {
                Text("No more tasks start from it. Tasks it already started stay.")
            }
            .navigationDestination(item: $openTask) { TaskDetailView(id: $0) }
            // `-recurringEdit YES` opens the editor on the first item, for screenshots.
            .task {
                if canLead, editing == nil, UserDefaults.standard.bool(forKey: "recurringEdit") { editing = items.first }
            }
        } else {
            ContentUnavailableView("Goal not found", systemImage: "flag.slash")
        }
    }

    private func row(_ item: Wire.Recurring, canLead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.once == true ? "calendar" : "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(item.once == true ? "recurring-once-\(item.id)" : "recurring-repeats-\(item.id)")
                Text(item.title).font(.body.weight(.semibold))
                if item.paused {
                    Text("Paused")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recurring-paused-\(item.id)")
                }
            }
            Text((item.once == true ? "Once · \(Wire.Recurring.when(item.firstAt))" : item.everyText) + (item.repo.map { " · \($0)" } ?? "") + " · \(NewTaskView.agentTitle(item.agent))")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if item.once != true || item.paused {
                    Text(item.paused ? "Not running" : "Next: \(Wire.Recurring.when(item.nextAt))")
                }
                if let last = item.lastTask {
                    Button { openTask = last } label: { Text("Last: \(last)").underline() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("recurring-last-\(item.id)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if canLead { editing = item } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recurring-row-\(item.id)")
        .swipeActions(edge: .trailing) {
            if canLead {
                Button { store.runRecurringNow(id: item.id) } label: { Label("Run Now", systemImage: "bolt.fill") }
                    .tint(Theme.accent)
                    .accessibilityIdentifier("recurring-run-\(item.id)")
                pauseButton(item)
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .leading) {
            if canLead {
                Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                    .accessibilityIdentifier("recurring-delete-\(item.id)")
            }
        }
        .contextMenu {
            if canLead {
                Button { store.runRecurringNow(id: item.id) } label: {
                    Label("Run Now", systemImage: "bolt.fill")
                    Text(item.once == true ? "Starts its task now, instead of at its time" : "Starts a task now; the schedule stays")
                }
                pauseButton(item)
                Button { editing = item } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func pauseButton(_ item: Wire.Recurring) -> some View {
        Button { store.pauseRecurring(id: item.id, paused: !item.paused) } label: {
            Label(item.paused ? "Resume" : "Pause", systemImage: item.paused ? "play.fill" : "pause.fill")
        }
        .accessibilityIdentifier("recurring-pause-\(item.id)")
    }

    /// `.sheet(item:)` wants an Identifiable; a blank item (no id yet) gets one of its own.
    private struct EditingItem: Identifiable {
        let item: Wire.Recurring
        var id: String { item.id.isEmpty ? "new" : item.id }
    }
}

/// Add or edit one recurring or one-off (scheduled) task.
struct RecurringEditor: View {
    let goal: Wire.Goal
    @State private var item: Wire.Recurring
    @State private var count: Int
    @State private var first: Date
    @State private var once: Bool
    let done: (Wire.Recurring?) -> Void

    init(goal: Wire.Goal, item: Wire.Recurring, done: @escaping (Wire.Recurring?) -> Void) {
        self.goal = goal
        self.done = done
        _item = State(initialValue: item)
        _count = State(initialValue: max(1, Int(item.every / Wire.Recurring.unitMinutes(item.unit))))
        _first = State(initialValue: Date(timeIntervalSince1970: Double(item.firstAt) / 1000))
        _once = State(initialValue: item.once == true)
    }

    private var repos: [String] { goal.repos }
    private var valid: Bool {
        !item.title.trimmingCharacters(in: .whitespaces).isEmpty && !item.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The Mac's caps: a week of hours, 90 days, a year of weeks.
    private var maxCount: Int { item.unit == .hours ? 168 : item.unit == .days ? 90 : 52 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $item.title, prompt: Text("Check for dependency updates"))
                        .accessibilityIdentifier("recurring-title")
                }
                Section {
                    TextEditor(text: $item.brief)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("recurring-prompt")
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Each run's task brief. Its planner writes a plan from it, and your risk policy says whether that needs approval.")
                }
                Section {
                    if repos.count > 1 {
                        Picker("Repo", selection: Binding(get: { item.repo ?? repos.first ?? "" }, set: { item.repo = $0 })) {
                            ForEach(repos, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Picker("Agent", selection: $item.agent) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                }
                Section {
                    Picker("Repeats", selection: $once) {
                        Text("Once at a time").tag(true)
                        Text("Repeating").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("recurring-repeats")
                    if once {
                        DatePicker("Runs at", selection: $first, in: Date()...)
                            .accessibilityIdentifier("recurring-runs-at")
                    } else {
                        Stepper(value: $count, in: 1...maxCount) { Text("Every \(count)") }
                            .accessibilityIdentifier("recurring-every")
                        Picker("Unit", selection: $item.unit) {
                            Text(count == 1 ? "hour" : "hours").tag(Wire.RecurringUnit.hours)
                            Text(count == 1 ? "day" : "days").tag(Wire.RecurringUnit.days)
                            Text(count == 1 ? "week" : "weeks").tag(Wire.RecurringUnit.weeks)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: item.unit) { _, _ in count = min(count, maxCount) }
                        DatePicker("First run", selection: $first)
                    }
                } footer: {
                    Text(once ? "It starts one task then, and is removed; the task is the record."
                              : "Later runs keep this time of day in \(item.timeZone), across daylight saving.")
                }
            }
            .navigationTitle(item.id.isEmpty ? (once ? "New Scheduled Task" : "New Recurring Task") : (once ? "Edit Scheduled Task" : "Edit Recurring Task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { done(nil) }.accessibilityIdentifier("recurring-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item.id.isEmpty ? "Add" : "Save") { done(saved) }
                        .disabled(!valid)
                        .accessibilityIdentifier("recurring-save")
                }
            }
        }
    }

    private var saved: Wire.Recurring {
        var saved = item
        if saved.id.isEmpty { saved.id = UUID().uuidString.lowercased() }
        saved.title = saved.title.trimmingCharacters(in: .whitespaces)
        saved.every = UInt32(count) * Wire.Recurring.unitMinutes(saved.unit)
        saved.firstAt = UInt64(first.timeIntervalSince1970 * 1000)
        saved.once = once ? true : nil
        if repos.count <= 1 { saved.repo = nil }
        return saved
    }
}

/// The Mac's RecurringSheet helpers, copied: the Mac app target isn't shared with the iPhone.
extension Wire.Recurring {
    /// A new one: weekly, tomorrow at 9:00 here, with Claude.
    static func blank(goal: Wire.Goal) -> Wire.Recurring {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let first = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return Wire.Recurring(id: "", goal: goal.id, title: "", brief: "", repo: nil, agent: "claude", every: 7 * 24 * 60, unit: .weeks,
                              firstAt: UInt64(first.timeIntervalSince1970 * 1000), timeZone: TimeZone.current.identifier,
                              nextAt: 0, paused: false, by: "")
    }

    static func unitMinutes(_ unit: Wire.RecurringUnit) -> UInt32 {
        switch unit {
        case .hours: 60
        case .days: 24 * 60
        case .weeks: 7 * 24 * 60
        default: 60
        }
    }

    /// "Every week", "Every 2 weeks".
    var everyText: String {
        let n = max(1, Int(every / Self.unitMinutes(unit)))
        let name = switch unit {
        case .hours: "hour"
        case .days: "day"
        default: "week"
        }
        return n == 1 ? "Every \(name)" : "Every \(n) \(name)s"
    }

    static func when(_ ms: UInt64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
