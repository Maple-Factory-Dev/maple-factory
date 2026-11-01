import SwiftUI

// Building blocks shared by the task inspector (sidebar) and the full-focus task view.

enum ComposerMode { case steer, comment }

struct TaskSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            content
        }
    }
}

/// A section that can fold to its title and a one-line summary; the chevron, or clicking the line, toggles it.
struct FoldableSection<Content: View>: View {
    let title: String
    let summary: String
    @Binding var folded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                SectionLabel(title: title)
                if folded {
                    Text(summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { folded.toggle() } }
            .help(folded ? "Show the \(title.lowercased())" : "Fold the \(title.lowercased())")
            if !folded { content }
        }
    }
}

extension FactoryTask {
    /// "v2 · 6 steps, all done": the plan in a line, for its folded header.
    var planSummary: String {
        let done = plan.filter { $0.progress == .done }.count
        let steps = "\(plan.count) \(plan.count == 1 ? "step" : "steps")"
        let progress = done == plan.count ? (plan.count == 1 ? "done" : "all done") : done == 0 ? "" : "\(done) done"
        return [planVersion > 1 ? "v\(planVersion)" : nil, progress.isEmpty ? steps : "\(steps), \(progress)"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The brief's (or spec's) first sentence, without its markdown, for its folded header.
    var briefSummary: String {
        let source = spec.flatMap { $0.isEmpty ? nil : $0 } ?? brief
        let line = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-_ \t")) }
            .first { !$0.isEmpty } ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if let end = plain.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { return String(plain[..<end.upperBound]).trimmingCharacters(in: .whitespaces) }
        return plain
    }
}

struct ViewerPill: View {
    let viewer: Person

    var body: some View {
        HStack(spacing: 5) {
            AgentAvatar(agent: viewer, size: 16, online: true)
            Text("\(viewer.firstName) is here")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(viewer.color)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(Capsule().fill(viewer.color.opacity(0.12)))
    }
}

/// State badge followed by "owner → agent".
struct TaskOwnership: View {
    let task: FactoryTask
    var avatarSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(state: task.state)
            OwnerMenu(task: task, avatarSize: avatarSize, spacing: 8)
            if let agent = task.agent {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                AgentAvatar(agent: agent, size: avatarSize)
                Text(agent.name)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
    }
}

/// A task's owner (avatar, then "You" or their first name). While the task is open the name opens a menu
/// to take it over or give it to a teammate; once it's merged, closed or cancelled it's plain text.
struct OwnerMenu: View {
    let task: FactoryTask
    var avatarSize: CGFloat = 18
    var showAvatar = true
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            if showAvatar { AgentAvatar(agent: task.owner, size: avatarSize) }
            let name = Text(task.owner.id == FactoryData.me.id ? "You" : task.owner.firstName)
                .foregroundStyle(Theme.text)
            if !task.state.isFinished {
                // Picks its owner: take it over, or (its owner, an admin) give it to a teammate.
                Menu {
                    TaskAssignButtons(task: task)
                } label: {
                    name
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change who owns it")
            } else {
                name
            }
        }
    }
}

/// A task's priority as a small chip: P0 red, P1 amber, the rest muted. Nothing when it has none.
struct PriorityChip: View {
    let priority: String?

    private static let titles = ["p0": "Do it right away", "p1": "Next", "p2": "Soon", "p3": "When there's room"]

    var body: some View {
        if let priority {
            let color = priority == "p0" ? Theme.State.cancelled : priority == "p1" ? Theme.State.awaitingApproval : Theme.textMuted
            Text(priority.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(priority == "p0" || priority == "p1" ? color.opacity(0.13) : Theme.fill))
                .help("\(priority.uppercased()): \(Self.titles[priority] ?? "priority")")
        }
    }
}

/// Where a task came from, when it didn't start as someone's idea: split off an over-budget task, a
/// leftover a Scout run picked up, or a follow-up of another task's review. Each names the task, linked.
struct TaskOrigin: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask

    var body: some View {
        if task.splitFrom != nil || task.scoutedFrom != nil || task.followUpOf != nil {
            HStack(spacing: 12) {
                if let id = task.splitFrom { line("arrow.triangle.branch", "Split from", id, nil) }
                if let from = task.scoutedFrom {
                    let parts = from.split(separator: "#", maxSplits: 1).map(String.init)
                    line("binoculars", "Scouted from", parts[0], parts.count > 1 ? "a review finding" : nil)
                }
                if let from = task.followUpOf {
                    let parts = from.split(separator: "#", maxSplits: 1).map(String.init)
                    line("arrow.turn.down.right", "Follow-up of", parts[0], parts.count > 1 ? "a review finding" : nil)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
        }
    }

    private func line(_ icon: String, _ label: String, _ id: String, _ detail: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(label)
            Text(id)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .onTapGesture { appState.openReference(id) }
                .taskHovercard(id)
            if let detail { Text("· \(detail)") }
        }
    }
}

/// The ⋯ menu on a task: what to do next, editing it, and getting at it, with Cancel's confirmation
/// and the Rename alert.
struct TaskActionsMenu<Label: View>: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @ViewBuilder var label: Label
    @State private var confirmCancel = false
    @State private var rename = false
    @State private var scheduling = false

