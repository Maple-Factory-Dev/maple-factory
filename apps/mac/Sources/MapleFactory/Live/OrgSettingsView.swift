import SwiftUI
import UniformTypeIdentifiers

/// The factory's settings (⌘,): what the org shares, what's yours, and this Mac's runner.
struct OrgSettingsView: View {
    @Environment(FactoryClient.self) private var client
    @AppStorage("settingsTab") private var tab = "repos"

    enum Pane: String, CaseIterable {
        case general, account, appearance, repos, secrets, people, prompts, merging, runner, notifications, updates

        var title: String {
            switch self {
            case .general: "General"
            case .account: "Account"
            case .appearance: "Appearance"
            case .repos: "Repositories"
            case .secrets: "Secrets"
            case .people: "People"
            case .prompts: "Prompts"
            case .merging: "Merging"
            case .runner: "Runner"
            case .notifications: "Notifications"
            case .updates: "Updates"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .account: "person.crop.circle"
            case .appearance: "paintpalette"
            case .repos: "shippingbox"
            case .secrets: "key"
            case .people: "person.2"
            case .prompts: "text.bubble"
            case .merging: "arrow.triangle.merge"
            case .runner: "laptopcomputer"
            case .notifications: "bell"
            case .updates: "arrow.down.circle"
            }
        }
    }

