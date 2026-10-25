import SwiftUI

/// Who's in the factory and how to bring someone in. Membership is the GitHub org's, so sharing is a
/// link to sign in (and, with a task open, a link to it) rather than an invite the factory keeps.
struct SharePopover: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    private struct Row: Identifiable {
        let person: Person
        let login: String
        let role: String
        let online: Bool
        let viewing: String?
        var id: String { login }
    }

    private var rows: [Row] {
        if state.isLive {
            return client.members.map { m in
                let presence = client.online.first { $0.login == m.login }
                return Row(person: LiveAdapter.person(m.login, members: client.members), login: m.login, role: m.role,
                           online: presence != nil, viewing: presence?.viewing)
            }
            .sorted { ($0.online ? 0 : 1, $0.login) < ($1.online ? 0 : 1, $1.login) }
        }
        return FactoryData.presence.map { p in
            Row(person: p.person, login: p.person.github ?? p.person.firstName.lowercased(), role: "member", online: true, viewing: p.viewing)
        }
    }

    private var org: String { state.isLive ? (client.org.isEmpty ? client.workspaceName : client.org) : "acme" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share \(state.isLive ? client.workspaceName : "Atlas")")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Everyone in the \(org) GitHub org can sign in; their teams and roles come from GitHub.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 2) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        AgentAvatar(agent: row.person, size: 24, online: row.online)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.login == client.me?.login ? "\(row.person.name) (you)" : row.person.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text(row.viewing.map { "Looking at \($0)" } ?? (row.online ? "Online" : "@\(row.login)"))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        if row.role == "admin" {
                            Text("Admin")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(Capsule().fill(Theme.fill))
                        }
                    }
                    .padding(.vertical, 5)
                }
            }

            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                if let id = state.focusedTask {
                    action("Copy link to \(id)", icon: "link") { state.copyLink(id) }
                }
                action("Copy sign-in link", icon: "person.badge.plus") {
                    let link = state.isLive ? client.server?.absoluteString ?? "" : "https://maplefactory.dev"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    state.showToast("Copied the sign-in link: anyone in \(org) can use it", icon: "person.badge.plus")
                }
                action("Add people on GitHub", icon: "arrow.up.right.square") {
                    if let url = URL(string: "https://github.com/orgs/\(org)/people") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11.5)).frame(width: 16)
            Text(title).font(.system(size: 12.5))
            Spacer()
        }
        .foregroundStyle(Theme.text)
        .contentShape(Rectangle())
        .onTapGesture(perform: perform)
    }
}