    var body: some View {
        Menu {
            TaskActionButtons(task: task, confirmCancel: $confirmCancel, rename: $rename, schedule: { scheduling = true })
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Task actions")
        .popover(isPresented: $scheduling, arrowEdge: .bottom) { SchedulePopover(task: task) }
        .cancelTaskConfirmation(task: task, isPresented: Binding(
            get: { confirmCancel || appState.confirmingCancel == task.id },
            set: { if !$0 { confirmCancel = false; appState.confirmingCancel = nil } }
        ))
        .renameTask(task: task, isPresented: $rename)
    }
}

/// Everything you can do to a task, for a menu or a row's context menu: the queue's (Move to top,
/// Schedule…, Start now, Run now; Queue on a draft), then what to do next (Send to planning, Retry,
/// Cancel task…), editing (Rename…, teammates' machines) and getting at it (pull request, branch,
/// ID). Cancel and Rename only ask; the caller shows the confirmation (`cancelTaskConfirmation`) and
/// the alert (`renameTask`).
struct TaskActionButtons: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var confirmCancel: Bool
    @Binding var rename: Bool
    /// Shows the Schedule… popover; without it there's no Schedule….
    var schedule: (() -> Void)? = nil

    private var open: Bool { !task.state.isFinished }

    var body: some View {
        if task.queued {
            Button { appState.moveToTop(task.id) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
            Button { appState.moveToBottom(task.id) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
            if let schedule {
                Button(action: schedule) { Label("Schedule…", systemImage: "clock") }
            }
            Button { appState.startNow(task.id) } label: { Label("Start now", systemImage: "play") }
            if task.state == .planning || task.state == .building {
                Button { appState.forceStart(task.id) } label: { Label("Run now, skip the slot wait", systemImage: "bolt") }
            }
            Divider()
        } else if task.state == .drafting {
            // Its place among the goal's drafts; it stays a draft.
            Button { appState.moveDraftToTop(task.id) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
            Button { appState.moveDraftToBottom(task.id) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
            Divider()
            Button { appState.queue(task.id, before: nil) } label: { Label("Queue", systemImage: "list.number") }
            if let schedule {
                Button(action: schedule) { Label("Schedule…", systemImage: "clock") }
            }
            Divider()
        }
        if task.state != .merged {
            if task.state == .drafting {
                Button { appState.plan(task.id) } label: { Label("Send to planning", systemImage: "paperplane") }
            }
            if task.state == .backlog {
                // Picked up again: planned again (or for the first time), or its plan approved and built.
                Button { appState.plan(task.id) } label: { Label(task.plan.isEmpty ? "Send to planning" : "Plan again", systemImage: "paperplane") }
                if !task.plan.isEmpty {
                    Button { appState.approvePlan(task.id) } label: { Label("Approve & build", systemImage: "hammer") }
                }
            }
            if task.state == .drafting || task.state == .awaitingApproval {
                Button { appState.sendToBacklog(task.id) } label: { Label("Send to backlog", systemImage: TaskState.backlog.icon) }
            }
            // Waiting on its plan's approval or in the backlog, nothing is running to retry; request changes instead.
            if task.state != .drafting && task.state != .awaitingApproval && task.state != .backlog {
                Button { appState.retry(task.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
            }
            if task.state != .cancelled && task.state != .closed {
                Button(role: .destructive) { confirmCancel = true } label: { Label("Cancel task…", systemImage: "xmark.circle") }
            }
            Divider()
        }
        if open {
            TaskAssignButtons(task: task)
            TaskMoveGoalMenu(task: task)
            Divider()
            Button { rename = true } label: { Label("Rename…", systemImage: "pencil") }
            Toggle(isOn: Binding(get: { task.shareable }, set: { appState.setShareable(task.id, $0) })) {
                Label("Run on teammates' machines", systemImage: "person.3")
            }
            Divider()
        }
        if let pr = task.pr, !pr.isLocal {
            Button { appState.openPullRequest(task.id) } label: { Label("Open pull request", systemImage: "arrow.up.right.square") }
        }
        if appState.branch(of: task.id) != nil {
            Button { appState.copyBranch(task.id) } label: { Label("Copy branch name", systemImage: "arrow.triangle.branch") }
        }
        Button { appState.copyID(task.id) } label: { Label("Copy ID", systemImage: "number") }
    }
}

/// Take it over (when it isn't yours) and, for its owner or an admin, Assign to ▸ the org's members.
struct TaskAssignButtons: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask

    private var mine: Bool { task.owner.github == FactoryData.me.github }

    var body: some View {
        if !mine, let me = FactoryData.me.github {
            Button { appState.assign(task.id, to: me) } label: { Label("Take it over", systemImage: "person.crop.circle.badge.checkmark") }
        }
        if appState.canReassign(task.id) {
            let choices = Self.choices(for: task)
            Menu {
                ForEach(choices, id: \.person.id) { choice in
                    let person = choice.person
                    // The current owner is checked; picking them again changes nothing.
                    Toggle(person.github == FactoryData.me.github ? "\(person.name) (you)" : person.name, isOn: Binding(
                        get: { choice.current },
                        set: { _ in appState.assign(task.id, to: person.github!) }
                    ))
                }
            } label: {
                Label("Assign to", systemImage: "person.badge.plus")
            }
            .disabled(!choices.contains { !$0.current })
        }
    }

    /// Everyone you can give `task` to: the teammates with a GitHub login, its current owner checked.
    static func choices(for task: FactoryTask) -> [(person: Person, current: Bool)] {
        FactoryData.people.filter { $0.github != nil }.map { ($0, $0.github == task.owner.github) }
    }
}

/// Move to goal ▸ the unarchived goals other than its own; one that doesn't work in its repo is disabled and says why.
struct TaskMoveGoalMenu: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask

    var body: some View {
        let targets = appState.moveTargets(task.id)
        Menu {
            ForEach(targets, id: \.goal.id) { target in
                Button {
                    appState.moveToGoal(task.id, goal: target.goal.name)
                } label: {
                    if let blocked = target.blocked {
                        Text("\(target.goal.name) — \(blocked)")
                    } else {
                        Text(target.goal.name)
                    }
                }
                .disabled(target.blocked != nil)
                .help(target.blocked ?? "Move \(task.id) to \(target.goal.name); it keeps its id")
            }
        } label: {
            Label("Move to goal", systemImage: "folder")
        }
        .disabled(targets.isEmpty)
    }
}

extension View {
    /// Asks before cancelling `task`, saying what cancelling stops.
    func cancelTaskConfirmation(task: FactoryTask, isPresented: Binding<Bool>) -> some View {
        modifier(CancelTaskConfirmation(task: task, isPresented: isPresented))
    }

    /// Asks for `task`'s new title.
    func renameTask(task: FactoryTask, isPresented: Binding<Bool>) -> some View {
        modifier(RenameTask(task: task, isPresented: isPresented))
    }
}

private struct RenameTask: ViewModifier {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var isPresented: Bool
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename \(task.id)", isPresented: $isPresented) {
                TextField("Title", text: $title)
                Button("Rename") { appState.rename(task.id, title: title) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A new title everyone sees on the board and in the sidebar.")
            }
            .onChange(of: isPresented) { if isPresented { title = task.title } }
    }
}

private struct CancelTaskConfirmation: ViewModifier {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Cancel \(task.id)?", isPresented: $isPresented) {
            Button("Cancel Task", role: .destructive) { appState.cancel(task.id) }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(Self.stops(task))
        }
    }

    /// What cancelling ends, in a sentence.
    static func stops(_ task: FactoryTask) -> String {
        var parts: [String] = []
        if let worker = task.worker { parts.append("its running \(worker.role) session") }
        else if task.state == .planning || task.state == .building || task.liveLog != nil { parts.append("its running session") }
        if let pr = task.pr, pr.state == .open || pr.state == .draft { parts.append("its open PR #\(pr.number)") }
        if task.state == .awaitingApproval { parts.append("the pending plan approval") }
        if task.state == .reviewing, task.pr?.state != .merged { parts.append("the pending review") }
        if task.question != nil || task.hand != nil { parts.append("the open question to you") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first
        return (list.map { "This stops \($0). " } ?? "") + "Its branch stays, and you can pick it back up with Retry."
    }
}

struct QuestionBlock: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    let question: String
    @State private var replying = false
    @State private var reply = ""

    private var options: [String] { task.questionOptions }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.State.planning)
                Text("\(task.agent?.name ?? "Agent") is asking")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(question)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let reply = task.comments.last(where: { $0.via != nil }) {
                HStack(alignment: .top, spacing: 8) {
                    AgentAvatar(agent: reply.author, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(reply.author.firstName) replied in \(reply.via ?? "") · \(reply.when) ago")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                        Text(reply.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBG.opacity(0.7)))
            } else if task.intakeID != nil {
                Label("Also posted to the requester's Slack thread", systemImage: "number")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
            if options.allSatisfy({ $0.count <= 32 }) {
                FlowLayout(spacing: 6) {
                    ForEach(options + ["Reply…"], id: \.self) { answer in chip(answer) }
                }
            } else {
                // Long answers read as full-width rows that wrap, like a hand-raise's options.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.self) { answer in optionRow(answer) }
                    chip("Reply…")
                }
            }
            if replying {
                HStack(spacing: 6) {
                    TextField("Your answer", text: $reply)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
                        .onSubmit(sendReply)
                    Text("Send")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.State.planning))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: sendReply)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.State.planning.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.planning.opacity(0.25)))
        )
    }
}

