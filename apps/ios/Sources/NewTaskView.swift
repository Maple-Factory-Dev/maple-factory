import MapleKit
import PhotosUI
import SwiftUI

/// Starts a task from the phone: a goal, a title and brief, photos and screenshots for it, how soon,
/// which repo (when the goal spans several), the agent and the effort, and whether a planner picks it
/// up now or it waits as a draft. Sends `task.create`. Tickets aren't offered: on the Mac they come only
/// from intake requests, and there's no ticket search to pick one from.
struct NewTaskView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var goalID: String
    @State private var title = ""
    @State private var brief = ""
    @State private var priority: Wire.Priority = .p2
    @State private var repo: String?
    @State private var plan = true
    @State private var agent = "claude"
    /// "" for none, an effort's name, or `Self.newEffort` while one is typed in.
    @State private var effort = ""
    @State private var newEffort = ""
    @State private var uploads = AttachmentUploads()
    @FocusState private var titleFocused: Bool
    @FocusState private var effortFocused: Bool

    private static let newEffort = "\u{0}new"

    init(goal: String) {
        _goalID = State(initialValue: goal)
    }

    private var goal: Wire.Goal? { store.feed.goal(goalID) }
    private var uploading: Bool { uploads.uploading }
    private var canSend: Bool { goal != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !uploading }
    private var chosenEffort: String? {
        let name = effort == Self.newEffort ? newEffort : effort
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
                    MarkdownField(placeholder: "What should it do, and why?", text: $brief, identifier: "newTask.brief")
                } footer: {
                    Text("Left empty, the title is the brief.")
                }
                attachmentsSection
                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(Wire.Priority.allCases, id: \.self) { priority in
                            Text("\(priority.rawValue.uppercased()) · \(Self.priorityTitles[priority] ?? "")").tag(priority)
                        }
                    }
                    .accessibilityIdentifier("newTask.priority")
                    if store.agents.count > 1 {
                        Picker("Agent", selection: $agent) {
                            ForEach(store.agents, id: \.self) { id in
                                Label { Text(Self.agentTitle(id)) } icon: { Image(systemName: Self.agentSymbol(id)) }.tag(id)
                            }
                        }
                        .accessibilityIdentifier("newTask.agent")
                    }
                    Picker("Effort", selection: $effort) {
                        Text("None").tag("")
                        if let goal {
                            ForEach(store.efforts(in: goal), id: \.self) { Text($0).tag($0) }
                        }
                        Text("New effort…").tag(Self.newEffort)
                    }
                    .accessibilityIdentifier("newTask.effort")
                    if effort == Self.newEffort {
                        TextField("Effort name", text: $newEffort)
                            .focused($effortFocused)
                            .accessibilityIdentifier("newTask.newEffort")
                    }
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
                        store.createTask(goal: goal, title: title, brief: brief, repo: goal.repos.count > 1 ? repo : nil, priority: priority, plan: plan,
                                         agent: agent, effort: chosenEffort, attachments: uploads.attachments)
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
                uploads.injectTestAttachments(flag: "newTaskAttachment", store: store)
                // `-newTaskEffort <name>` opens with a new effort typed in, for a screenshot.
                if let name = UserDefaults.standard.string(forKey: "newTaskEffort"), !name.isEmpty {
                    effort = Self.newEffort
                    newEffort = name
                }
            }
            .onChange(of: goalID) {
                repo = goal?.repo ?? goal?.repos.first
                effort = ""
                newEffort = ""
            }
            .onChange(of: effort) { effortFocused = effort == Self.newEffort && !UserDefaults.standard.bool(forKey: "newTask") }
        }
    }

    private var attachmentsSection: some View {
        Section {
            AttachmentTray(uploads: uploads, prefix: "newTask")
        } header: {
            Text("Attachments")
        } footer: {
            if uploads.failed {
                Text("Tap a photo that didn't go up to try again.")
            } else if uploading {
                Text("Send waits for the uploads to finish.")
            }
        }
    }

    static func agentTitle(_ id: String) -> String {
        switch id {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: id.capitalized
        }
    }

    static func agentSymbol(_ id: String) -> String {
        switch id {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
    }
}
