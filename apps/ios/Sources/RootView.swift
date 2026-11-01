import MapleKit
import SwiftUI

/// Signed in: Inbox, Goals, Machines and Settings. `-tab goals|machines|settings`, `-task <id>` and
/// `-goal <id>` (with `-newTask YES` for its New task sheet) open a screen directly, for screenshots;
/// `-stats YES` (with `-statsDays N`) opens Statistics; `-usage YES` opens Usage.
/// A `maplefactory://` link (FactoryStore.pendingLink) opens its task on the Inbox tab, or a session's
/// terminal on Machines.
struct RootView: View {
    @Environment(FactoryStore.self) private var store

    enum Tab: String { case inbox, goals, machines, settings }

    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .inbox
    @State private var inboxPath = NavigationPath()
    @State private var goalsPath = NavigationPath()
    @State private var machinesPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $inboxPath) {
                InboxView().withTaskDestinations()
            }
            .tabItem { Label("Inbox", systemImage: "tray.full") }
            .badge(store.feed.inbox(for: store.me).filter { $0.assignee == store.me }.count)
            .tag(Tab.inbox)

            NavigationStack(path: $goalsPath) {
                GoalsView { goalsPath.append(GoalRoute(id: $0.id)) }.withTaskDestinations()
            }
            .tabItem { Label("Goals", systemImage: "flag") }
            .tag(Tab.goals)

            NavigationStack(path: $machinesPath) { MachinesView().withTaskDestinations() }
                .tabItem { Label("Machines", systemImage: "desktopcomputer") }
                .tag(Tab.machines)

            NavigationStack(path: $settingsPath) { SettingsView().withTaskDestinations() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) { NoticeBanner() }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "usage") {
                tab = .settings
                settingsPath.append(UsageRoute())
            } else if let id = UserDefaults.standard.string(forKey: "task"), store.feed.task(id) != nil {
                if tab == .goals, let goal = store.feed.task(id)?.goal {
                    goalsPath.append(GoalRoute(id: goal))
                    goalsPath.append(TaskRoute(id: id))
                } else {
                    tab = .inbox
                    inboxPath.append(TaskRoute(id: id))
                }
            } else if tab == .goals, let goal = UserDefaults.standard.string(forKey: "goal") {
                goalsPath.append(GoalRoute(id: goal))
            }
        }
        .onChange(of: store.pendingLink, initial: true) { _, link in
            guard let link else { return }
            store.pendingLink = nil
            switch link {
            case .task(let id):
                // Replaces whatever was pushed, so the task isn't stacked twice. It needn't be in the
                // feed yet: the detail fills in when the snapshot lands.
                tab = .inbox
                inboxPath = NavigationPath([TaskRoute(id: id)])
            case .session(let machine, let id):
                tab = .machines
                machinesPath = NavigationPath([SessionRoute(machine: machine, session: id)])
            }
        }
        // Live, who you are arrives with the snapshot, after the first appearance.
        .onChange(of: store.isAdmin, initial: true) { _, isAdmin in
            guard isAdmin, UserDefaults.standard.bool(forKey: "stats"), settingsPath.isEmpty else { return }
            tab = .settings
            settingsPath.append(StatsRoute())
        }
    }
}

struct TaskRoute: Hashable { let id: String }
struct GoalRoute: Hashable { let id: String }
struct StatsRoute: Hashable {}
struct UsageRoute: Hashable {}
struct SessionRoute: Hashable { let machine: String; let session: String }

extension View {
    func withTaskDestinations() -> some View {
        navigationDestination(for: TaskRoute.self) { TaskDetailView(id: $0.id) }
            .navigationDestination(for: GoalRoute.self) { GoalView(id: $0.id) }
            .navigationDestination(for: SessionRoute.self) { SessionTerminalView(machineID: $0.machine, sessionID: $0.session) }
    }
}

/// The connection's state, under the title while it isn't live.
struct ConnectionBar: View {
    @Environment(FactoryStore.self) private var store