extension QuestionBlock {
    private func chip(_ answer: String) -> some View {
        Text(answer)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule()
                    .fill(Theme.cardBG)
                    .overlay(Capsule().strokeBorder(Theme.stroke))
            )
            .contentShape(Capsule())
            .onTapGesture { pick(answer) }
    }

    private func optionRow(_ answer: String) -> some View {
        Text(answer)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { pick(answer) }
    }

    private func pick(_ answer: String) {
        if answer == "Reply…" { replying = true } else { appState.answer(task.id, text: answer) }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.answer(task.id, text: text)
        reply = ""
        replying = false
    }
}

// MARK: - Decisions

/// Side by side while both labels fit with their padding, stacked when the column is too narrow.
struct DecisionButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(spacing: 8) { content }
        }
    }
}

struct RequestChangesButton: View {
    /// Off while the approval or merge beside it is in flight.
    var enabled = true
    var action: () -> Void

    var body: some View {
        SecondaryButton(title: "Request changes", enabled: enabled, action: action)
    }
}

struct SecondaryButton: View {
    let title: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            )
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .disabled(!enabled)
            .animation(.snappy(duration: 0.2), value: enabled)
    }
}

/// The planner's proposed rename: taken when the plan is approved, unless the approver keeps the current title.
struct SuggestedTitleRow: View {
    let task: FactoryTask
    let suggested: String
    @Binding var keep: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Renames to")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text(suggested)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(keep ? Theme.textFaint : Theme.text)
                        .strikethrough(keep, color: Theme.textFaint)
                    Text(task.title)
                        .font(.system(size: 12))
                        .foregroundStyle(keep ? Theme.text : Theme.textFaint)
                        .strikethrough(!keep, color: Theme.textFaint)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Keep current title", isOn: $keep)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 19)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
        .animation(.snappy(duration: 0.2), value: keep)
    }
}

