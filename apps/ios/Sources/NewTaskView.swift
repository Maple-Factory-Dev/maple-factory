import MapleKit
import SwiftUI

/// Starts a task from the phone: a goal, a title and brief, how soon, which repo (when the goal spans
/// several), and whether a planner picks it up now or it waits as a draft. Sends `task.create`.
/// Attachments, tickets, the agent and the effort are the Mac composer's for now.
struct NewTaskView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var goalID: String
    @State private var title = ""
    @State private var brief = ""
    @State private var priority: Wire.Priority = .p2
    @State private var repo: String?
    @State private var plan = true
    @FocusState private var titleFocused: Bool

    init(goal: String) {
        _goalID = State(initialValue: goal)
    }

    private var goal: Wire.Goal? { store.feed.goal(goalID) }
    private var canSend: Bool { goal != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static let priorityTitles: [Wire.Priority: String] = [.p0: "Do it right away", .p1: "Next", .p2: "Soon", .p3: "When there's room"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Goal", selection: $goalID) {
                        ForEach(store.feed.activeGoals) { goal in
                            Text(goal.name).tag(goal.id)
                        }
                    }
                    .accessibilityIdentifier("newTask.goal")
                    if let goal, goal.repos.count > 1 {
                        Picker("Repo", selection: $repo) {
                            ForEach(goal.repos, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .accessibilityIdentifier("newTask.repo")
                    }
                }
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                        .accessibilityIdentifier("newTask.title")
                    TextField("What should it do, and why?", text: $brief, axis: .vertical)
                        .lineLimit(5...12)
                        .accessibilityIdentifier("newTask.brief")
                } footer: {
                    Text("Left empty, the title is the brief.")
                }
                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(Wire.Priority.allCases, id: \.self) { priority in
                            Text("\(priority.rawValue.uppercased()) · \(Self.priorityTitles[priority] ?? "")").tag(priority)
                        }
                    }
                    .accessibilityIdentifier("newTask.priority")
                }
                Section {
                    Picker("When", selection: $plan) {
                        Text("Plan now").tag(true)
                        Text("Save as draft").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newTask.when")
                } footer: {
                    Text(plan ? "A planner writes a plan for you to approve." : "It waits in the goal's drafts until you send it to planning.")
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        guard let goal else { return }
                        store.createTask(goal: goal, title: title, brief: brief, repo: goal.repos.count > 1 ? repo : nil, priority: priority, plan: plan)
                        dismiss()
                    }
                    .disabled(!canSend)
                    .accessibilityIdentifier("newTask.send")
                }
            }
            .onAppear {
                repo = goal?.repo ?? goal?.repos.first
                // Opened by `-newTask YES` for a screenshot, the keyboard would hide the form.
                titleFocused = !UserDefaults.standard.bool(forKey: "newTask")
            }
            .onChange(of: goalID) { repo = goal?.repo ?? goal?.repos.first }
        }
    }
}
