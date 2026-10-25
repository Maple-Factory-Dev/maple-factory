import SwiftUI

/// The factory's settings (⌘,): what the org shares, what's yours, and this Mac's runner.
struct OrgSettingsView: View {
    @Environment(FactoryClient.self) private var client
    @AppStorage("settingsTab") private var tab = "repos"

    enum Pane: String, CaseIterable {
        case account, repos, people, runner

        var title: String {
            switch self {
            case .account: "Account"
            case .repos: "Repositories"
            case .people: "People"
            case .runner: "Runner"
            }
        }

        var icon: String {
            switch self {
            case .account: "person.crop.circle"
            case .repos: "shippingbox"
            case .people: "person.2"
            case .runner: "laptopcomputer"
            }
        }
    }

    private var pane: Binding<Pane?> {
        Binding(get: { Pane(rawValue: tab) ?? .repos }, set: { tab = ($0 ?? .repos).rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: pane) {
                Section("Factory") {
                    ForEach([Pane.account, .repos, .people], id: \.self) { row($0) }
                }
                Section("This Mac") { row(.runner) }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                // Repositories and People are lists, which scroll themselves.
                switch Pane(rawValue: tab) ?? .repos {
                case .account: ScrollView { AccountSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
                case .repos: RepositoriesSettings()
                case .people: PeopleSettings()
                case .runner: ScrollView { RunnerSettings().frame(maxWidth: .infinity, alignment: .topLeading) }
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

/// Which factory this app is signed in to, and as whom.
struct AccountSettings: View {
    @Environment(FactoryClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Account", detail: "The factory this app is connected to. Switch factories from the workspace menu at the top of the sidebar.")
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
                    LabeledContent("Status", value: client.status == .live ? "Connected" : "Reconnecting…")
                }
                Button("Sign Out", role: .destructive) { client.signOut() }
            } else {
                ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Connect to a factory from the workspace menu."))
            }
        }
        .font(.system(size: 13))
        .padding(20)
    }
}

/// This Mac's runner: whether it's in the factory, its version, and how much work it takes.
struct RunnerSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding: String?
    @State private var error: String?

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
                                if client.runnerOutdated(machine), let latest = client.runnerLatest {
                                    Text("· \(latest) available").foregroundStyle(Theme.State.awaitingApproval)
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button(client.runnerOutdated(machine) ? "Update" : "Check for Update") {
                            client.send(.machineUpdate(.init(machine: machine.id)))
                        }
                        .disabled(!machine.online)
                        Button("Show Log") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/maple-runner.log"))
                        }
                    }
                }
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

/// The repos goals can work in: the ones the GitHub App is installed on, and any an admin adds.
struct RepositoriesSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding = ""
    @State private var refreshing = false
    @State private var filter = ""

    private var isAdmin: Bool { client.me?.role == "admin" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repositories")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("The ones the GitHub App is installed on come from GitHub: grant or remove its access there. Goals pick from these.")
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
                    }
                    .padding(.vertical, 2)
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