struct ApprovalBlock: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var onRequestChanges: () -> Void
    @State private var keepTitle = false

    var body: some View {
        let needed = state.risk(for: task)?.approvals ?? task.approvalsNeeded
        let iApproved = task.approvals.contains { $0.id == FactoryData.me.id }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel(title: "Approvals")
                Text("\(task.approvals.count) of \(needed)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                SignOffMeter(done: task.approvals.count, needed: needed)
            }
            ForEach(task.approvals) { person in
                SignOffRow(person: person, text: "approved v\(task.planVersion)")
            }
            if task.approvals.count < needed {
                PendingSignOffRow(text: iApproved ? "Needs one more approver" : "Waiting on you", highlight: !iApproved)
            }
            if !iApproved {
                let approving = state.isInFlight(task.id, .approvePlan)
                if let suggested = task.suggestedTitle {
                    SuggestedTitleRow(task: task, suggested: suggested, keep: $keepTitle)
                }
                DecisionButtons {
                    PrimaryButton(title: "Approve plan", icon: "checkmark", busy: approving, busyTitle: "Approving…") {
                        state.approvePlan(task.id, keepTitle: keepTitle)
                    }
                    RequestChangesButton(enabled: !approving, action: onRequestChanges)
                }
                .padding(.top, 2)
            }
            // Not now: parked, and nothing runs on it until someone picks it up.
            SecondaryButton(title: "Send to backlog", enabled: !state.isInFlight(task.id, .approvePlan)) {
                state.sendToBacklog(task.id)
            }
        }
    }
}

/// A parked task: nothing runs on it until someone approves its plan, asks for changes or plans it.
struct BacklogBlock: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var onRequestChanges: () -> Void
    @State private var keepTitle = false

    var body: some View {
        let planned = !task.plan.isEmpty
        let approving = state.isInFlight(task.id, .approvePlan)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: TaskState.backlog.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.State.backlog)
                VStack(alignment: .leading, spacing: 3) {
                    Text("In the backlog: nothing runs until you pick it up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(planned ? "Plan v\(task.planVersion) is kept. Approve it to build, or ask for changes first."
                                 : "Not planned yet. Edit its brief, then send it to planning.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if planned {
                if let suggested = task.suggestedTitle {
                    SuggestedTitleRow(task: task, suggested: suggested, keep: $keepTitle)
                }
                DecisionButtons {
                    PrimaryButton(title: "Approve & build", icon: "hammer", busy: approving, busyTitle: "Approving…") {
                        state.approvePlan(task.id, keepTitle: keepTitle)
                    }
                    RequestChangesButton(enabled: !approving, action: onRequestChanges)
                }
            }
            SecondaryButton(title: "Send to planning", enabled: !approving) {
                state.plan(task.id)
            }
        }
    }
}

