import MapleKit
import SwiftUI

/// The factory's repos, grouped by owner. Admins hold and release merges into a repo (an incident freeze).
struct RepositoriesSettingsView: View {
    @Environment(FactoryStore.self) private var store
    /// The repo whose "Hold merges" prompt is open.
    @State private var holding: String?
    @State private var reason = ""

    private var owners: [(owner: String, repos: [Wire.OrgRepo])] {
        Dictionary(grouping: store.feed.repos) { String($0.name.split(separator: "/").first ?? "") }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.owner < $1.owner }
    }

    var body: some View {
        List {
            if store.feed.repos.isEmpty {
                ContentUnavailableView("No repositories", systemImage: "shippingbox", description: Text("Add repos from the Mac app's Repositories settings."))
            }
            ForEach(owners, id: \.owner) { group in
                Section(group.owner) {
                    ForEach(group.repos, id: \.name) { repo in row(repo) }
                }
            }
            Section {
            } footer: {
                if store.isAdmin {
                    Text("Swipe a repo, or touch and hold it, to hold merges into it. Nothing merges into a held repo, on any goal, until someone lifts the hold.")
                } else {
                    AdminOnlyNote()
                }
            }
        }
        .navigationTitle("Repositories")
        .alert("Hold merges into \(holding ?? "")", isPresented: Binding(get: { holding != nil }, set: { if !$0 { holding = nil } })) {
            TextField("Why? e.g. Incident #42", text: $reason)
                .accessibilityIdentifier("hold-reason")
            Button("Cancel", role: .cancel) { holding = nil }
            Button("Hold merges") {
                let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if let repo = holding { store.holdMerges(repo, reason: String((why.isEmpty ? "On hold" : why).prefix(200))) }
                holding = nil
            }
        } message: {
            Text("Auto-merge countdowns stop and Merge is refused. Tasks keep building and reviewing.")
        }
    }

    @ViewBuilder
    private func row(_ repo: Wire.OrgRepo) -> some View {
        let hold = store.mergeHold(repo.name)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.name.split(separator: "/").last.map(String.init) ?? repo.name).font(.body.weight(.medium))
                Spacer()
                if hold != nil {
                    Label("Merges on hold", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.orange.opacity(0.14)))
                        .accessibilityIdentifier("hold-badge-\(repo.name)")
                }
            }
            HStack(spacing: 10) {
                Label(repo.isPrivate ? "Private" : "Public", systemImage: repo.isPrivate ? "lock" : "globe")
                if let branch = repo.defaultBranch { Label(branch, systemImage: "arrow.triangle.branch") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let hold {
                Text("\(hold.reason) · @\(hold.by)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("repo-\(repo.name)")
        .swipeActions(edge: .trailing) {
            if store.isAdmin { holdButton(repo.name, held: hold != nil) }
        }
        .contextMenu {
            if store.isAdmin { holdButton(repo.name, held: hold != nil) }
        }
    }

    @ViewBuilder
    private func holdButton(_ repo: String, held: Bool) -> some View {
        if held {
            Button { store.releaseMerges(repo) } label: { Label("Release merges", systemImage: "play.fill") }
                .tint(.green)
        } else {
            Button { reason = ""; holding = repo } label: { Label("Hold merges", systemImage: "hand.raised.fill") }
                .tint(.orange)
        }
    }
}
