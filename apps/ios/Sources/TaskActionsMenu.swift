import MapleKit
import SwiftUI

/// The task's toolbar `…`: what the Mac's TaskActionButtons offers, gated the same way. Its place in
/// the queue (Move to top/bottom), what's next (Send to planning, Send to backlog, Cancel task…) and,
/// while it's open, who has it and what it says (Take it over, Assign…, Edit…, Move to goal…).
/// Above those, Retry, Recheck GitHub and Split… where the Mac offers them.
/// Cancel asks first; Assign, Edit, Move to goal and Split open sheets.
struct TaskActionsMenu: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task

    @State private var sheet: Sheet?
    @State private var confirmCancel = false

    enum Sheet: String, Identifiable { case assign, edit, move, effort, split; var id: String { rawValue } }

    private var open: Bool { task.state != .merged && task.state != .cancelled }
    /// Nothing runs to retry while it waits on its plan's approval, is a draft or sits in the backlog
    /// (the Mac's TaskActionButtons); a cancelled task picks back up with Retry.
    private var retryable: Bool {
        ![.merged, .drafting, .awaitingApproval, .backlog].contains(task.state)
    }
    /// A pull request on GitHub (not a local repo's) that hasn't merged: the Mac PR card's Recheck.
    private var recheckable: Bool { open && task.pr?.url != nil && task.pr?.state != .merged }
    /// Open with a plan of at least two steps and its PR not merged (the Mac's `plan.count >= split`).
    private var splittable: Bool { open && task.plan.count >= 2 && task.pr?.state != .merged }
    private var queued: Bool { task.queueRank != nil && (task.state == .planning || task.state == .building) }

    var body: some View {
        Menu {
            if queued {
                Section {
                    Button { store.queueTop(task.id) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
                    Button { store.queueBottom(task.id) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
                }
            }
            if retryable || recheckable || splittable {
                Section {
                    if retryable {
                        Button { store.retryTask(task.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    }
                    if recheckable {
                        Button { store.recheckGitHub(task.id) } label: { Label("Recheck GitHub", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    if splittable {
                        Button { sheet = .split } label: { Label("Split…", systemImage: "square.split.2x1") }
                    }
                }
            }
            if open {
                Section {
                    if task.state == .drafting {
                        Button { store.plan(task.id) } label: { Label("Send to planning", systemImage: "paperplane") }
                    }
                    if task.state == .backlog {
                        Button { store.plan(task.id) } label: { Label(task.plan.isEmpty ? "Send to planning" : "Plan again", systemImage: "paperplane") }
                    }
                    if task.state == .drafting || task.state == .awaitingApproval {
                        Button { store.sendToBacklog(task.id) } label: { Label("Send to backlog", systemImage: Wire.TaskState.backlog.icon) }
                    }
                    Button(role: .destructive) { confirmCancel = true } label: { Label("Cancel task…", systemImage: "xmark.circle") }
                }
                Section {
                    if task.owner != store.me, !store.me.isEmpty {
                        Button { store.assign(task.id, to: store.me) } label: { Label("Take it over", systemImage: "person.crop.circle.badge.checkmark") }
                    }
                    if store.canReassign(task) {
                        Button { sheet = .assign } label: { Label("Assign…", systemImage: "person.badge.plus") }
                    }
                    Button { sheet = .edit } label: { Label("Edit title & brief…", systemImage: "pencil") }
                    Button { sheet = .effort } label: { Label(task.effort == nil ? "Add to effort…" : "Change effort…", systemImage: "square.stack.3d.up") }
                    Button { sheet = .move } label: { Label("Move to goal…", systemImage: "folder") }
                        .disabled(!store.moveTargets(task).contains { $0.blocked == nil })
                }
            }
        } label: {
            Label("Task actions", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("taskActions")
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .assign: AssignSheet(task: task)
                case .edit: EditTaskSheet(task: task)
                case .move: MoveGoalSheet(task: task)
                case .split: SplitSheet(task: task)
                case .effort: EffortSheet(task: task)
                }
            }
            .environment(store)
        }
        .confirmationDialog("Cancel \(task.id)?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Task", role: .destructive) { store.cancel(task.id) }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(Self.stops(task))
        }
    }

    /// What cancelling ends, in a sentence (the Mac's CancelTaskConfirmation.stops).
    static func stops(_ task: Wire.Task) -> String {
        var parts: [String] = []
        if let worker = task.worker { parts.append("its running \(worker.role.rawValue) session") }
        else if task.state == .planning || task.state == .building || task.liveLog != nil { parts.append("its running session") }
        if let pr = task.pr, pr.state == .open || pr.state == .draft { parts.append("its open PR #\(pr.number)") }
        if task.state == .awaitingApproval { parts.append("the pending plan approval") }
        if task.state == .reviewing, task.pr?.state != .merged { parts.append("the pending review") }
        if task.question != nil || task.hand != nil { parts.append("the open question to you") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first
        return (list.map { "This stops \($0). " } ?? "") + "Its branch stays, and you can pick it back up with Retry."
    }
}

/// The org's members, you first and the current owner checked; tapping one gives them the task.
private struct AssignSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: Wire.Task

    private var members: [Wire.Member] {
        store.feed.members.filter { $0.login == store.me } + store.feed.members.filter { $0.login != store.me }
    }

    var body: some View {
        List(members, id: \.login) { member in
            Button {
                store.assign(task.id, to: member.login)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Avatar(login: member.login, url: member.avatarUrl, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.login == store.me ? "\(member.name ?? member.login) (you)" : member.name ?? member.login)
                            .foregroundStyle(.primary)
                        Text(member.login).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if member.login == task.owner { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .accessibilityIdentifier("assign-\(member.login)")
        }
        .navigationTitle("Assign \(task.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// The task's title and brief; Save sends whichever changed.
private struct EditTaskSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: Wire.Task
    @State private var title: String
    @State private var brief: String

    init(task: Wire.Task) {
        self.task = task
        _title = State(initialValue: task.title)
        _brief = State(initialValue: task.brief)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool {
        trimmedTitle != task.title || brief.trimmingCharacters(in: .whitespacesAndNewlines) != task.brief.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $title, axis: .vertical)
                    .accessibilityIdentifier("edit-title")
            }
            Section {
                MarkdownField(placeholder: "What should it do, and why?", text: $brief, identifier: "edit-brief", minHeight: 180)
            } header: {
                Text("Brief")
            } footer: {
                Text("Markdown. Everyone sees the new title on the board; a new brief is what the next planner reads.")
            }
        }
        .navigationTitle("Edit \(task.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    store.edit(task.id, title: title, brief: brief)
                    dismiss()
                }
                .disabled(trimmedTitle.isEmpty || !changed)
                .accessibilityIdentifier("edit-save")
            }
        }
    }
}

/// The goals the task can move to; one that doesn't work in its repo is greyed out and says why.
private struct MoveGoalSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: Wire.Task

    var body: some View {
        List {
            Section {
                ForEach(store.moveTargets(task), id: \.goal.id) { target in
                    Button {
                        store.moveGoal(task.id, to: target.goal)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color(goalHex: target.goal.color)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.goal.name).foregroundStyle(target.blocked == nil ? .primary : .secondary)
                                if let blocked = target.blocked {
                                    Text(blocked.prefix(1).uppercased() + blocked.dropFirst()).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(target.blocked != nil)
                    .accessibilityIdentifier("move-\(target.goal.id)")
                }
            } footer: {
                Text("It keeps its id, branch and pull request.")
            }
        }
        .navigationTitle("Move \(task.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// How many tasks to split into, from 2 to the plan's steps (at most 6), starting at what the PR
/// budget suggests; the list shows which steps each part gets.
private struct SplitSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: Wire.Task
    @State private var parts = 2

    private var most: Int { max(2, min(task.plan.count, 6)) }
    private var chunks: [[Wire.PlanStep]] { FactoryStore.splitSteps(task.plan, parts: parts) }
    private var footer: String {
        let how = "\(task.id) keeps its first steps; the rest become new tasks that get planned on their own."
        guard let suggested = store.suggestedSplit(task), let policy = store.feed.policy else { return how }
        return "Over the PR budget: \(suggested) parts keep each under \(policy.maxFiles) files and \(policy.maxLines) lines. " + how
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $parts, in: 2...most) {
                    LabeledContent("Parts", value: "\(parts)")
                }
                .accessibilityIdentifier("split-parts")
                .accessibilityValue("\(parts)")
            } footer: {
                Text(footer)
            }
            ForEach(Array(chunks.enumerated()), id: \.offset) { index, steps in
                Section(index == 0 ? "\(task.id) keeps" : "New task \(index)") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.text)
                            if !step.file.isEmpty { Text(step.file).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .onAppear { if let suggested = store.suggestedSplit(task) { parts = min(max(suggested, 2), most) } }
        .navigationTitle("Split \(task.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Split") {
                    store.split(task.id, into: parts)
                    dismiss()
                }
                .disabled(chunks.count < 2)
                .accessibilityIdentifier("split-confirm")
            }
        }
    }
}