/// Asks what one more automated-review round should look for.
struct RequestReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let taskID: String
    var send: (String) -> Void
    @State private var focus = ""

    var body: some View {
        let empty = focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            Text("Request a review of \(taskID)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("The review agent runs one more round and looks at this first. Approvals already given stay.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("What should it look for? e.g. check security", text: $focus, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !empty { send(focus); dismiss() } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { send(focus); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(empty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Merging is gated on passing proofs, passing required CI, and however many human reviews the
/// task's risk calls for. When the goal's policy allows it, the factory merges on its own.
struct ReviewActions: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var onRequestChanges: () -> Void
    @State private var requestingReview = false

    var body: some View {
        let gate = state.mergeGate(for: task)
        let iReviewed = task.reviews.contains { $0.id == FactoryData.me.id }
        // Mid-countdown it isn't merging yet: the countdown button itself locks when it runs out.
        let factoryMerging = task.merging || state.autoMerging.contains(task.id)

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                gateRow("Proofs", ready: gate.proofsReady, failed: gate.failedProofs > 0,
                        detail: gate.proofsReady ? "All proven" : gate.failedProofs > 0 ? "\(gate.failedProofs) failed" : "\(gate.unproven) pending")
                gateRow("CI", ready: gate.checksReady, failed: gate.failedChecks > 0,
                        detail: gate.checksReady ? "Required checks passing" : gate.failedChecks > 0 ? "\(gate.failedChecks) failing" : "Running")
                if let detail = gate.autoReviewDetail {
                    let verdict = task.autoReview?.current?.verdict
                    gateRow("Auto review", ready: gate.autoReviewReady,
                            failed: verdict == .changesRequested || verdict == .escalated, detail: detail)
                }
                gateRow("Reviews", ready: gate.reviewsReady, failed: false,
                        detail: gate.reviewsNeeded == 0 ? "Not required" : "\(task.reviews.count) of \(gate.reviewsNeeded)")
                mergeRow
            }

            if gate.reviewsNeeded > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(task.reviews) { person in
                        SignOffRow(person: person, text: "approved the changes")
                    }
                    if !gate.reviewsReady {
                        if !gate.autoReviewReady && !iReviewed {
                            PendingSignOffRow(text: "Waiting on the automatic review", highlight: false)
                        } else {
                            PendingSignOffRow(text: iReviewed ? "Needs one more reviewer" : "Waiting on you", highlight: !iReviewed)
                        }
                    }
                }
            }

            if let mergeAt = countdown(gate) {
                CountdownMergeButton(number: task.pr?.number ?? 0, mergeAt: mergeAt, from: task.mergeFrom,
                                     holding: state.isInFlight(task.id, .holdMerge),
                                     hold: { state.holdMerge(task.id) }, mergeNow: { state.merge(task.id) })
            } else if factoryMerging {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Factory is merging #\(task.pr?.number ?? 0)…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.State.merged)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.State.merged.opacity(0.1)))
            } else if let hand = task.hand, hand.reason == .mergeFailed {
                // The merge failed: a person picks how it goes on, so Merge gives way to the hand's options.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: hand.reason.icon).foregroundStyle(hand.reason.color)
                    Text(hand.explanation).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                DecisionButtons {
                    PrimaryButton(title: "Send back to fix", icon: "arrow.uturn.backward") {
                        state.resolveHand(task.id, option: hand.options.first { $0.title == "Send it back to fix" }, note: "")
                    }
                    SecondaryButton(title: "Retry merge") {
                        state.resolveHand(task.id, option: hand.options.first { $0.title == "Try the merge again" }, note: "")
                    }
                    RequestChangesButton(action: onRequestChanges)
                }
            } else {
                let approving = state.isInFlight(task.id, .approveChanges)
                let merging = state.isMerging(task)
                DecisionButtons {
                    if !gate.autoReviewReady && !gate.reviewsReady && !iReviewed {
                        // The server refuses approvals until the reviewer passes the round, so say so instead of failing silently.
                        PrimaryButton(title: "Approve after review", icon: "hourglass", enabled: false) {}
                    } else if !gate.reviewsReady && !iReviewed {
                        PrimaryButton(title: "Approve changes", icon: "checkmark", busy: approving, busyTitle: "Approving…") {
                            state.approveChanges(task.id)
                        }
                    } else {
                        PrimaryButton(title: "Merge", icon: "arrow.triangle.merge", enabled: gate.canMerge,
                                      busy: merging, busyTitle: "Merging #\(task.pr?.number ?? 0)…") {
                            state.merge(task.id)
                        }
                    }
                    RequestChangesButton(enabled: !approving && !merging, action: onRequestChanges)
                }
                // Another automated-review round, with this person's focus, once the last one is in.
                if let round = task.autoReview?.current, round.verdict != .inProgress, !merging,
                   task.hand == nil, task.question == nil {
                    SecondaryButton(title: "Request review…", enabled: !approving) { requestingReview = true }
                        .help("Run the review agent again, looking first at what you ask")
                }
            }

            if let mergeAt = countdown(gate) {
                TimelineView(.everySecond(until: mergeAt)) { context in
                    let left = Int(max(0, mergeAt.timeIntervalSince(context.date)).rounded(.up))
                    statusRow("bolt.fill", left > 0 ? "Auto-merging in \(left)s — Hold to merge it yourself." : "Auto-merging now.", Theme.State.merged)
                }
            } else {
                statusLine(gate)
            }
        }
        .sheet(isPresented: $requestingReview) {
            RequestReviewSheet(taskID: task.id) { focus in state.requestReview(task.id, focus: focus) }
        }
    }

    /// When the factory auto-merges it, while that's counting down and every gate still holds.
    private func countdown(_ gate: MergeGate) -> Date? {
        guard task.state == .reviewing, let mergeAt = task.mergeAt, gate.canMerge, gate.autoMerge,
              task.hand == nil, !task.merging, !state.isInFlight(task.id, .merge) else { return nil }
        return mergeAt
    }

    /// The merge forecast: conflicts with the base (red), overlaps with other work in flight (amber, each
    /// one a link to that task, hovered for its card and the files they share), or merges cleanly (green).
    @ViewBuilder private var mergeRow: some View {
        let forecast = task.mergeForecast ?? MergeForecast()
        let base = forecast.base ?? task.pr?.base ?? "main"
        if !forecast.conflicts.isEmpty {
            let n = forecast.conflicts.count
            let files = n == 1 ? "1 file" : "\(n) files"
            let since = forecast.since.map { " since \($0) merged" } ?? ""
            let fixing = task.state == .building ? " · builder updating" : ""
            gateRow("Merge", ready: false, failed: true, detail: "Conflicts in \(files)\(since)\(fixing)")
                .help(forecast.conflicts.joined(separator: "\n"))
        } else if !forecast.overlaps.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.State.awaitingApproval)
                Text("Merge").foregroundStyle(Theme.text)
                Spacer()
                Text("Overlaps").foregroundStyle(Theme.State.awaitingApproval)
                ForEach(Array(forecast.overlaps.prefix(2).enumerated()), id: \.element) { i, o in
                    Button {
                        state.openReference(o.task)
                    } label: {
                        Text("\(o.task) (\(o.files.count == 1 ? "1 file" : "\(o.files.count) files"))\(i < min(forecast.overlaps.count, 2) - 1 ? "," : "")")
                            .underline()
                            .foregroundStyle(Theme.State.awaitingApproval)
                    }
                    .buttonStyle(.plain)
                    .taskHovercard(o.task, files: o.files)
                }
                if forecast.overlaps.count > 2 {
                    Text("+\(forecast.overlaps.count - 2)").foregroundStyle(Theme.State.awaitingApproval)
                }
            }
            .font(.system(size: 12))
        } else {
            gateRow("Merge", ready: true, failed: false, detail: "Merges cleanly into \(base)")
        }
    }

    private func gateRow(_ label: String, ready: Bool, failed: Bool, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ready ? "checkmark.circle.fill" : failed ? "xmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11.5))
                .foregroundStyle(ready ? Theme.State.merged : failed ? Theme.State.cancelled : Theme.textFaint)
            Text(label).foregroundStyle(Theme.text)
            Spacer()
            Text(detail).foregroundStyle(failed ? Theme.State.cancelled : Theme.textMuted)
        }
        .font(.system(size: 12))
    }

    private func statusLine(_ gate: MergeGate) -> some View {
        let risk = state.risk(for: task)
        let level = risk?.level.title.lowercased() ?? "this"
        let (icon, text, color): (String, String, Color) = {
            if task.hand?.reason == .mergeFailed {
                return ("hand.raised", "Nothing merges it again until someone picks a way forward.", Theme.textMuted)
            }
            if !gate.autoReviewReady {
                switch task.autoReview?.current?.verdict {
                case .changesRequested?:
                    return ("arrow.triangle.2.circlepath", "The reviewer asked for changes; the builder is fixing them. You can approve once it passes.", Theme.textMuted)
                case .escalated?:
                    return ("exclamationmark.triangle", "The reviewer escalated this round. Approval unlocks once the automatic review passes.", Theme.textMuted)
                default:
                    let round = gate.autoReviewRound.map { "round \($0)" } ?? "its first round"
                    return ("hourglass", "The factory's reviewer is on \(round). You can approve once it passes.", Theme.textMuted)
                }
            }
            if !state.policy.autoMerges && gate.canMerge {
                return ("hand.tap", "Ready. Nothing merges on its own in this factory, so a person merges.", Theme.textMuted)
            }
            if let acceptance = risk?.acceptance {
                return ("bolt.shield", "\(acceptance.acceptedBy.firstName) accepted \(level) risk for \(task.goal). The factory merges once proofs and CI pass.", Theme.State.merged)
            }
            if gate.autoMerge {
                return ("bolt.fill", "\(risk?.level.title ?? "Low") risk: auto-merges once proofs and CI pass.", Theme.State.merged)
            }
            if gate.canMerge {
                return ("hand.tap", "Ready. Auto-merge is off for \(level) risk, so a person merges.", Theme.textMuted)
            }
            return ("lock", "Merge unlocks when proofs, CI and reviews are all green.", Theme.textMuted)
        }()
        return statusRow(icon, text, color)
    }

    private func statusRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
    }
}

