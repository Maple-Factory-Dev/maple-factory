import SwiftUI

/// The factory's MCP connectors: MCP servers every session gets beside `maple`, on every machine.
/// Admins add and change them; secret values are write-only, so a stored one only ever shows as set.
struct ConnectorSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var editing: ConnectorDraft?
    /// A headless run's `connector:<name>` action: opens the sheet as Edit… or Add Connector… would.
    static let demoEdit = Notification.Name("ConnectorSettings.demoEdit")

    private var isAdmin: Bool { client.me?.role == "admin" }

    var body: some View {
        SettingsPane("Connectors",
                     subtitle: "MCP servers every factory session gets on every machine, beside Maple's own: Jira, Linear, your docs. Their tokens stay on the factory and go only to runners.",
                     accessory: isAdmin && client.connectors != nil ? AnyView(addButton) : nil) {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory to see its connectors.")
            } else if let connectors = client.connectors {
                SettingsSection(connectors.isEmpty ? "Connectors" : connectors.count == 1 ? "1 connector" : "\(connectors.count) connectors",
                                caption: isAdmin ? nil : "Only admins can add, change or turn off connectors.") {
                    if connectors.isEmpty {
                        SettingsRow("No connectors yet", detail: isAdmin ? "Add one to give every session its tools." : "An admin adds them.")
                    }
                    ForEach(connectors, id: \.name) { connector in row(connector, in: connectors) }
                }
            } else {
                SettingsUnavailable(title: "Needs a newer server", systemImage: "arrow.down.circle", detail: "Update this factory's maple-server to use connectors.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoEdit)) { note in
            let name = note.userInfo?["name"] as? String
            editing = client.connectors?.first { $0.name == name }.map(ConnectorDraft.init) ?? ConnectorDraft()
        }
        .sheet(item: $editing) { draft in
            ConnectorSheet(draft: draft, taken: Set((client.connectors ?? []).map(\.name)).subtracting(draft.original.map { [$0] } ?? [])) { saved in
                var list = client.connectors ?? []
                if let original = draft.original, let i = list.firstIndex(where: { $0.name == original }) {
                    if let saved { list[i] = saved } else { list.remove(at: i) }
                } else if let saved {
                    list.append(saved)
                }
                client.save(connectors: list)
            }
        }
    }

    private var addButton: some View {
        Button { editing = ConnectorDraft() } label: { Label("Add", systemImage: "plus") }
    }

    private func row(_ connector: Wire.McpConnector, in list: [Wire.McpConnector]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: connector.transport == .http ? "globe" : "terminal")
                .font(.system(size: 13)).foregroundStyle(Theme.textFaint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                HStack(spacing: 0) {
                    Text(Self.target(connector)).lineLimit(1).truncationMode(.middle)
                    Text(Self.tags(connector).map { " · \($0)" }.joined()).lineLimit(1).fixedSize()
                }
                .font(SettingsKit.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            if isAdmin {
                Button("Edit…") { editing = ConnectorDraft(connector) }
            }
            Toggle("Enabled", isOn: Binding(
                get: { connector.enabled },
                set: { on in
                    client.save(connectors: list.map { c in
                        var c = c
                        if c.name == connector.name { c.enabled = on }
                        return c
                    })
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!isAdmin)
        }
        .settingsRowPadding()
    }

    /// What it runs: the command line, or the URL.
    static func target(_ c: Wire.McpConnector) -> String {
        c.transport == .http ? c.url ?? "" : ShellWords.join([c.command ?? ""] + c.args)
    }

    static func tags(_ c: Wire.McpConnector) -> [String] {
        var tags: [String] = []
        let secrets = (c.transport == .http ? c.headers : c.env).count
        if secrets > 0 { tags.append(secrets == 1 ? "1 secret set" : "\(secrets) secrets set") }
        if c.autoAllow { tags.append("tools allowed without asking") }
        return tags
    }
}

/// A connector being added or edited. `original` is its name when editing (names don't change once saved:
/// the factory keeps its secrets by name).
struct ConnectorDraft: Identifiable {
    struct Secret: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
        /// The factory has a value for this key: blank keeps it.
        var stored: Bool
    }

    let id = UUID()
    var original: String?
    var name = ""
    var transport: Wire.McpTransport = .stdio
    var command = ""
    var args = ""
    var url = ""
    var secrets: [Secret] = []
    var enabled = true
    var autoAllow = false
    /// The saved connector's transport and secret keys: switching away from it drops them (the other
    /// transport's server has no values for them), and switching back brings them back.
    private var savedTransport: Wire.McpTransport?
    private var savedKeys: [String] = []

    init() {}

    init(_ c: Wire.McpConnector) {
        original = c.name
        name = c.name
        transport = c.transport == .http ? .http : .stdio
        command = c.command ?? ""
        args = ShellWords.join(c.args)
        url = c.url ?? ""
        savedTransport = transport
        savedKeys = (c.transport == .http ? c.headers : c.env).keys.sorted()
        secrets = savedKeys.map { Secret(key: $0, value: "", stored: true) }
        enabled = c.enabled
        autoAllow = c.autoAllow
    }

    /// Keeps the secrets in step with the transport: env vars for stdio, headers for http.
    mutating func transportChanged() {
        secrets.removeAll { $0.stored }
        if transport == savedTransport {
            secrets.insert(contentsOf: savedKeys.map { Secret(key: $0, value: "", stored: true) }, at: 0)
        }
    }

    var connector: Wire.McpConnector {
        let pairs = Dictionary(secrets.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { a, _ in a })
        let stdio = transport != .http
        return Wire.McpConnector(
            name: name.trimmingCharacters(in: .whitespaces).lowercased(),
            transport: transport,
            command: stdio ? command.trimmingCharacters(in: .whitespaces) : nil,
            args: stdio ? ShellWords.split(args) : [],
            url: stdio ? nil : url.trimmingCharacters(in: .whitespaces),
            env: stdio ? pairs : [:],
            headers: stdio ? [:] : pairs,
            enabled: enabled,
            autoAllow: autoAllow
        )
    }
}

/// Add or edit one connector. `done(nil)` deletes it.
struct ConnectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ConnectorDraft
    let taken: Set<String>
    let done: (Wire.McpConnector?) -> Void

    private var stdio: Bool { draft.transport != .http }
    private var problem: String? {
        let name = draft.name.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty { return "" }
        if name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil { return "Lowercase letters, digits and dashes." }
        if name == "maple" { return "maple is the factory's own server." }
        if taken.contains(name) { return "There's already a connector named \(name)." }
        if stdio, draft.command.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if !stdio, !(draft.url.hasPrefix("https://") || draft.url.hasPrefix("http://")) { return "An http(s) URL." }
        if let s = draft.secrets.first(where: { !$0.key.isEmpty && $0.value.isEmpty && !$0.stored }) { return "\(s.key) needs a value." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("jira"))
                        .font(.system(size: 13, design: .monospaced))
                        .disabled(draft.original != nil)
                    Picker("Runs as", selection: $draft.transport) {
                        Text("A local command (stdio)").tag(Wire.McpTransport.stdio)
                        Text("A server at a URL (http)").tag(Wire.McpTransport.http)
                    }
                    if stdio {
                        TextField("Command", text: $draft.command, prompt: Text("npx"))
                            .font(.system(size: 13, design: .monospaced))
                        TextField("Arguments", text: $draft.args, prompt: Text("-y mcp-atlassian \"--config=/path with spaces\""))
                            .font(.system(size: 13, design: .monospaced))
                    } else {
                        TextField("URL", text: $draft.url, prompt: Text("https://mcp.example.com/mcp"))
                            .font(.system(size: 13, design: .monospaced))
                    }
                } footer: {
                    Text("Its tools are mcp__\(draft.name.isEmpty ? "name" : draft.name.lowercased())__* in every session. The command runs on each machine, so it has to be installed there (npx and uvx fetch theirs).")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                }
                Section {
                    ForEach($draft.secrets) { $secret in
                        HStack {
                            TextField("Name", text: $secret.key, prompt: Text(stdio ? "JIRA_API_TOKEN" : "Authorization"))
                                .font(.system(size: 12.5, design: .monospaced))
                                .labelsHidden()
                                .disabled(secret.stored)
                            SecureField("Value", text: $secret.value, prompt: Text(secret.stored ? "set" : "value"))
                                .labelsHidden()
                            Button { draft.secrets.removeAll { $0.id == secret.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove")
                        }
                    }
                    Button(stdio ? "Add Variable" : "Add Header") { draft.secrets.append(.init(key: "", value: "", stored: false)) }
                } header: {
                    Text(stdio ? "Environment variables" : "Headers")
                } footer: {
                    Text("Write-only: a stored value shows as “set”. Leave it blank to keep it, or type a new one to replace it.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                }
                Section {
                    Toggle("Enabled", isOn: $draft.enabled)
                    Toggle("Allow its tools without asking", isOn: $draft.autoAllow)
                } footer: {
                    Text("Unattended sessions use its tools without stopping for permission. Off: Claude's auto mode decides each call.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.transport) { draft.transportChanged() }
            HStack {
                if draft.original != nil {
                    Button("Delete", role: .destructive) {
                        done(nil)
                        dismiss()
                    }
                }
                if let problem, !problem.isEmpty {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.State.cancelled)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? "Add" : "Save") {
                    done(draft.connector)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
    }
}

/// Arguments as one line, the way a shell reads them: spaces separate them, and quotes ('…' or "…")
/// or a backslash keep spaces (and quotes) inside one.
enum ShellWords {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                word.append(ch)
                escaped = false
            } else if ch == "\\", quote != "'" {
                escaped = true
                inWord = true
            } else if let q = quote {
                if ch == q { quote = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
            } else if ch.isWhitespace {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The other way: an argument with spaces, quotes or nothing in it is single-quoted.
    static func join(_ words: [String]) -> String {
        words.map { w in
            let plain = !w.isEmpty && w.allSatisfy { !$0.isWhitespace && !"'\"\\$`".contains($0) }
            return plain ? w : "'" + w.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