    var body: some View {
        switch store.status {
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right").bar(.secondary)
        case .reconnecting(let attempt, let reason):
            Label("\(reason) Reconnecting (\(attempt))…", systemImage: "wifi.exclamationmark").bar(Theme.warning)
        case .tooNew:
            Label(FactoryAPI.tooNewMessage, systemImage: "arrow.down.app").bar(Theme.danger)
        case .demo:
            Label("Demo factory: sample data, nothing is sent", systemImage: "play.circle").bar(Theme.accent)
        case .live, .signedOut:
            EmptyView()
        }
    }
}

private extension View {
    func bar(_ color: some ShapeStyle) -> some View {
        font(.footnote).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The feed's latest toast or error, for a few seconds.
struct NoticeBanner: View {
    @Environment(FactoryStore.self) private var store

    var body: some View {
        if let notice = store.notice {
            let (text, icon, color): (String, String, Color) = switch notice {
            case .toast(let text, _): (text, "checkmark.circle.fill", Theme.approve)
            case .error(let text): (text, "exclamationmark.triangle.fill", Theme.danger)
            }
            Label(text, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(color.gradient))
                .shadow(radius: 8, y: 4)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { store.notice = nil }
                }
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @Environment(FactoryStore.self) private var store
    @State private var mineOnly = true
    @State private var search = ""

    private var entries: [InboxEntry] {
        store.feed.inbox(for: store.me).filter { entry in
            (!mineOnly || entry.assignee == store.me)
                && (search.isEmpty || matches(entry))
        }
    }

    private func matches(_ entry: InboxEntry) -> Bool {
        let task = store.feed.task(entry.task)
        return [entry.task, entry.message, task?.title ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                ConnectionBar()
                Picker("Scope", selection: $mineOnly) {
                    Text("For you").tag(true)
                    Text("Team").tag(false)
                }
                .pickerStyle(.segmented)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            let all = entries
            if all.isEmpty, store.feed.hasSnapshot {
                ContentUnavailableView("Nothing waiting on you", systemImage: "checkmark.circle",
                                       description: Text(mineOnly ? "Plans, reviews and questions for you land here." : "Nothing is waiting on the team."))
                    .listRowBackground(Color.clear)
            }
            ForEach(InboxEntry.Kind.allCases, id: \.self) { kind in
                let items = all.filter { $0.kind == kind }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { entry in
                            NavigationLink(value: TaskRoute(id: entry.task)) { InboxRow(entry: entry) }
                        }
                    } header: {
                        Label("\(kind.title) · \(items.count)", systemImage: kind.icon).foregroundStyle(kind.color)
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        .searchable(text: $search, prompt: "Tasks, people, messages")
        .refreshable { await store.refresh() }
        .overlay { if !store.feed.hasSnapshot { ProgressView() } }
    }
}

struct InboxRow: View {
    @Environment(FactoryStore.self) private var store
    let entry: InboxEntry

    var body: some View {
        let task = store.feed.task(entry.task)
        let goal = task.flatMap { store.feed.goal($0.goal) }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(Color(goalHex: goal?.color ?? "#8A909A")).frame(width: 7, height: 7)
                Text(entry.task).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(When.ago(entry.at)).font(.caption).foregroundStyle(.tertiary)
            }
            Text(task?.title ?? entry.task).font(.body.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Avatar(login: entry.assignee, url: store.feed.member(entry.assignee)?.avatarUrl, size: 16)
                Text(entry.message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Goals

struct GoalsView: View {
    @Environment(FactoryStore.self) private var store
    /// Opens a goal just made with New goal.
    var openGoal: (Wire.Goal) -> Void = { _ in }
    @State private var search = ""
    @State private var composing = false
    /// `-newGoal YES` opens the New goal sheet, for screenshots.
    @State private var creatingGoal = UserDefaults.standard.bool(forKey: "newGoal")

    var body: some View {
        let goals = store.feed.activeGoals.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.prefix.localizedCaseInsensitiveContains(search) }
        let following = goals.filter { store.feed.following($0) }
        let others = goals.filter { !store.feed.following($0) }
        List {
            Section { ConnectionBar() }.listRowBackground(Color.clear)
            if !following.isEmpty {
                Section("Following") { ForEach(following) { GoalRow(goal: $0) } }
            }
            if !others.isEmpty {
                Section("Other goals") { ForEach(others) { GoalRow(goal: $0) } }
            }
        }
        .navigationTitle("Goals")
        .searchable(text: $search)
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creatingGoal = true } label: { Label("New goal", systemImage: "plus") }
                    .accessibilityIdentifier("newGoal")
            }
            if defaultGoal != nil { ToolbarItem(placement: .primaryAction) { NewTaskButton(composing: $composing) } }
        }
        .sheet(isPresented: $composing) { if let goal = defaultGoal { NewTaskView(goal: goal.id) } }
        .sheet(isPresented: $creatingGoal) { GoalEditorSheet(editing: nil) { openGoal($0) } }
    }

    /// Where a new task from here starts: the first goal you follow, else the first goal.
    private var defaultGoal: Wire.Goal? {
        store.feed.activeGoals.first { store.feed.following($0) } ?? store.feed.activeGoals.first
    }
}

/// Opens the New task sheet.
struct NewTaskButton: View {
    @Binding var composing: Bool

    var body: some View {
        Button { composing = true } label: { Label("New task", systemImage: "square.and.pencil") }
            .accessibilityIdentifier("newTask")
    }
}

struct GoalRow: View {
    @Environment(FactoryStore.self) private var store
    let goal: Wire.Goal

    var body: some View {
        let tasks = store.feed.tasks(in: goal.id)
        let open = tasks.filter { $0.state != .merged && $0.state != .cancelled && $0.state != .closed }
        NavigationLink(value: GoalRoute(id: goal.id)) {
            HStack(spacing: 12) {
                Text(goal.prefix)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(goalHex: goal.color)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name).font(.body.weight(.medium))
                    // Finished tasks the snapshot left out still count as done.
                    Text("\(open.count) open · \(tasks.count - open.count + (store.feed.older[goal.id]?.finished ?? 0)) done").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Avatar(login: goal.lead, url: store.feed.member(goal.lead)?.avatarUrl, size: 22)
            }
        }
    }
}

struct GoalView: View {
    @Environment(FactoryStore.self) private var store
    /// `-newTask YES` opens the New task sheet, for screenshots.
    @State private var composing = UserDefaults.standard.bool(forKey: "newTask")
    /// `-editGoal YES` opens the Edit goal sheet, for screenshots.
    @State private var editingGoal = UserDefaults.standard.bool(forKey: "editGoal")
    let id: String

    private static let stages: [Wire.TaskState] = [.awaitingApproval, .planning, .building, .reviewing, .drafting, .backlog, .merged, .closed, .cancelled]

    /// Edit mode for the Drafts section, where drafts are dragged into order.
    @State private var editMode: EditMode = .inactive
    private var editing: Bool { editMode.isEditing }

    /// The goal's drafts in their order: swipe one to planning or the backlog, or Edit to drag them.
    @ViewBuilder
    private func draftsSection(_ drafts: [Wire.Task]) -> some View {
        if !drafts.isEmpty {
            Section {
                ForEach(drafts) { task in
                    NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                        .swipeActions(edge: .trailing) {
                            if !editing {
                                Button { store.sendToBacklog(task.id) } label: { Label("Backlog", systemImage: Wire.TaskState.backlog.icon) }
                                    .tint(Theme.state(.backlog))
                                planButton(task)
                            }
                        }
                }
                .onMove { from, to in move(drafts, from: from, to: to) }
            } header: {
                HStack {
                    header(.drafting, drafts.count)
                    Spacer()
                    if drafts.count > 1 {
                        Button(editing ? "Done" : "Edit") {
                            withAnimation { editMode = editing ? .inactive : .active }
                        }
                        .font(.subheadline.weight(editing ? .semibold : .regular))
                        .textCase(nil)
                        .accessibilityIdentifier("drafts-edit")
                    }
                }
            }
            .onChange(of: drafts.count > 1) { _, several in if !several { editMode = .inactive } }
        }
    }

    /// Ranks the dragged draft ahead of the one that now follows it ("top" when it lands first).
    private func move(_ drafts: [Wire.Task], from: IndexSet, to: Int) {
        guard let index = from.first else { return }
        var order = drafts
        order.move(fromOffsets: from, toOffset: to)
        let id = drafts[index].id
        guard let at = order.firstIndex(where: { $0.id == id }), order.map(\.id) != drafts.map(\.id) else { return }
        store.rankDraft(id, before: at == 0 ? "top" : order.indices.contains(at + 1) ? order[at + 1].id : nil)
    }

    private func planButton(_ task: Wire.Task) -> some View {
        Button { store.plan(task.id) } label: { Label("Plan", systemImage: Wire.TaskState.planning.icon) }
            .tint(Theme.state(.planning))
    }

    /// Under the finished stages: the snapshot sends tasks finished in the last 14 days; this brings 50 older ones.
    private var loadOlderSection: some View {
        let loading = store.feed.loadingOlder.contains(id)
        let left = store.feed.older[id]?.finished ?? 0
        return Section {
            Button { store.loadOlder(goal: id) } label: {
                HStack {
                    Label("Load older", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    if loading { ProgressView() } else { Text("\(left) more").foregroundStyle(.secondary) }
                }
            }
            .disabled(loading)
            .accessibilityIdentifier("load-older")
        } footer: {
            Text("Finished tasks older than 14 days load when you ask.")
        }
    }

    private func header(_ stage: Wire.TaskState, _ count: Int) -> some View {
        Label("\(stage.title) · \(count)", systemImage: stage.icon).foregroundStyle(Theme.state(stage))
    }

    var body: some View {
        if let goal = store.feed.goal(id) {
            let tasks = store.feed.tasks(in: id)
            List {
                Section {
                    if !goal.summary.isEmpty { Text(goal.summary).foregroundStyle(.secondary) }
                    LabeledContent("Lead") {
                        HStack(spacing: 6) { Avatar(login: goal.lead, size: 18); Text(goal.lead) }
                    }
                    if let repo = goal.repo { LabeledContent("Repo", value: repo) }
                    Toggle("Follow", isOn: Binding(get: { store.feed.following(goal) }, set: { store.follow(goal.id, $0) }))
                }
                GoalSettingsSection(goal: goal)
                ForEach(Self.stages, id: \.self) { stage in
                    let staged = tasks.filter { $0.state == stage }
                    if stage == .drafting {
                        draftsSection(staged.sorted(by: Wire.Task.draftOrder))
                    } else if !staged.isEmpty {
                        Section {
                            ForEach(staged) { task in
                                NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                                    .swipeActions(edge: .trailing) {
                                        if stage == .backlog, !editing { planButton(task) }
                                    }
                            }
                        } header: {
                            header(stage, staged.count)
                        }
                    }
                }
                if store.feed.hasOlder(goal: id) { loadOlderSection }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(goal.name)
            .refreshable { await store.refresh() }
            .toolbar {
                if store.canLead(goal) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editingGoal = true }
                            .accessibilityIdentifier("editGoal")
                    }
                }
                if goal.archived != true { ToolbarItem(placement: .primaryAction) { NewTaskButton(composing: $composing) } }
            }
            .sheet(isPresented: $composing) { NewTaskView(goal: goal.id) }
            .sheet(isPresented: Binding(get: { editingGoal && store.canLead(goal) }, set: { editingGoal = $0 })) { GoalEditorSheet(editing: goal) }
            // `-loadOlder YES` presses Load older once, for screenshots.
            .task { if UserDefaults.standard.bool(forKey: "loadOlder") { store.loadOlder(goal: id) } }
        } else {
            ContentUnavailableView("Goal not found", systemImage: "flag.slash")
        }
    }
}

struct TaskRow: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if task.hand != nil { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning) }
                if task.question != nil { Image(systemName: "questionmark.bubble.fill").font(.caption).foregroundStyle(Theme.state(.planning)) }
                if permission != nil {
                    Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(Theme.state(.awaitingApproval))
                        .accessibilityLabel("Needs permission")
                }
                Spacer()
                Avatar(login: task.owner, url: store.feed.member(task.owner)?.avatarUrl, size: 18)
            }
            Text(task.title).lineLimit(2)
            if let effort = task.effort, !effort.isEmpty {
                Label(effort, systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("task.effort")
            }
            if let permission {
                Text("Needs permission: \(permission.tool)").font(.caption).foregroundStyle(Theme.state(.awaitingApproval))
            } else if let waiting = task.waiting {
                Text(waiting).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The permission prompt its worker is stopped at, if any.
    private var permission: PermissionPrompt? { store.feed.workerActivity(for: task.worker)?.permission }
}

// MARK: - Machines

struct MachinesView: View {
    @Environment(FactoryStore.self) private var store

    var body: some View {
        List {
            Section { ConnectionBar() }.listRowBackground(Color.clear)
            if store.feed.machines.isEmpty, store.feed.hasSnapshot {
                ContentUnavailableView("No machines yet", systemImage: "desktopcomputer",
                                       description: Text("Enroll a Mac from the Mac app's Machines page."))
            }
            ForEach(store.feed.machines.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }) { machine in
                Section { MachineRows(machine: machine) }
            }
        }
        .navigationTitle("Machines")
        .refreshable { await store.refresh() }
    }
}