/// The auto-merge counting down: a green button whose fill drains to empty by `mergeAt`, when the
/// factory merges, with Hold (a person merges it instead) and Merge now beside it. At 0s both give way
/// to a locked "Merging #N…" at once, without waiting for the server to say it's merging.
struct CountdownMergeButton: View {
    let number: Int
    let mergeAt: Date
    /// When the countdown started; unknown, it's taken as the factory's default 10s.
    var from: Date?
    /// Hold was sent and the server hasn't cleared the countdown yet.
    var holding = false
    var hold: () -> Void
    var mergeNow: () -> Void

    var body: some View {
        // Once a second for the number, and at 0s for the lock; Core Animation drains the bar (CountdownDrain),
        // not a redraw every frame.
        TimelineView(.everySecond(until: mergeAt)) { context in
            let left = max(0, mergeAt.timeIntervalSince(context.date))
            if left > 0 {
                counting(left)
            } else {
                PrimaryButton(title: "Merge", icon: "arrow.triangle.merge", busy: true, busyTitle: "Merging #\(number)…") {}
            }
        }
        .transition(.opacity)
    }

    private func counting(_ left: TimeInterval) -> some View {
        VStack(spacing: 8) {
            Group {
                let total = max(mergeAt.timeIntervalSince(from ?? mergeAt.addingTimeInterval(-10)), 0.001)
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold))
                    Text("Merging #\(number) in \(Int(left.rounded(.up)))s")
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background {
                    ZStack {
                        Rectangle().fill(Theme.approve.opacity(0.4))
                        CountdownDrain(mergeAt: mergeAt, total: total, color: Theme.approve)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Merging #\(number) in \(Int(left.rounded(.up))) seconds")
            }
            DecisionButtons {
                SecondaryButton(title: "Hold", enabled: !holding, action: hold)
                SecondaryButton(title: "Merge now", enabled: !holding, action: mergeNow)
            }
        }
    }
}

struct PrimaryButton: View {
    let title: String
    let icon: String
    var enabled = true
    /// Sent and waiting on the factory: a spinner and `busyTitle`, and taps do nothing.
    var busy = false
    var busyTitle: String? = nil
    var color = Theme.approve
    var action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
            }
            Text(busy ? busyTitle ?? title : title)
                .contentTransition(.opacity)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(enabled ? .white : Theme.textFaint)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(enabled ? color.opacity(busy ? 0.7 : 1) : Theme.fill))
        .contentShape(Rectangle())
        .onTapGesture { if enabled && !busy { action() } }
        .disabled(!enabled || busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(busy ? busyTitle ?? title : title)
        .accessibilityAddTraits(.isButton)
        .animation(.snappy(duration: 0.2), value: busy)
    }
}

struct SignOffMeter: View {
    let done: Int
    let needed: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(needed, 1), id: \.self) { index in
                Capsule()
                    .fill(index < done ? Theme.State.merged : Theme.fillSelected)
                    .frame(width: 18, height: 4)
            }
        }
    }
}

struct SignOffRow: View {
    let person: Person
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: person, size: 20)
            Text(person.id == FactoryData.me.id ? "You" : person.firstName).foregroundStyle(Theme.text)
            Text(text).foregroundStyle(Theme.textMuted)
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.State.merged)
        }
        .font(.system(size: 12.5))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct PendingSignOffRow: View {
    let text: String
    var highlight = true

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(Theme.textFaint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 20, height: 20)
            Text(text).foregroundStyle(highlight ? Theme.State.awaitingApproval : Theme.textMuted)
            Spacer()
        }
        .font(.system(size: 12.5, weight: .medium))
    }
}

