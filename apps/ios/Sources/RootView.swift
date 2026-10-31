import MapleKit
import SwiftUI

/// Signed in: Inbox, Goals, Machines and Settings. `-tab goals|machines|settings` and `-task <id>`
/// open a screen directly, for screenshots.
struct RootView: View {
    @Environment(FactoryStore.self) private var store

    enum Tab: String { case inbox, goals, machines, settings }

    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .inbox
    @State private var inboxPath = NavigationPath()
    @State private var goalsPath = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $inboxPath) {
                InboxView().withTaskDestinations()
            }
            .tabItem { Label("Inbox", systemImage: "tray.full") }
            .badge(store.feed.inbox(for: store.me).filter { $0.assignee == store.me }.count)
            .tag(Tab.inbox)

            NavigationStack(path: $goalsPath) {
                GoalsView().withTaskDestinations()
            }
            .tabItem { Label("Goals", systemImage: "flag") }
            .tag(Tab.goals)

            NavigationStack { MachinesView().withTaskDestinations() }
                .tabItem { Label("Machines", systemImage: "desktopcomputer") }
                .tag(Tab.machines)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) { NoticeBanner() }
        .onAppear {
            if let id = UserDefaults.standard.string(forKey: "task"), store.feed.task(id) != nil {
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
    }
}

struct TaskRoute: Hashable { let id: String }
struct GoalRoute: Hashable { let id: String }

extension View {
    func withTaskDestinations() -> some View {
        navigationDestination(for: TaskRoute.self) { TaskDetailView(id: $0.id) }
            .navigationDestination(for: GoalRoute.self) { GoalView(id: $0.id) }
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
    @State private var search = ""

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
    }
}

struct GoalRow: View {
    @Environment(FactoryStore.self) private var store
    let goal: Wire.Goal

    var body: some View {
        let tasks = store.feed.tasks(in: goal.id)
        let open = tasks.filter { $0.state != .merged && $0.state != .cancelled }
        NavigationLink(value: GoalRoute(id: goal.id)) {
            HStack(spacing: 12) {
                Text(goal.prefix)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(goalHex: goal.color)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name).font(.body.weight(.medium))
                    Text("\(open.count) open · \(tasks.count - open.count) done").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Avatar(login: goal.lead, url: store.feed.member(goal.lead)?.avatarUrl, size: 22)
            }
        }
    }
}

struct GoalView: View {
    @Environment(FactoryStore.self) private var store
    let id: String

    private static let stages: [Wire.TaskState] = [.awaitingApproval, .planning, .building, .reviewing, .drafting, .backlog, .merged, .cancelled]

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
                ForEach(Self.stages, id: \.self) { stage in
                    let staged = tasks.filter { $0.state == stage }
                    if !staged.isEmpty {
                        Section {
                            ForEach(staged) { task in
                                NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                            }
                        } header: {
                            Label("\(stage.title) · \(staged.count)", systemImage: stage.icon).foregroundStyle(Theme.state(stage))
                        }
                    }
                }
            }
            .navigationTitle(goal.name)
            .refreshable { await store.refresh() }
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
                Spacer()
                Avatar(login: task.owner, url: store.feed.member(task.owner)?.avatarUrl, size: 18)
            }
            Text(task.title).lineLimit(2)
            if let waiting = task.waiting { Text(waiting).font(.caption).foregroundStyle(.secondary) }
        }
    }
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(machine.online ? Theme.approve : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name).font(.body.weight(.medium))
                Text([machine.owner, machine.os, machine.version.map { "runner \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(machine.online ? "Online" : machine.lastSeen.map { "Seen \(When.ago($0)) ago" } ?? "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(machine.online ? Theme.approve : .secondary)
        }
        if store.feed.runnerOutdated(machine), let latest = store.feed.runnerLatest {
            Label("Runner \(latest) is out", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(Theme.warning)
        }
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
            NavigationLink(value: live.session.taskId.map { TaskRoute(id: $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(live.session.taskId ?? live.session.agent).font(.subheadline.monospaced())
                        Text(live.session.agent).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let state = live.activity?.state { Text(state.rawValue).font(.caption).foregroundStyle(state == .waiting ? Theme.warning : .secondary) }
                    }
                    if let message = live.activity?.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .disabled(live.session.taskId == nil)
        }
    }

    private func gauge(_ title: String, _ value: Double) -> some View {
        Gauge(value: min(max(value, 0), 1)) { Text(title) } currentValueLabel: { Text("\(Int(value * 100))%") }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(value > 0.85 ? Theme.danger : Theme.accent)
            .scaleEffect(0.8)
            .frame(maxWidth: .infinity)
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
    }
}