struct MachineRows: View {
    @Environment(FactoryStore.self) private var store
    let machine: Wire.Machine

    @State private var renaming = false
    @State private var nickname = ""
    @State private var moving: String?

    var body: some View {
        header
            // One dialog for the machine's sessions: Move, from a session's button or swipe.
            .confirmationDialog("Move \(moving ?? "") off \(machine.name)?", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                                titleVisibility: .visible, presenting: moving) { id in
                Button("Move to another machine") { store.moveTask(id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It re-queues first and carries on from its last push.")
            }
        runnerRow
        if let health = machine.health {
            HStack {
                gauge("CPU", health.cpu)
                gauge("Memory", Double(health.memUsed) / Double(max(health.memTotal, 1)))
                gauge("Disk", Double(health.diskUsed) / Double(max(health.diskTotal, 1)))
            }
            if !health.agents.isEmpty {
                HStack {
                    ForEach(health.agents, id: \.name) { agent in
                        Label("\(agent.name) \(agent.version ?? "")", systemImage: agent.loggedIn ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(agent.loggedIn ? Theme.approve : Theme.danger)
                    }
                }
            }
        }
        ForEach(machine.sessions, id: \.session.id) { live in
            let movable = live.session.taskId.flatMap { id in
                FactoryStore.isStuck(machine) && store.canMove(task: id, on: machine) ? id : nil
            }
            NavigationLink(value: SessionRoute(machine: machine.id, session: live.session.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(live.session.taskId ?? live.session.agent).font(.subheadline.monospaced())
                        Text(live.session.agent).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if live.activity?.permission != nil {
                            Label("needs permission", systemImage: "hand.raised.fill").font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.state(.awaitingApproval))
                                .accessibilityIdentifier("session-needs-permission")
                        } else if let state = live.activity?.state {
                            Text(state.rawValue).font(.caption).foregroundStyle(state == .waiting ? Theme.warning : .secondary)
                        }
                    }
                    if let prompt = live.activity?.permission {
                        Text("\(prompt.tool): \(prompt.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if let message = live.activity?.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                if let movable {
                    Button("Move to another machine", systemImage: "arrow.uturn.forward") { moving = movable }.tint(Theme.accent)
                }
            }
            if let movable {
                Button { moving = movable } label: {
                    Label("Move to another machine", systemImage: "arrow.uturn.forward.circle").font(.subheadline)
                }
                .accessibilityIdentifier("move-\(movable)")
            }
        }
    }

    /// Name, owner and runner; long-press to rename it, for its owner or an admin.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(machine.online ? Theme.approve : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name).font(.body.weight(.medium)).accessibilityIdentifier("machine-name-\(machine.id)")
                Text([machine.owner, machine.os, machine.version.map { "runner \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(machine.online ? "Online" : machine.lastSeen.map { "Seen \(When.ago($0)) ago" } ?? "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(machine.online ? Theme.approve : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("machine-\(machine.id)")
        .contextMenu {
            if store.canManage(machine) {
                Button("Rename…", systemImage: "pencil") {
                    nickname = machine.name
                    renaming = true
                }
            }
        }
        .alert("Rename \(machine.name)", isPresented: $renaming) {
            TextField(machine.id, text: $nickname).accessibilityIdentifier("rename-field")
            Button("Rename") { store.renameMachine(machine, name: nickname) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A nickname everyone sees in place of \(machine.id). Leave it empty to go back to that.")
        }
    }

    /// A newer runner, with Update for its owner or an admin, and the update while it runs.
    @ViewBuilder private var runnerRow: some View {
        switch RunnerPhase(machine, outdated: store.feed.runnerOutdated(machine) ? store.feed.runnerLatest : nil) {
        case .current:
            EmptyView()
        case .outdated(let latest):
            HStack {
                Label("Runner \(latest) is out", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(Theme.warning)
                Spacer()
                if store.canManage(machine) {
                    if !machine.online { Text("Offline").font(.caption2).foregroundStyle(.secondary) }
                    Button("Update") { store.updateRunner(machine) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!machine.online)
                        .accessibilityIdentifier("update-runner-\(machine.id)")
                }
            }
        case .busy(let target):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(target.map { "Updating to runner \($0)…" } ?? "Updating the runner…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("runner-updating-\(machine.id)")
        case .updated(let version):
            Label("Updated to runner \(version)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.approve)
                .accessibilityIdentifier("runner-updated-\(machine.id)")
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Couldn't update the runner", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger)
                    if let message { Text(message).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                if store.canManage(machine) {
                    Button("Retry") { store.updateRunner(machine) }.buttonStyle(.bordered).controlSize(.small).disabled(!machine.online)
                }
            }
        }
    }

    private func gauge(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Gauge(value: min(max(value, 0), 1)) { Text(title) } currentValueLabel: { Text("\(Int(value * 100))%") }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(value > 0.85 ? Theme.danger : Theme.accent)
                .scaleEffect(0.8)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Where a machine's runner update is, from `machine.update`: the same reading as the Mac's
/// FactoryClient.updatePhase, kept here so the Mac and MapleKit don't change.
enum RunnerPhase: Equatable {
    case current
    case outdated(String)
    /// Checking, installing or restarting, toward this version when known.
    case busy(String?)
    case updated(String)
    case failed(String?)

    /// `outdated`: the newer release, when the machine is behind it.
    init(_ machine: Wire.Machine, outdated latest: String?) {
        let behind: RunnerPhase = latest.map { .outdated($0) } ?? .current
        guard let update = machine.update else { self = behind; return }
        switch update.state {
        case .checking, .installing, .restarting: self = .busy(update.target ?? latest)
        // Offline after "updated" is the machine gone, not the update.
        case .updated: self = machine.online ? .updated(update.target ?? machine.version ?? "") : behind
        case .failed: self = .failed(update.message)
        case .upToDate, .other: self = behind
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(FactoryStore.self) private var store

    var body: some View {
        Form {
            Section("Factory") {
                LabeledContent("Name", value: store.factoryName)
                if let server = store.server { LabeledContent("Address", value: server.host() ?? server.absoluteString) }
                if let version = store.feed.serverVersion { LabeledContent("Server", value: version) }
                LabeledContent("Members", value: "\(store.feed.members.count)")
                NavigationLink(value: UsageRoute()) { Label("Usage", systemImage: "gauge.with.dots.needle.33percent") }
                if store.isAdmin {
                    NavigationLink(value: StatsRoute()) { Label("Statistics", systemImage: "chart.bar") }
                }
            }
            if let me = store.feed.me {
                Section("Account") {
                    HStack(spacing: 12) {
                        Avatar(login: me.login, url: me.avatarUrl, size: 40)
                        VStack(alignment: .leading) {
                            Text(me.name ?? me.login).font(.headline)
                            Text("@\(me.login) · \(me.role)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if store.saved.count > 1 {
                Section("Switch factory") {
                    ForEach(store.saved.filter { $0.server != store.server }) { factory in
                        Button { store.switchTo(factory) } label: {
                            LabeledContent(factory.name, value: factory.host)
                        }
                    }
                }
            }
            Section {
                if store.status == .demo {
                    Button("Leave the demo") { store.close() }
                } else {
                    Button("Sign out", role: .destructive) { store.signOut() }
                }
            }
            Section {
                LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(for: StatsRoute.self) { _ in StatisticsView() }
        .navigationDestination(for: UsageRoute.self) { _ in UsageView() }
    }
}