// MARK: - Conversation

struct DiscussionList: View {
    let comments: [Comment]
    var avatarSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                HStack(alignment: .top, spacing: 10) {
                    AgentAvatar(agent: comment.author, size: avatarSize)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(comment.author.id == FactoryData.me.id ? "You" : comment.author.firstName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            if let anchor = comment.anchor {
                                Text(anchor)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.textMuted)
                                    .padding(.horizontal, 6)
                                    .frame(height: 17)
                                    .background(Capsule().fill(Theme.fill))
                            }
                            Spacer()
                            Text(comment.when)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                        MarkdownPreview(source: comment.text, baseSize: 12.5)
                    }
                }
            }
        }
    }
}

struct ActivityFeed: View {
    let items: [ActivityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    (Text(item.who).foregroundStyle(Theme.text).fontWeight(.medium)
                     + Text("  \(item.text)").foregroundStyle(Theme.textMuted))
                        .font(.system(size: 12.5))
                    Spacer()
                    Text(item.when)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}

// MARK: - Peek

/// Short stand-ins the task panel shows in place of whole sections; the full view has the rest.

/// One line for a section: what it is, how far along, and a tap to open it.
struct PeekRow<Trailing: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
            if let detail {
                Text("· \(detail)")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(hovered ? Theme.fill : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

extension PeekRow where Trailing == EmptyView {
    init(icon: String, title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, detail: detail, action: action) { EmptyView() }
    }
}

/// Peek rows stacked in one bordered box, divided by hairlines.
struct PeekGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 { Hairline().padding(.leading, 36) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.fillSubtle)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        )
    }
}

/// The pull request as one row: number, state and checks, opening it on GitHub (or the full view for a local repo).
struct PullRequestRow: View {
    @Environment(\.openURL) private var openURL
    let pr: PullRequest
    let openFull: () -> Void

    private var checks: String? {
        guard !pr.checks.isEmpty else { return nil }
        let passed = pr.checks.filter { $0.status == .passed }.count
        return "\(passed) of \(pr.checks.count) checks"
    }

    var body: some View {
        PeekRow(icon: "arrow.triangle.pull", title: "#\(pr.number)", detail: checks, action: {
            if pr.isLocal { openFull() } else { openURL(pr.url) }
        }) {
            PRStateChip(state: pr.state)
        }
        .help(pr.isLocal ? "A local repo: open the full view for its branch" : pr.url.absoluteString)
    }
}

/// The latest comments, with how many earlier ones the full view holds.
struct DiscussionPeek: View {
    let comments: [Comment]
    var shown = 2
    let openFull: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(title: "Discussion")
                Spacer()
                if comments.count > shown {
                    Text("\(comments.count - shown) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: openFull)
                        .help("Open full view (⌘↩)")
                }
            }
            DiscussionList(comments: Array(comments.suffix(shown)))
        }
    }
}

// MARK: - Composer

