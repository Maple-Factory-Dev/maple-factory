import SwiftUI

/// The factory's own settings (⌘,): what the whole org shares.
struct OrgSettingsView: View {
    @AppStorage("settingsTab") private var tab = "repos"

    var body: some View {
        TabView(selection: $tab) {
            RepositoriesSettings()
                .tabItem { Label("Repositories", systemImage: "shippingbox") }
                .tag("repos")
            PeopleSettings()
                .tabItem { Label("People", systemImage: "person.2") }
                .tag("people")
        }
        .frame(width: 560, height: 460)
    }
}

/// The repos goals can work in: the ones the GitHub App is installed on, and any an admin adds.
struct RepositoriesSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding = ""
    @State private var refreshing = false

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
                List(client.repos, id: \.name) { repo in
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