    private var pane: Binding<Pane?> {
        Binding(get: { Pane(rawValue: tab) ?? .repos }, set: { tab = ($0 ?? .repos).rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: pane) {
                row(.general)
                Section("Factory") {
                    ForEach([Pane.account, .appearance, .repos, .secrets, .people, .prompts, .merging], id: \.self) { row($0) }
                }
                Section("This Mac") { row(.runner); row(.notifications); row(.updates) }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                // Repositories, Secrets and People are lists, which scroll themselves.
                switch Pane(rawValue: tab) ?? .repos {
                case .general: ScrollView { GeneralSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .account: ScrollView { AccountSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .appearance: ScrollView { AppearanceSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .repos: RepositoriesSettings()
                case .secrets: SecretsSettings()
                case .people: PeopleSettings()
                case .prompts: ScrollView { PromptSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .merging: ScrollView { MergingSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .runner: ScrollView { RunnerSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .notifications: ScrollView { NotificationSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .updates: ScrollView { UpdateSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle((Pane(rawValue: tab) ?? .repos).title)
        .frame(width: 780, height: 560)
    }

    private func row(_ pane: Pane) -> some View {
        HStack {
            Label(pane.title, systemImage: pane.icon)
            Spacer()
            if pane == .runner, let machine = client.thisMac {
                Circle().fill(machine.online ? Theme.State.merged : Theme.textFaint).frame(width: 6, height: 6)
            }
        }
        .tag(pane)
    }
}

/// How the app behaves on this Mac: what clicking a task opens, and what the Dock shows.
struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @AppStorage(DockIcon.settingKey) private var dockShowsFactoryIcon = true

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "General", detail: "How Maple Factory behaves on this Mac.")
            SettingsCard {
                Picker("When you click a task", selection: $state.taskOpening) {
                    ForEach(AppState.TaskOpening.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("The task panel button in the toolbar (⌥⌘I) appears only with Peek in the side panel.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            SettingsCard {
                Toggle("Show the factory's icon in the Dock", isOn: $dockShowsFactoryIcon)
                Text("When the factory you're in has an icon (Settings › Appearance), the Dock shows it; switching factories changes it. Off, or for a factory without one, the Dock shows Maple's.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13))
        .padding(20)
    }
}

/// Which factory this app is signed in to, and as whom.
struct AccountSettings: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Account", detail: "The factory this app is connected to. Switch or add factories from the factory menu at the top of the sidebar.")
            if let me = client.me, let server = client.server {
                SettingsCard {
                    HStack(spacing: 12) {
                        AgentAvatar(agent: LiveAdapter.person(me.login, members: client.members), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.name ?? me.login).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("@\(me.login) · \(me.role.capitalized)").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    Divider()
                    LabeledContent("Factory", value: client.workspaceName)
                    LabeledContent("Address", value: server.absoluteString)
                    LabeledContent("Status", value: client.status == .live ? "Connected" : client.status == .tooNew ? "Update needed" : "Reconnecting…")
                    if let version = client.serverVersion { LabeledContent("Server", value: "maple-server \(version)") }
                }
                if let update = client.serverUpdate {
                    SettingsCard {
                        Label("maple-server \(update.version) is out", systemImage: "arrow.down.circle")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.State.awaitingApproval)
                        Text(LocalizedStringKey(update.how)).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                }
                Button("Sign Out of \(client.workspaceName)", role: .destructive) { state.signOut() }
            } else {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Add a factory from the factory menu at the top of the sidebar."))
            }
        }
        .font(.system(size: 13))
        .padding(20)
    }
}

/// The factory's name and icon, for everyone in it: the sidebar, the factory menu and the Dock. Admins
/// change them; everyone else sees them with the lock note.
struct AppearanceSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var busy = false
    @State private var problem: String?
    @State private var targeted = false

    private var isAdmin: Bool { client.isAdmin }
    /// A demo script's `icon:<file>` (or `icon:remove`), as Choose Image… or Remove would.
    static let demoPick = Notification.Name("AppearanceSettings.demoPick")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Appearance", detail: "The factory's name and icon, for everyone in it: at the top of the sidebar, in the factory menu, and (the icon) in the Dock on each Mac that shows it (Settings › General).")
            if !client.isSignedIn {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Connect to a factory to see its name and icon."))
            } else {
                FactoryNameCard()
                SettingsCard {
                    HStack(alignment: .center, spacing: 28) {
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                FactoryIcon(name: client.workspaceName, image: client.icon, size: 22)
                                Text(client.workspaceName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(width: 200, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke)))
                            Text("Sidebar").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        VStack(spacing: 8) {
                            Image(nsImage: client.icon.map(MapleIcon.dockImage) ?? MapleIcon.dockImage)
                                .resizable()
                                .frame(width: 72, height: 72)
                            Text("Dock").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(targeted ? Theme.accent : Theme.stroke, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: isAdmin ? [5, 4] : []))
                    )
                    .overlay { if busy { ProgressView().controlSize(.small) } }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard isAdmin, let url = urls.first else { return false }
                        upload(url)
                        return true
                    } isTargeted: { targeted = isAdmin && $0 }
                    Text(isAdmin
                         ? "Choose an image or drop one on the preview. A square image of at least 512 × 512 px looks best: PNG, JPEG or WebP, up to 2 MB."
                         : "A square image of at least 512 × 512 px looks best: PNG, JPEG or WebP, up to 2 MB.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !isAdmin {
                        Label("Only admins can change this.", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.State.cancelled)
                    }
                    Spacer()
                    if isAdmin {
                        Button("Remove", role: .destructive) { remove() }.disabled(busy || client.iconLink == nil)
                        Button("Choose Image…") { choose() }.disabled(busy)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPick)) { note in
            guard isAdmin, let path = note.object as? String else { return }
            if path == "remove" { remove() } else { upload(URL(fileURLWithPath: path)) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the factory's icon: a square image of at least 512 × 512 px."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        upload(url)
    }

    private func upload(_ url: URL) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try Data(contentsOf: url)
                guard NSImage(data: data) != nil else { throw FactoryClient.ClientError.message("That isn't an image.") }
                try await client.upload(iconData: data)
            } catch {
                problem = FactoryClient.describe(error)
            }
        }
    }

    private func remove() {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await client.removeIcon() } catch { problem = FactoryClient.describe(error) }
        }
    }
}

/// The factory's name: what an admin calls it in place of the GitHub org. Blank, or Use Org Name, goes back to the org's.
struct FactoryNameCard: View {
    @Environment(FactoryClient.self) private var client
    @State private var draft = ""
    @State private var busy = false
    @State private var problem: String?

    private var isAdmin: Bool { client.isAdmin }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unchanged: Bool { trimmed == (client.displayName ?? "") }
    /// A demo script's `name:<text>` (typed in, then Save) or `name:clear` (Use Org Name).
    static let demo = Notification.Name("FactoryNameCard.demo")

    var body: some View {
        SettingsCard {
            LabeledContent("Name") {
                TextField(client.orgName, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isAdmin || busy)
                    .onSubmit(save)
            }
            Text(trimmed.count > FactoryClient.maxName
                 ? "The name can be up to \(FactoryClient.maxName) characters."
                 : "Shown instead of \(client.orgName). Leave it blank to use the org's name.")
                .font(.system(size: 12))
                .foregroundStyle(trimmed.count > FactoryClient.maxName ? Theme.State.cancelled : Theme.textMuted)
        }
        HStack {
            if !isAdmin {
                Label("Only admins can change this.", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.State.cancelled)
            }
            Spacer()
            if isAdmin {
                Button("Use Org Name") { clear() }.disabled(busy || client.displayName == nil)
                Button("Save") { save() }.disabled(busy || unchanged || trimmed.count > FactoryClient.maxName)
            }
        }
        .onAppear { draft = client.displayName ?? "" }
        // Someone else renamed it (name.updated): show theirs.
        .onChange(of: client.displayName) { _, name in draft = name ?? "" }
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            guard isAdmin, let text = note.object as? String else { return }
            if text == "clear" { return clear() }
            Task {
                draft = ""
                for character in text {
                    draft.append(character)
                    try? await Task.sleep(for: .milliseconds(45))
                }
                save()
            }
        }
    }

    private func save() {
        guard isAdmin, !unchanged, trimmed.count <= FactoryClient.maxName else { return }
        run { try await client.setName(trimmed) }
    }

    private func clear() {
        draft = ""
        run { try await client.clearName() }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { problem = FactoryClient.describe(error) }
        }
    }
}

/// This Mac's banners for tasks that need you.
struct NotificationSettings: View {
    @Bindable private var notifier = Notifier.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Notifications", detail: "A banner when a task newly needs you (a raised hand, a question, a plan to approve or a PR to review) while Maple Factory is in the background. Snooze them from the bell in the sidebar.")
            SettingsCard {
                Toggle("Notifications", isOn: $notifier.enabled)
                LabeledContent("Status", value: notifier.statusText)
                if notifier.isSnoozed {
                    Button("Resume Notifications") { notifier.resume() }
                }
                if notifier.denied {
                    Divider()
                    Text("macOS isn't letting Maple Factory show notifications.")
                        .font(.system(size: 12)).foregroundStyle(Theme.State.awaitingApproval)
                    Button("Open System Settings") { notifier.openSystemSettings() }
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .task { await notifier.refreshPermission() }
    }
}

/// The app's own updates: which releases it takes, and checking now.
struct UpdateSettings: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Updates", detail: "Maple Factory updates itself from maplefactory.dev. Runners and the factory's server update on their own.")
            SettingsCard {
                LabeledContent("Version", value: updater.version)
                if updater.available {
                    Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                    Picker("Channel", selection: $updater.channel) {
                        ForEach(Updater.Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if updater.channel == .beta {
                        Text("Beta gets prereleases as well as releases. Going back to Stable keeps the beta you have until a release passes it.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    HStack {
                        Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                        Spacer()
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                } else {
                    Text("This build doesn't update itself (it isn't a release build).")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
    }

    private var status: String {
        switch updater.result {
        case .some(.some(let version)): return "\(version) is available"
        case .some(.none): return "Up to date"
        case .none: return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        }
    }
}

/// This Mac's runner: whether it's in the factory, its version, and how much work it takes.
struct RunnerSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding: String?
    @State private var error: String?
    @State private var nickname = ""
    @State private var showingChanges = false

    /// Available but not asked for: the header says so, without a row of its own.
    private static func outdatedOnly(_ phase: RunnerUpdatePhase) -> Bool {
        if case .outdated = phase { true } else { false }
    }

    private func rename(_ machine: Wire.Machine) {
        client.send(.machineRename(.init(machine: machine.id, name: nickname)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Runner", detail: "This Mac runs factory sessions in the background, starting at login. These settings are the same ones as on Machines.")
            if !client.isSignedIn {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Connect to a factory first."))
            } else if let machine = client.thisMac {
                SettingsCard {
                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer").font(.system(size: 18)).foregroundStyle(Theme.textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.name).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                            HStack(spacing: 5) {
                                Circle().fill(machine.online ? Theme.State.merged : Theme.textFaint).frame(width: 6, height: 6)
                                Text(machine.online ? "Online" : "Offline")
                                if let version = machine.version { Text("· runner \(version)") }
                                Text("·")
                                Button("What's New") { showingChanges = true }
                                    .buttonStyle(.link)
                                    .disabled(client.runnerReleases.isEmpty)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        let action = client.runnerAction(machine)
                        Button(action == .check ? "Check for Update" : "Update") {
                            client.perform(action, on: machine)
                        }
                        .disabled((action != .check && !machine.online) || client.updatePhase(machine).isBusy)
                        Button("Show Log") {
                            NSWorkspace.shared.open(LocalRunner.logFile)
                        }
                    }
                    // Its progress and how it ended; Settings has its own Update and Show Log beside it.
                    if case let phase = client.updatePhase(machine), phase != .current, !Self.outdatedOnly(phase) {
                        RunnerUpdateRow(machine: machine, canUpdate: false) { showingChanges = true }
                    } else if client.runnerOutdated(machine), let latest = client.runnerLatest {
                        Text("Runner \(latest) is available.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.State.awaitingApproval)
                    }
                }
                .runnerChanges(machine, isPresented: $showingChanges)
                SettingsCard {
                    HStack {
                        Text("Name")
                        TextField(machine.id, text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { rename(machine) }
                        Button("Rename") { rename(machine) }
                            .disabled(nickname.trimmingCharacters(in: .whitespaces) == machine.name)
                    }
                    Text("What everyone sees for this Mac on Machines, tasks and the sidebar. Leave it empty to use \(machine.id).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .onAppear { nickname = machine.name == machine.id ? "" : machine.name }
                MachineSettingsSheet(machine: machine, embedded: true)
                    .id(machine.id)
            } else if LocalRunner.enrolled != nil {
                SettingsCard {
                    Text("This Mac is enrolled with another factory (\(LocalRunner.enrolled?.url ?? "")), or it was removed from this one.")
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsCard {
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer").font(.system(size: 18)).foregroundStyle(Theme.textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This Mac isn't a factory machine").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(adding ?? "Add it to run agents here, starting at login. No Homebrew needed.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button("Add This Mac", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(adding != nil || LocalRunner.helpers == nil)
                    }
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.State.cancelled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
    }

    private func add() {
        guard let server = client.server else { return }
        adding = "Getting a code…"
        error = nil
        Task {
            do {
                let code = try await client.enrollment().code
                try await LocalRunner.addThisMac(server: server, code: code) { adding = "\($0)…" }
                adding = "Added. It shows up here in a moment."
            } catch {
                adding = nil
                self.error = FactoryClient.describe(error)
            }
        }
    }
}

/// Who's an admin of this factory: GitHub's org owners, and anyone an admin made one here. Admins make
/// and remove the factory's own; GitHub owners stay admins until GitHub says otherwise.
struct FactoryAdminsCard: View {
    @Environment(FactoryClient.self) private var client
    /// A demo script's `admin:grant:<login>` (or `admin:revoke:<login>`), as that row's button would.
    static let demo = Notification.Name("FactoryAdminsCard.demo")

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Factory admins").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Admins change the factory's settings, secrets and prompts. Owners of the GitHub organization always are; an admin can make anyone else who has signed in one too.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(client.members.enumerated()), id: \.element.login) { index, member in
                    if index > 0 { Hairline() }
                    row(member)
                }
            }
            if !client.isAdmin {
                Label("Only admins can change who's an admin.", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            guard client.isAdmin, let login = note.userInfo?["login"] as? String else { return }
            if note.userInfo?["action"] as? String == "revoke" { client.revokeAdmin(login) } else { client.grantAdmin(login) }
        }
    }

    private func row(_ member: Wire.Member) -> some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: LiveAdapter.person(member.login, members: client.members), size: 20)
            Text(member.name ?? member.login).foregroundStyle(Theme.text).lineLimit(1)
            Text(member.login == client.me?.login ? "@\(member.login) (you)" : "@\(member.login)").foregroundStyle(Theme.textMuted).lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.badge(member))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(member.role == "admin" ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(Theme.fill))
            if client.isAdmin && member.adminSource != "github" && member.login != client.me?.login {
                if member.role == "admin" {
                    Button("Remove admin") { client.revokeAdmin(member.login) }.controlSize(.small)
                } else {
                    Button("Make admin") { client.grantAdmin(member.login) }.controlSize(.small)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 6)
    }

    /// GitHub owner, Admin · added by @x, or Member.
    static func badge(_ member: Wire.Member) -> String {
        guard member.role == "admin" else { return "Member" }
        if member.adminSource == "granted" { return member.adminGrantedBy.map { "Admin · added by @\($0)" } ?? "Admin" }
        // An older server doesn't say why; then GitHub is the only way to be one.
        return "GitHub owner"
    }
}

struct SettingsHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke)))
    }
}

/// What the org adds to every planning, building and review session's prompt. Admins edit it; a goal
/// can add its own on top (the goal sheet's Agent instructions).
struct PromptSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var draft = LiveAdapter.noPrompts
    @State private var saved = false

    private var isAdmin: Bool { client.me?.role == "admin" }
    private var current: Wire.PromptAdditions { client.prompts ?? LiveAdapter.noPrompts }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Prompts", detail: "Added to every factory session's prompt for its role, after the task's brief. A goal's own instructions come after these.")
            if !client.isSignedIn {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Connect to a factory to see its prompts."))
            } else {
                SettingsCard {
                    PromptFields(prompts: $draft, editable: isAdmin, height: 96)
                }
                HStack {
                    if !isAdmin {
                        Label("Only admins can change these", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    } else if saved && draft == current {
                        Text("Saved").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    if isAdmin {
                        Button("Revert") { draft = current }.disabled(draft == current)
                        Button("Save") {
                            client.save(prompts: draft)
                            saved = true
                        }
                        .keyboardShortcut("s")
                        .disabled(draft == current)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .onAppear { draft = current }
        // Another admin's save, or the server's trimmed echo of ours.
        .onChange(of: client.prompts) { _, new in draft = new ?? LiveAdapter.noPrompts }
    }
}

/// Whether approved changes merge on their own, and what the factory does when one won't merge. Org-wide, on the risk policy; admins change it.
struct MergingSettings: View {
    @Environment(FactoryClient.self) private var client

    private var isAdmin: Bool { client.me?.role == "admin" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Merging", detail: "What happens after a change is approved, for everyone in the factory.")
            if !client.isSignedIn || client.riskPolicy == nil {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Connect to a factory to see how it merges."))
            } else {
                SettingsCard {
                    Toggle("Merge approved changes automatically", isOn: Binding(
                        get: { client.riskPolicy?.autoMerges ?? true },
                        set: { on in
                            guard var policy = client.riskPolicy else { return }
                            policy.autoMerges = on
                            client.save(policy: policy)
                        }
                    ))
                    .disabled(!isAdmin)
                    Text("When a change is proven, reviewed and its checks pass, the factory merges it if its risk level (or its goal's accepted risk) allows. Off: nothing merges on its own; ready changes wait in Pending merge until someone clicks Merge.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                SettingsCard {
                    Toggle("Fix merges automatically", isOn: Binding(
                        get: { client.riskPolicy?.autoFixMerges ?? true },
                        set: { on in
                            guard var policy = client.riskPolicy else { return }
                            policy.autoFixMerges = on
                            client.save(policy: policy)
                        }
                    ))
                    .disabled(!isAdmin)
                    Text("When an approved change won't merge into its base, a builder brings the branch up to date, resolves the conflicts and pushes, and review runs again. It tries twice before asking you. Off: the factory raises its hand and you pick what to do.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                if !isAdmin {
                    Label("Only admins can change this.", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
    }
}

/// Planning, Building and Review prompt additions, each a labelled multi-line editor.
struct PromptFields: View {
    @Binding var prompts: Wire.PromptAdditions
    var editable = true
    var height: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            editor("Planning", "How the planner should plan: conventions, what a plan must cover.", $prompts.planner)
            editor("Building", "What the builder must do: test commands, style, what not to touch.", $prompts.builder)
            editor("Review", "What the review agent should check for.", $prompts.reviewer)
        }
    }

    private func editor(_ label: String, _ hint: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                Spacer()
                if text.wrappedValue.count > 3500 {
                    Text("\(text.wrappedValue.count) / 4000").font(.system(size: 11)).foregroundStyle(text.wrappedValue.count > 4000 ? Theme.State.awaitingApproval : Theme.textFaint)
                }
            }
            TextEditor(text: text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .disabled(!editable)
                .opacity(editable ? 1 : 0.75)
                .padding(6)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(editable ? hint : "None").font(.system(size: 12.5)).foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
        }
    }
}

/// The repos goals can work in: the ones the GitHub App is installed on, and any an admin adds.
/// Clicking one opens its worktree scripts (`RepoScriptsDetail`).
struct RepositoriesSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding = ""
    @State private var refreshing = false
    @State private var filter = ""
    /// The repo whose detail is open (`-reposSelected owner/name` opens one at launch).
    @AppStorage("reposSelected") private var selected = ""

    private var isAdmin: Bool { client.me?.role == "admin" }
    private var selectedRepo: Wire.OrgRepo? {
        selected.isEmpty || !client.isSignedIn ? nil : client.repos.first { $0.name.lowercased() == selected.lowercased() }
    }

    var body: some View {
        if let repo = selectedRepo {
            RepoScriptsDetail(repo: repo) { selected = "" }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repositories")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("The ones the GitHub App is installed on come from GitHub: grant or remove its access there. Goals pick from these. Click one for its worktree scripts.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    refreshing = true
                    client.send(.reposRefresh)
                    Task { try? await Task.sleep(for: .seconds(1.5)); refreshing = false }
                } label: {
                    Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!client.isSignedIn || refreshing)
            }

            if !client.isSignedIn {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Connect to a factory to see its repositories."))
            } else if client.repos.isEmpty {
                ContentUnavailableView("No repositories yet", systemImage: "shippingbox",
                                       description: Text(isAdmin ? "Install the GitHub App on your org, or add one below." : "An admin installs the GitHub App on the org, or adds them here."))
            } else {
                TextField("Filter \(client.repos.count) repositories", text: $filter)
                    .textFieldStyle(.roundedBorder)
                List(client.repos.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter.trimmingCharacters(in: .whitespaces)) }, id: \.name) { repo in
                    HStack(spacing: 10) {
                        Image(systemName: repo.isPrivate ? "lock" : "globe")
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 16)
                        Text(repo.name)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.text)
                        if let branch = repo.defaultBranch {
                            Text(branch).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                        }
                        if client.scripts(for: repo.name) != nil {
                            Text("scripts")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.fill))
                                .help("Has worktree scripts")
                        }
                        Spacer()
                        Text(repo.source == .github ? "GitHub App" : "Added by hand")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        if repo.source == .manual && isAdmin {
                            Button {
                                client.send(.reposRemove(.init(name: repo.name)))
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(repo.name)")
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textFaint)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = repo.name }
                    .help("Open \(repo.name)'s worktree scripts")
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            if isAdmin && client.isSignedIn {
                HStack {
                    TextField("owner/name, or its GitHub URL", text: $adding)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
    }

    private func add() {
        let name = adding.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        client.send(.reposAdd(.init(name: name)))
        adding = ""
    }
}

/// Who shows in this person's sidebar: a few teammates, not the whole org.
struct PeopleSettings: View {
    @Environment(FactoryClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if client.isSignedIn { FactoryAdminsCard() }
            VStack(alignment: .leading, spacing: 4) {
                Text("People in your sidebar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(client.sidebarPicks == nil
                     ? "Until you pick, it shows people on your GitHub teams. Pick the ones you work with; only you see this."
                     : "Only you see this. Everyone in the org can still be mentioned and assigned.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let others = client.members.filter { $0.login != client.me?.login }
            if others.isEmpty {
                ContentUnavailableView("Just you so far", systemImage: "person", description: Text("Members of the org show up here once they sign in."))
            } else {
                List(others, id: \.login) { member in
                    let shown = client.sidebarMembers.contains { $0.login == member.login }
                    Toggle(isOn: Binding(get: { shown }, set: { on in
                        let current = client.sidebarMembers.map(\.login).filter { $0 != client.me?.login }
                        client.sidebarPicks = on ? current + [member.login] : current.filter { $0 != member.login }
                    })) {
                        HStack(spacing: 8) {
                            AgentAvatar(agent: LiveAdapter.person(member.login, members: client.members), size: 20)
                            Text(member.name ?? member.login).foregroundStyle(Theme.text)
                            Text("@\(member.login)").foregroundStyle(Theme.textMuted)
                            if !member.teams.isEmpty {
                                Text(member.teams.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                if client.sidebarPicks != nil {
                    Button("Go back to my teams") { client.sidebarPicks = nil }
                }
            }
        }
        .padding(20)
    }
}
