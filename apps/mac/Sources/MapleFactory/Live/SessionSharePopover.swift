import SwiftUI

/// Who else may open one live session's terminal: teammates picked from the org, each able to watch it
/// or to type into it too. Its machine's owner and admins see it; the whole list goes to the factory on
/// every change, and the server closes the terminals of anyone taken off.
struct SessionSharePopover: View {
    /// Headless: opens the open session's popover (`share:open`).
    static let demoOpen = Notification.Name("SessionSharePopover.demoOpen")

    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    let live: Wire.LiveSession

    @State private var adding = ""

    private var shares: [Wire.SessionShare] { live.shares ?? [] }

    /// Members who could be added: not the owner, not already in, not revoked.
    private var addable: [Wire.Member] {
        client.members.filter { m in m.login != machine.owner && !shares.contains { $0.login == m.login } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share this session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Teammates you add can open its terminal from Machines. \(machine.owner == client.me?.login ? "You" : machine.owner) and admins always can.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 2) {
                ForEach(shares, id: \.login) { share in row(share) }
                if shares.isEmpty {
                    Text("Not shared with anyone.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }

            if !addable.isEmpty {
                Menu {
                    ForEach(addable, id: \.login) { m in
                        Button("\(m.name ?? m.login) (@\(m.login))") { set(m.login, canType: false) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus").font(.system(size: 11.5))
                        Text("Add a teammate")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if shares.contains(where: \.canType) {
                Label("“Can type” gives a shell on \(machine.name), with this repo's secrets in its environment.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.State.awaitingApproval)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Hairline()

            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 11.5)).frame(width: 16)
                Text("Copy link").font(.system(size: 12.5))
                Spacer()
            }
            .foregroundStyle(Theme.text)
            .contentShape(Rectangle())
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("maplefactory://session/\(machine.id)/\(live.session.id)", forType: .string)
                state.showToast("Copied a link to this session: it opens for the people it's shared with", icon: "link")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ share: Wire.SessionShare) -> some View {
        HStack(spacing: 10) {
            AgentAvatar(agent: LiveAdapter.person(share.login, members: client.members), size: 24, online: client.online.contains { $0.login == share.login })
            VStack(alignment: .leading, spacing: 1) {
                Text(client.members.first { $0.login == share.login }?.name ?? share.login)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("@\(share.login) · by \(share.by == client.me?.login ? "you" : "@\(share.by)")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Picker("", selection: Binding(get: { share.canType }, set: { set(share.login, canType: $0) })) {
                Text("Can watch").tag(false)
                Text("Can type").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture { remove(share.login) }
                .help("Remove \(share.login): their terminal closes")
        }
        .padding(.vertical, 5)
    }

    private func set(_ login: String, canType: Bool) {
        var grants = shares.map { Wire.ShareGrant(login: $0.login, canType: $0.canType) }
        if let i = grants.firstIndex(where: { $0.login == login }) { grants[i].canType = canType } else { grants.append(.init(login: login, canType: canType)) }
        client.shareSession(machine: machine.id, id: live.session.id, shares: grants)
    }

    private func remove(_ login: String) {
        client.shareSession(machine: machine.id, id: live.session.id, shares: shares.filter { $0.login != login }.map { .init(login: $0.login, canType: $0.canType) })
    }
}
