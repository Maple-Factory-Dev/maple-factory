import MapleKit
import SwiftUI

/// Who's in the factory, admins first. Admins make or remove admins, and revoke access.
struct PeopleSettingsView: View {
    @Environment(FactoryStore.self) private var store
    @State private var revoking: Wire.Member?

    private var members: [Wire.Member] {
        store.feed.members.sorted { a, b in
            if (a.role == "admin") != (b.role == "admin") { return a.role == "admin" }
            return (a.name ?? a.login).localizedCaseInsensitiveCompare(b.name ?? b.login) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(members, id: \.login) { row($0) }
            } footer: {
                if store.isAdmin {
                    Text("Admins change the factory's settings, secrets and prompts. Owners of the GitHub organization always are.")
                } else {
                    AdminOnlyNote(text: "Only admins can change who's an admin.")
                }
            }
        }
        .navigationTitle("People")
        .confirmationDialog("Revoke \(revoking?.login ?? "")'s access?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Revoke access", role: .destructive) {
                if let login = revoking?.login { store.revokeMember(login) }
                revoking = nil
            }
        } message: {
            Text("Signs \(revoking?.login ?? "") out of every app and browser now and closes their terminals. They can sign in again while GitHub lets them.")
        }
    }

    private func badge(_ member: Wire.Member) -> String {
        guard member.role == "admin" else { return "Member" }
        return member.adminSource == "github" ? "Owner" : "Admin"
    }

    private func row(_ member: Wire.Member) -> some View {
        let isMe = member.login == store.me
        let canChange = store.isAdmin && !isMe && member.adminSource != "github"
        return HStack(spacing: 12) {
            Avatar(login: member.login, url: member.avatarUrl, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name ?? member.login)
                Text(isMe ? "@\(member.login) (you)" : "@\(member.login)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge(member))
                .font(.caption.weight(.medium))
                .foregroundStyle(member.role == "admin" ? .primary : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .accessibilityIdentifier("role-\(member.login)")
            if canChange {
                Menu {
                    if member.role == "admin" {
                        Button { store.revokeAdmin(member.login) } label: { Label("Remove admin", systemImage: "person.badge.minus") }
                    } else {
                        Button { store.grantAdmin(member.login) } label: { Label("Make admin", systemImage: "person.badge.shield.checkmark") }
                    }
                    Button(role: .destructive) { revoking = member } label: { Label("Revoke access", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityIdentifier("member-menu-\(member.login)")
            }
        }
        .accessibilityIdentifier("member-\(member.login)")
    }
}
