import MapleKit
import SwiftUI

/// Each repo's secret names and who last changed them; values never come back. Admins add, replace and delete.
struct SecretsSettingsView: View {
    @Environment(FactoryStore.self) private var store
    @State private var adding = false
    @State private var deleting: Wire.RepoSecret?

    private var byRepo: [(repo: String, secrets: [Wire.RepoSecret])] {
        Dictionary(grouping: store.feed.secrets, by: \.repo)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.repo < $1.repo }
    }

    var body: some View {
        List {
            if store.feed.secrets.isEmpty {
                ContentUnavailableView("No secrets", systemImage: "key", description: Text("Secrets are environment variables a repo's tasks get on the runner."))
            }
            ForEach(byRepo, id: \.repo) { group in
                Section(group.repo) {
                    ForEach(group.secrets, id: \.self) { secret in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(secret.name).font(.body.monospaced())
                            Text("@\(secret.updatedBy) · \(Date(timeIntervalSince1970: Double(secret.updatedAt) / 1000).formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("secret-\(secret.repo)-\(secret.name)")
                        .swipeActions {
                            if store.isAdmin {
                                Button("Delete", role: .destructive) { deleting = secret }
                            }
                        }
                    }
                }
            }
            Section {
            } footer: {
                if store.isAdmin {
                    Text("Values are kept on the server and only sent to runners. Setting a name that exists replaces it.")
                } else {
                    AdminOnlyNote()
                }
            }
        }
        .navigationTitle("Secrets")
        .toolbar {
            if store.isAdmin && !store.feed.repos.isEmpty {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add secret")
                    .accessibilityIdentifier("add-secret")
            }
        }
        .sheet(isPresented: $adding) { SecretSheet() }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = deleting { store.deleteSecret(repo: s.repo, name: s.name) }
                deleting = nil
            }
        } message: {
            Text("Tasks on \(deleting?.repo ?? "") won't get it any more.")
        }
    }
}

/// Adds or replaces one secret: repo, name and a value that's never shown again.
struct SecretSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var name = ""
    @State private var value = ""

    /// Environment variable names: A–Z, 0–9 and _, not starting with a digit.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "_" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repository", selection: $repo) {
                    ForEach(store.feed.repos, id: \.name) { Text($0.name).tag($0.name) }
                }
                Section {
                    TextField("NAME", text: $name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("secret-name")
                    SecureField("Value", text: $value)
                        .accessibilityIdentifier("secret-value")
                } footer: {
                    if !name.isEmpty && !Self.isValidName(name) {
                        Text("Use A–Z, 0–9 and _, not starting with a digit.").foregroundStyle(.red)
                    } else if store.feed.secrets.contains(where: { $0.repo == repo && $0.name == name }) {
                        Text("This replaces the existing \(name).")
                    }
                }
            }
            .navigationTitle("Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setSecret(repo: repo, name: name, value: value)
                        dismiss()
                    }
                    .disabled(repo.isEmpty || !Self.isValidName(name) || value.isEmpty)
                    .accessibilityIdentifier("save-secret")
                }
            }
            .onAppear { if repo.isEmpty { repo = store.feed.repos.first?.name ?? "" } }
        }
        .presentationDetents([.medium, .large])
    }
}
