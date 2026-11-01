import MapleKit
import SwiftUI
import UIKit

// Start, share and end live sessions from the phone, as the Mac's Machines page does. Shown only to the
// machine's owner or an admin (store.canManage): the same check the server's org-hub applies to
// session.open, session.kill and session.share.

/// A new terminal session on a machine: an installed agent in one of its folders. Once the runner reports
/// it, the phone opens its terminal.
struct NewSessionSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machine: Wire.Machine

    @State private var agent = ""
    @State private var folder = ""
    @State private var other = ""
    /// The sessions already there when Start was tapped: the new one is the first that isn't.
    @State private var awaiting: Set<String>?
    @State private var failed = false

    private static let otherTag = "\u{0}other"

    private var current: Wire.Machine { store.feed.machines.first { $0.id == machine.id } ?? machine }
    private var agents: [Wire.AgentInstall] { current.health?.agents ?? [] }
    private var folders: [String] { store.folderChoices(for: current) }
    private var cwd: String {
        (folder == Self.otherTag ? other : folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canStart: Bool {
        current.online && awaiting == nil && !cwd.isEmpty && agents.contains { $0.name == agent && $0.loggedIn }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if agents.isEmpty {
                        Text("No agents reported by \(current.name) yet.").foregroundStyle(.secondary)
                    }
                    Picker("Agent", selection: $agent) {
                        ForEach(agents, id: \.name) { install in
                            VStack(alignment: .leading) {
                                Text(install.name)
                                if !install.loggedIn { Text("not signed in").font(.caption).foregroundStyle(.secondary) }
                            }
                            .tag(install.name)
                            .selectionDisabled(!install.loggedIn)
                            .foregroundStyle(install.loggedIn ? .primary : .secondary)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("new-session-agent")
                } header: { Text("Agent") }

                Section {
                    Picker("Folder", selection: $folder) {
                        ForEach(folders, id: \.self) { Text($0).font(.body.monospaced()).tag($0) }
                        Text("Other…").tag(Self.otherTag)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("new-session-folder")
                    if folder == Self.otherTag {
                        TextField("~/path/to/repo", text: $other)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("new-session-other")
                    }
                } header: { Text("Folder") } footer: {
                    if !current.online { Text("\(current.name) is offline.") }
                }

                if failed {
                    Label("Couldn't start a session", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("new-session-failed")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if awaiting != nil {
                        ProgressView()
                    } else {
                        Button("Start", action: start).disabled(!canStart).accessibilityIdentifier("new-session-start")
                    }
                }
            }
            .onAppear {
                if agent.isEmpty { agent = agents.first { $0.loggedIn }?.name ?? "" }
                if folder.isEmpty { folder = folders.first ?? Self.otherTag }
            }
            // The runner's reply is the session turning up on the machine, as on the Mac.
            .onChange(of: current.sessions.map(\.session.id)) { _, ids in
                guard let known = awaiting, let id = ids.first(where: { !known.contains($0) }) else { return }
                awaiting = nil
                dismiss()
                store.pendingLink = .session(machine: machine.id, id: id)
            }
        }
    }

    private func start() {
        failed = false
        let known = Set(current.sessions.map(\.session.id))
        awaiting = known
        store.openSession(machine: machine.id, agent: agent, cwd: cwd)
        Task {
            try? await Task.sleep(for: .seconds(10))
            if awaiting == known { awaiting = nil; failed = true }
        }
    }
}

/// Who else may open one live session's terminal, a port of the Mac's SessionSharePopover: teammates
/// picked from the org, each able to watch it or type into it too. Every change sends the whole list.
struct SessionShareSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machineID: String
    let sessionID: String

    private var machine: Wire.Machine? { store.feed.machines.first { $0.id == machineID } }
    private var live: Wire.LiveSession? { machine?.sessions.first { $0.session.id == sessionID } }
    private var shares: [Wire.SessionShare] { live?.shares ?? [] }
    private var addable: [Wire.Member] {
        store.feed.members.filter { m in m.login != machine?.owner && !shares.contains { $0.login == m.login } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if shares.isEmpty {
                        Text("Not shared with anyone.").foregroundStyle(.secondary)
                    }
                    ForEach(shares, id: \.login) { row($0) }
                    if !addable.isEmpty {
                        Menu {
                            ForEach(addable, id: \.login) { m in
                                Button("\(m.name ?? m.login) (@\(m.login))") { set(m.login, canType: false) }
                            }
                        } label: {
                            Label("Add a teammate", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("share-add")
                    }
                } header: {
                    Text("Shared with")
                } footer: {
                    Text("Teammates you add can open its terminal from Machines. \(machine?.owner == store.me ? "You" : "@\(machine?.owner ?? "")") and admins always can.")
                }

                if shares.contains(where: \.canType) {
                    Section {
                        Label("“Can type” gives a shell on \(machine?.name ?? machineID), with this repo's secrets in its environment.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                            .accessibilityIdentifier("share-type-warning")
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = "maplefactory://session/\(machineID)/\(sessionID)"
                        store.notice = .toast("Copied a link to this session: it opens for the people it's shared with", taskId: nil)
                    } label: {
                        Label("Copy link", systemImage: "link")
                    }
                    .accessibilityIdentifier("share-copy-link")
                }
            }
            .navigationTitle("Share session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: live == nil) { _, gone in if gone { dismiss() } }
        }
    }

    private func row(_ share: Wire.SessionShare) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.feed.members.first { $0.login == share.login }?.name ?? share.login)
                Text("@\(share.login) · by \(share.by == store.me ? "you" : "@\(share.by)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Access", selection: Binding(get: { share.canType }, set: { set(share.login, canType: $0) })) {
                Text("Can watch").tag(false)
                Text("Can type").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("share-access-\(share.login)")
            Button { remove(share.login) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(share.login)")
            .accessibilityIdentifier("share-remove-\(share.login)")
        }
    }

    private func set(_ login: String, canType: Bool) {
        var grants = shares.map { Wire.ShareGrant(login: $0.login, canType: $0.canType) }
        if let i = grants.firstIndex(where: { $0.login == login }) { grants[i].canType = canType } else { grants.append(.init(login: login, canType: canType)) }
        store.shareSession(machine: machineID, id: sessionID, shares: grants)
    }

    private func remove(_ login: String) {
        store.shareSession(machine: machineID, id: sessionID,
                           shares: shares.filter { $0.login != login }.map { .init(login: $0.login, canType: $0.canType) })
    }
}

/// "agent · task" for a session, as the End confirmations name it.
func sessionName(_ live: Wire.LiveSession) -> String {
    [live.session.agent, live.session.taskId].compactMap { $0 }.joined(separator: " · ")
}
