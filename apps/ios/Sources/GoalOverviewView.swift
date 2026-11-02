import MapleKit
import SwiftUI

/// A goal's page: an Overview like the Mac's, sorted by what you should do next (MF-324). What's
/// waiting on you, what's up next, what's moving, and what landed lately; every task, Backlog and older
/// ones included, is under All tasks. Auto-merge, archiving, Edit goal and Scheduled (recurring and one-off tasks) sit behind the … menu.
struct GoalView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// `-newTask YES` opens the New task sheet, for screenshots.
    @State private var composing = UserDefaults.standard.bool(forKey: "newTask")
    /// `-editGoal YES` opens the Edit goal sheet, for screenshots.
    @State private var editingGoal = UserDefaults.standard.bool(forKey: "editGoal")
    /// `-recurring YES` opens the goal's recurring and scheduled tasks, for screenshots.
    @State private var showRecurring = UserDefaults.standard.bool(forKey: "recurring")
    /// `-goalSettings YES` opens Goal settings, for screenshots.
    @State private var showSettings = UserDefaults.standard.bool(forKey: "goalSettings")
    /// `-allTasks YES` opens All tasks, for screenshots.
    @State private var showAll = UserDefaults.standard.bool(forKey: "allTasks") || UserDefaults.standard.bool(forKey: "loadOlder")
    @State private var editMode: EditMode = .inactive
    @AppStorage("goalOverview.landedOpen") private var landedOpen = false
    /// Each section's fold, kept across launches and shared by every goal (MF-340).
    @AppStorage("goalOverview.needsYouOpen") private var needsYouOpen = true
    @AppStorage("goalOverview.upNextOpen") private var upNextOpen = true
    @AppStorage("goalOverview.draftsOpen") private var draftsOpen = true
    @AppStorage("goalOverview.inMotionOpen") private var inMotionOpen = true
    let id: String

    var body: some View {
        if let goal = store.feed.goal(id) {
            let overview = store.feed.overview(goal: id)
            List {
                header(goal)
                needsYou(overview.needsYou)
                upNext(overview)
                inMotion(overview.inMotion)
                landed(overview.recentlyLanded)
                Section {
                    NavigationLink(value: GoalAllTasksRoute(goal: id)) {
                        LabeledContent("All tasks", value: "\(allCount)")
                    }
                    .accessibilityIdentifier("goal-all-tasks")
                } footer: {
                    Text("Every task by stage, with Backlog and older finished work.")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(goal.name)
            .refreshable { await store.refresh() }
            .toolbar {
                if goal.archived != true { ToolbarItem(placement: .primaryAction) { NewTaskButton(composing: $composing) } }
                ToolbarItem(placement: .primaryAction) { menu(goal) }
            }
            .sheet(isPresented: $composing) { NewTaskView(goal: goal.id) }
            .sheet(isPresented: Binding(get: { editingGoal && store.canLead(goal) }, set: { editingGoal = $0 })) { GoalEditorSheet(editing: goal) }
            .navigationDestination(for: GoalAllTasksRoute.self) { GoalAllTasksView(id: $0.goal) }
            .navigationDestination(isPresented: $showRecurring) { RecurringView(goalID: id) }
            .navigationDestination(isPresented: $showSettings) { GoalSettingsView(id: id, onArchive: archived) }
            .navigationDestination(isPresented: $showAll) { GoalAllTasksView(id: id) }
        } else {
            ContentUnavailableView("Goal not found", systemImage: "flag.slash")
        }
    }

    /// Back to Goals once it's archived: off Goal settings, then off the goal.
    private func archived() {
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { dismiss() }
    }

    /// Its tasks, finished ones the snapshot left out included.
    private var allCount: Int { store.feed.tasks(in: id).count + (store.feed.older[id]?.finished ?? 0) }

    private func menu(_ goal: Wire.Goal) -> some View {
        Menu {
            if store.canLead(goal) {
                Button { editingGoal = true } label: { Label("Edit goal", systemImage: "pencil") }
                    .accessibilityIdentifier("editGoal")
            }
            Button { showRecurring = true } label: {
                Label("Scheduled (\(store.recurring(goal: id).count))", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("goal-recurring")
            Button { showSettings = true } label: { Label("Goal settings", systemImage: "gearshape") }
                .accessibilityIdentifier("goal-settings")
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("goal-menu")
    }

    // MARK: Header

    private func header(_ goal: Wire.Goal) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(goal.prefix)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(goalHex: goal.color)))
                    if goal.archived == true {
                        Text("Archived").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    followPill(goal)
                }
                if !goal.summary.isEmpty {
                    Text(goal.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Avatar(login: goal.lead, url: store.feed.member(goal.lead)?.avatarUrl, size: 18)
                    Text(goal.lead)
                    if let repo = goal.repo {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.caption2)
                        Text(repo).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func followPill(_ goal: Wire.Goal) -> some View {
        let following = store.feed.following(goal)
        return Button { store.follow(goal.id, !following) } label: {
            Label(following ? "Following" : "Follow", systemImage: following ? "bell.fill" : "bell")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(following ? Theme.accent : .secondary)
                .background(Capsule().fill(following ? Theme.accent.opacity(0.15) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goal-follow")
    }

    // MARK: Sections

    private func needsYou(_ waiting: [GoalOverview.Waiting]) -> some View {
        Section {
            if needsYouOpen {
                if waiting.isEmpty {
                    Label("Nothing waiting on you", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("needs-you-empty")
                }
                ForEach(waiting) { item in
                    NavigationLink(value: TaskRoute(id: item.task.id)) { NeedsYouCard(item: item) }
                        .accessibilityIdentifier("needs-you-\(item.task.id)")
                }
            }
        } header: {
            CollapsibleHeader(title: "Needs you", count: waiting.count, icon: "person.crop.circle.badge.exclamationmark", tint: Theme.warning, open: $needsYouOpen, id: "section-needs-you")
        }
    }

    @ViewBuilder
    private func upNext(_ o: GoalOverview) -> some View {
        if !o.queued.isEmpty || !o.planning.isEmpty {
            Section {
                if upNextOpen {
                    ForEach(Array(o.queued.enumerated()), id: \.element.id) { index, task in
                        NavigationLink(value: TaskRoute(id: task.id)) {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.secondary.opacity(0.15)))
                                TaskRow(task: task)
                            }
                        }
                    }
                    ForEach(o.planning) { task in
                        NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                    }
                }
            } header: {
                CollapsibleHeader(title: "Up next", count: o.upNextCount, icon: "list.number", tint: Theme.accent, open: $upNextOpen, id: "section-up-next")
            } footer: {
                Text([o.queued.isEmpty ? nil : "\(o.queued.count) queued", o.planning.isEmpty ? nil : "\(o.planning.count) planning"].compactMap { $0 }.joined(separator: " · "))
            }
        }
        DraftsSection(drafts: o.drafts, editMode: $editMode, open: $draftsOpen) { count in
            SectionTitle(title: o.queued.isEmpty && o.planning.isEmpty ? "Up next · Drafts" : "Drafts", count: count, icon: Wire.TaskState.drafting.icon, tint: Theme.state(.drafting))
        }
    }

    @ViewBuilder
    private func inMotion(_ tasks: [Wire.Task]) -> some View {
        if !tasks.isEmpty {
            Section {
                if inMotionOpen {
                    ForEach(tasks) { task in
                        NavigationLink(value: TaskRoute(id: task.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                TaskRow(task: task)
                                if let steps = GoalOverview.steps(task) {
                                    HStack(spacing: 8) {
                                        ProgressView(value: Double(steps.done), total: Double(max(steps.total, 1)))
                                            .tint(Theme.state(task.state))
                                        Text("\(steps.done) of \(steps.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                CollapsibleHeader(title: "In motion", count: tasks.count, icon: "bolt.fill", tint: Theme.state(.building), open: $inMotionOpen, id: "section-in-motion")
            }
        }
    }

    @ViewBuilder
    private func landed(_ tasks: [Wire.Task]) -> some View {
        if !tasks.isEmpty {
            Section {
                if landedOpen {
                    ForEach(tasks) { task in
                        NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                    }
                }
            } header: {
                CollapsibleHeader(title: "Recently landed", count: tasks.count, icon: Wire.TaskState.merged.icon, tint: Theme.state(.merged), open: $landedOpen, id: "recently-landed")
            }
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int
    let icon: String
    let tint: Color

    var body: some View {
        Label("\(title) · \(count)", systemImage: icon).foregroundStyle(tint)
    }
}

/// A section title that folds its section: the title and count stay, a chevron turns 90° when open.
private struct CollapsibleHeader: View {
    let title: String
    let count: Int
    let icon: String
    let tint: Color
    @Binding var open: Bool
    let id: String

    var body: some View {
        Button { withAnimation { open.toggle() } } label: {
            HStack {
                SectionTitle(title: title, count: count, icon: icon, tint: tint)
                Spacer()
                FoldChevron(open: open)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

/// One thing waiting on you: why, and the action it wants.
private struct NeedsYouCard: View {
    @Environment(FactoryStore.self) private var store
    let item: GoalOverview.Waiting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.reason.icon).foregroundStyle(tint)
                Text(item.task.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Avatar(login: item.task.owner, url: store.feed.member(item.task.owner)?.avatarUrl, size: 18)
            }
            Text(item.task.title).font(.body.weight(.medium)).lineLimit(2)
            if !item.why.isEmpty {
                Text(item.why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(item.reason.action)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(tint))
                .accessibilityIdentifier("needs-you-action-\(item.task.id)")
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch item.reason {
        case .hand: Theme.warning
        case .question: Theme.state(.planning)
        case .approval: Theme.state(.awaitingApproval)
        case .review: Theme.state(.reviewing)
        }
    }
}