/// One input for both audiences: steer the task's agent, or comment to teammates.
struct TaskComposer: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var mode: ComposerMode
    var focused: FocusState<Bool>.Binding

    @State private var draft = ""
    @State private var interruptNow = false
    @State private var mention = MentionState()
    @State private var taskRef = MentionState()

    // The box is a TextField, so its cursor isn't known: an `@name` or `#ref` at the end is what's being typed.
    private var mentionQuery: MentionQuery? { mention.query(draft, cursor: (draft as NSString).length) }
    private var mentionCandidates: [Person] {
        mentionQuery.map { MentionQuery.matches(FactoryData.people, $0.query) } ?? []
    }
    private var taskQuery: TaskRefQuery? { taskRef.taskQuery(draft, cursor: (draft as NSString).length) }
    private var taskCandidates: [FactoryTask] {
        taskQuery.map { TaskRefQuery.matches(appState.tasks, $0.query) } ?? []
    }

    var body: some View {
        // A merged or cancelled task can't be redirected any more, whatever tab was picked before.
        let steering = mode == .steer && task.isSteerable

        VStack(alignment: .leading, spacing: 12) {
            if task.isSteerable, let agent = task.agent {
                HStack(spacing: 2) {
                    // On a plan waiting for approval, steering means asking for the next version of it.
                    modeTab(task.state == .awaitingApproval || task.state == .backlog ? "Revise plan" : "Steer \(agent.name)", icon: "sparkle", mode: .steer)
                    modeTab("Comment", icon: "bubble.left", mode: .comment)
                    Spacer()
                    if steering, task.state == .building {
                        Menu {
                            Button("At next step") { interruptNow = false }
                            Button("Interrupt now") { interruptNow = true }
                        } label: {
                            Text(interruptNow ? "Interrupt now" : "At next step")
                        }
                        .menuStyle(.borderlessButton)
                        .font(.system(size: 11.5))
                        .fixedSize()
                    }
                }
            }

            if steering {
                HStack(spacing: 6) {
                    ForEach(quickTweaks, id: \.self) { tweak in
                        Text(tweak)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().strokeBorder(Theme.stroke))
                            .contentShape(Capsule())
                            .onTapGesture { draft = tweak; focused.wrappedValue = true }
                    }
                }
            }

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.text)
                .focused(focused)
                .onExitCommand { if !pickerKey(.close) { focused.wrappedValue = false } }
                .onSubmit { if !pickerKey(.pick) { send() } }
                .onKeyPress(keys: [.upArrow, .downArrow, .tab]) { press in
                    pickerKey(press.key == .upArrow ? .up : press.key == .downArrow ? .down : .pick) ? .handled : .ignored
                }
                // Teammates to @mention, just above the box.
                .overlay(alignment: .topLeading) {
                    let candidates = mentionCandidates
                    if !candidates.isEmpty {
                        MentionPicker(people: candidates, highlighted: min(mention.highlighted, candidates.count - 1)) { pickMention($0) }
                            .offset(y: -MentionPicker.height(candidates.count) - 8)
                    }
                }
                // Tasks to reference after a `#`, in the same place.
                .overlay(alignment: .topLeading) {
                    let candidates = taskCandidates
                    if !candidates.isEmpty {
                        TaskRefPicker(tasks: candidates, highlighted: min(taskRef.highlighted, candidates.count - 1)) { pickTask($0) }
                            .offset(y: -TaskRefPicker.height(candidates.count) - 8)
                    }
                }
                .onChange(of: mentionQuery?.range.location) { mention.highlighted = 0 }
                .onChange(of: taskQuery?.range.location) { taskRef.highlighted = 0 }
                .onReceive(NotificationCenter.default.publisher(for: Self.demoType)) { note in
                    mode = .comment
                    draft = note.userInfo?["text"] as? String ?? ""
                    focused.wrappedValue = true
                }
                .onReceive(NotificationCenter.default.publisher(for: MentionKey.demo)) { note in
                    if let key = note.object as? MentionKey { _ = pickerKey(key) }
                }
                .onReceive(NotificationCenter.default.publisher(for: Self.demoSend)) { _ in send() }

            HStack {
                Image(systemName: "paperclip").foregroundStyle(Theme.textMuted)
                if steering {
                    Text(interruptNow && task.state == .building ? "Interrupts after the current edit" : task.steerTiming)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: steering ? "arrow.uturn.backward" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(steering ? .white : Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(steering ? Theme.State.planning : Theme.accent))
                    .onTapGesture(perform: send)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.raised.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(steering && focused.wrappedValue ? Theme.State.planning.opacity(0.6) : Theme.stroke)
                )
        )
        // The view may have been built before the task had an agent: once it can be steered, steer by default
        // so Request changes reaches the agent rather than landing as a comment.
        .onChange(of: task.isSteerable) { _, steerable in
            if steerable { mode = .steer }
        }
    }

    private var placeholder: String {
        guard mode == .steer, task.isSteerable, let agent = task.agent else {
            // Say so up front, so a comment on a plan isn't mistaken for a revision that never comes.
            if task.state == .awaitingApproval || task.state == .backlog, task.isSteerable { return "Comment for teammates; doesn't send the plan back to \(task.agent?.name ?? "the planner")…" }
            return "Comment or @mention someone…"
        }
        switch task.state {
        case .awaitingApproval, .backlog: return "What should \(agent.name) change for plan v\(task.planVersion + 1)?"
        case .building: return "Tell \(agent.name) what to change mid-build…"
        case .reviewing: return "What should \(agent.name) fix before merge?"
        default: return "Tell \(agent.name) what to change in the plan…"
        }
    }

    private var quickTweaks: [String] {
        switch task.state {
        case .building: ["Add a test for this", "Smaller commits", "Explain the last change"]
        case .reviewing: ["Record a longer video", "Re-run the flaky test", "Add a screenshot"]
        default: ["Smaller steps", "Add a done-when check", "What's the riskiest step?"]
        }
    }

    private func modeTab(_ title: String, icon: String, mode tabMode: ComposerMode) -> some View {
        let active = mode == tabMode

        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title)
        }
        .font(.system(size: 12, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? (tabMode == .steer ? Theme.State.planning : Theme.text) : Theme.textMuted)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { mode = tabMode }
    }

    /// `-actions "mention:cc @"` (AppState.play): types into the composer, for recordings.
    static let demoType = Notification.Name("TaskComposer.demoType")
    /// `-actions "post:1"`: sends what's in the composer, as Return would.
    static let demoSend = Notification.Name("TaskComposer.demoSend")

    private func mentionKey(_ key: MentionKey) -> Bool {
        let candidates = mentionCandidates
        guard mention.handle(key, query: mentionQuery, count: candidates.count) else { return false }
        if key == .pick { pickMention(candidates[min(mention.highlighted, candidates.count - 1)]) }
        return true
    }

    private func pickMention(_ person: Person) {
        guard let query = mentionQuery else { return }
        draft = query.inserting(person, into: draft).text
        focused.wrappedValue = true
    }

    /// Whichever picker is open takes the key.
    private func pickerKey(_ key: MentionKey) -> Bool { mentionKey(key) || taskKey(key) }

    private func taskKey(_ key: MentionKey) -> Bool {
        let candidates = taskCandidates
        guard taskRef.handle(key, query: taskQuery, count: candidates.count) else { return false }
        if key == .pick { pickTask(candidates[min(taskRef.highlighted, candidates.count - 1)]) }
        return true
    }

    private func pickTask(_ task: FactoryTask) {
        guard let query = taskQuery else { return }
        draft = query.inserting(task, into: draft).text
        focused.wrappedValue = true
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.snappy(duration: 0.25)) {
            if mode == .steer, task.isSteerable {
                appState.steer(task.id, text: text, interruptNow: interruptNow)
            } else {
                appState.comment(task.id, text: text)
            }
        }
        draft = ""
    }
}
