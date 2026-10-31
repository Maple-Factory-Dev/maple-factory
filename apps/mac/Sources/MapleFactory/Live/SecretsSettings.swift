import SwiftUI

/// A repo's secrets: names and who changed them when. Admins add, replace and delete them; a value
/// goes to the factory once and is never shown again. Task sessions on the repo get them as
/// environment variables, and `maple-runner secrets pull` writes them to a checkout's .env.local.
struct SecretsSettings: View {
    @Environment(FactoryClient.self) private var client
    @AppStorage("secretsRepo") private var picked = ""
    @State private var editing: SecretSheet.Mode?
    @State private var deleting: Wire.RepoSecret?

    /// The headless `secret:add` action: the Add sheet, for screenshots; `secret:save:NAME:value` types
    /// into the open sheet and clicks Add.
    static let demoAdd = Notification.Name("SecretsSettings.demoAdd")
    static let demoSave = Notification.Name("SecretsSettings.demoSave")

    private var isAdmin: Bool { client.me?.role == "admin" }
    /// The picked repo, else the first with secrets, else the first.
    private var repo: String? {
        let names = client.repos.map(\.name)
        if names.contains(picked) { return picked }
        return names.first { name in client.secrets.contains { $0.repo.lowercased() == name.lowercased() } } ?? names.first
    }
    private var listed: [Wire.RepoSecret] {
        guard let repo else { return [] }
        return client.secrets.filter { $0.repo.lowercased() == repo.lowercased() }.sorted { $0.name < $1.name }
    }

    var body: some View {
        SettingsPane("Secrets",
                     subtitle: "Task sessions on a repo get its secrets as environment variables, and maple-runner secrets pull writes them to a gitignored .env.local in your checkout. Values are encrypted on the factory and never shown again.",
                     accessory: isAdmin && client.isSignedIn && repo != nil ? AnyView(addButton) : nil) {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory to see its secrets.")
            } else if client.repos.isEmpty {
                SettingsUnavailable(title: "No repositories yet", systemImage: "shippingbox", detail: "Secrets belong to a repo. Add one in Repositories first.")
            } else {
                SettingsSection {
                    SettingsPicker("Repository", selection: Binding(get: { repo ?? "" }, set: { picked = $0 })) {
                        ForEach(client.repos, id: \.name) { r in
                            let count = client.secrets.filter { $0.repo.lowercased() == r.name.lowercased() }.count
                            Text(count > 0 ? "\(r.name)  (\(count))" : r.name).tag(r.name)
                        }
                    }
                }
                SettingsSection(listed.isEmpty ? "Secrets" : listed.count == 1 ? "1 secret" : "\(listed.count) secrets",
                                caption: isAdmin ? nil : "Only admins can add, replace or delete secrets.") {
                    if listed.isEmpty {
                        SettingsRow("No secrets for \(repo ?? "this repo")", detail: isAdmin ? "Add one, like API_KEY or DATABASE_URL." : "An admin adds them.")
                    }
                    ForEach(listed) { s in row(s) }
                }
            }
        }
        .sheet(item: $editing) { mode in
            SecretSheet(mode: mode, taken: Set(listed.map(\.name))) { name, value in
                client.send(.secretsSet(.init(repo: mode.repo, name: name, value: value)))
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { s in
            Button("Delete", role: .destructive) { client.send(.secretsDelete(.init(repo: s.repo, name: s.name))) }
        } message: { s in
            Text("Task sessions on \(s.repo) stop getting it, and the next secrets pull leaves it out. Checkouts that pulled it keep their copy.")
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoAdd)) { _ in
            if let repo { editing = .add(repo: repo) }
        }
    }

    private var addButton: some View {
        Button {
            if let repo { editing = .add(repo: repo) }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    /// A secret's name, who changed it when, and (for admins) Replace and Delete.
    private func row(_ s: Wire.RepoSecret) -> some View {
        let at = Date(timeIntervalSince1970: Double(s.updatedAt) / 1000)
        return HStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).help(s.name)
                (Text("@\(s.updatedBy) · ") + Text(at, format: .relative(presentation: .named)))
                    .font(SettingsKit.caption).foregroundStyle(Theme.textMuted).help(at.formatted())
            }
            Spacer(minLength: 8)
            if isAdmin {
                Button("Replace") { editing = .replace(repo: s.repo, name: s.name) }
                Button { deleting = s } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete \(s.name)")
            }
        }
        .settingsRowPadding()
    }
}

extension Wire.RepoSecret: Identifiable {
    public var id: String { "\(repo)/\(name)" }
}

/// Add a secret, or replace one's value. The value is typed into a secure field and sent once.
struct SecretSheet: View {
    enum Mode: Identifiable {
        case add(repo: String)
        case replace(repo: String, name: String)
        var id: String {
            switch self {
            case .add(let repo): "add:\(repo)"
            case .replace(let repo, let name): "replace:\(repo)/\(name)"
            }
        }
        var repo: String {
            switch self {
            case .add(let repo), .replace(let repo, _): repo
            }
        }
    }

    let mode: Mode
    let taken: Set<String>
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""

    private var replacing: String? {
        if case .replace(_, let name) = mode { return name }
        return nil
    }
    private var cleanName: String { (replacing ?? name).trimmingCharacters(in: .whitespaces).uppercased() }
    private var nameProblem: String? {
        if replacing != nil || cleanName.isEmpty { return nil }
        if cleanName.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) == nil { return "Letters, digits and _, not starting with a digit." }
        if taken.contains(cleanName) { return "\(cleanName) is already there; use Replace to change its value." }
        return nil
    }
    private var tooBig: Bool { value.utf8.count > 32 * 1024 }
    private var canSave: Bool { !cleanName.isEmpty && nameProblem == nil && !value.isEmpty && !tooBig }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(replacing.map { "Replace \($0)" } ?? "Add a secret").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("For \(mode.repo). Once saved, nobody sees the value again, here or anywhere else.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                if let replacing {
                    Text(replacing).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                } else {
                    TextField("API_KEY", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: name) { _, new in if new != new.uppercased() { name = new.uppercased() } }
                    if let nameProblem {
                        Text(nameProblem).font(.system(size: 11.5)).foregroundStyle(Theme.State.cancelled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Value").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                SecureField(replacing == nil ? "Paste the value" : "Paste the new value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSave { commit() } }
                if tooBig {
                    Text("A value can be at most 32 KB.").font(.system(size: 11.5)).foregroundStyle(Theme.State.cancelled)
                }
            }
            Text("Task sessions get it as $\(cleanName.isEmpty ? "NAME" : cleanName); it's never written into a worktree.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(replacing == nil ? "Add" : "Replace", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onReceive(NotificationCenter.default.publisher(for: SecretsSettings.demoSave)) { note in
            name = note.userInfo?["name"] as? String ?? name
            value = note.userInfo?["value"] as? String ?? ""
            if canSave { commit() }
        }
    }

    private func commit() {
        save(cleanName, value)
        value = ""
        dismiss()
    }
}
