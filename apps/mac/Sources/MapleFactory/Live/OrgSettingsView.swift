import SwiftUI

/// The factory's own settings (⌘,): what the whole org shares.
struct OrgSettingsView: View {
    var body: some View {
        TabView {
            RepositoriesSettings()
                .tabItem { Label("Repositories", systemImage: "shippingbox") }
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
