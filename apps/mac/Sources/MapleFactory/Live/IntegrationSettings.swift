import AppKit
import SwiftUI

/// Where requests come into the factory from: Slack's /maple, and Linear and Jira issues with its label.
/// Admins set each one up here; secret values are write-only, as with connectors, and a value the
/// Worker's env vars give shows as set by the environment until one is saved here.
struct IntegrationSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var open: Set<String> = []
    /// What's been typed into each one's fields, by kind then field, until it's saved.
    @State private var drafts: [String: [String: String]] = [:]
    /// A headless run's `integration:<kind>` action: opens that one's fields.
    static let demoOpen = Notification.Name("IntegrationSettings.demoOpen")

    private var isAdmin: Bool { client.me?.role == "admin" }

    var body: some View {
        SettingsPane("Integrations",
                     subtitle: "Where requests come into the factory from: Slack's /maple, and Linear or Jira issues with the factory's label. The bot answers back where they came from.") {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory to see its integrations.")
            } else if let integrations = client.integrations {
                SettingsSection("Integrations", caption: isAdmin ? nil : "Only admins can set up, change or turn off integrations.") {
                    ForEach(integrations, id: \.kind) { integration in
                        row(integration)
                        if open.contains(integration.kind.rawValue) { details(integration) }
                    }
                }
            } else {
                SettingsUnavailable(title: "Needs a newer server", systemImage: "arrow.down.circle", detail: "Update this factory's maple-server to set up integrations here.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoOpen)) { note in
            if let kind = note.object as? String { open.insert(kind) }
        }
    }

    private func row(_ i: Wire.Integration) -> some View {
        let kind = i.kind.rawValue
        return HStack(spacing: 10) {
            SettingsTile(icon: Self.icon(i.kind), color: Self.color(i.kind), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                status(i).font(SettingsKit.caption).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { i.enabled },
                set: { on in client.save(integration: i.kind, enabled: on, values: Self.kept(i)) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!isAdmin)
            Button {
                if open.contains(kind) { open.remove(kind) } else { open.insert(kind) }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(open.contains(kind) ? 90 : 0))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open.contains(kind) ? "Hide its settings" : "Show its settings")
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }

    /// Connected · last event 3m ago, Not set up, Off, or the last thing that went wrong.
    @ViewBuilder private func status(_ i: Wire.Integration) -> some View {
        if let error = i.lastError {
            Text("Error: \(error)").foregroundStyle(Theme.State.cancelled)
        } else if i.enabled {
            if let at = i.lastEventAt {
                (Text("Connected · last event ") + Text(Date(timeIntervalSince1970: Double(at) / 1000), format: .relative(presentation: .named)))
                    .foregroundStyle(Theme.textMuted)
            } else {
                Text("Connected · no events yet").foregroundStyle(Theme.textMuted)
            }
        } else if i.updatedBy != nil {
            Text("Off").foregroundStyle(Theme.textMuted)
        } else {
            Text("Not set up").foregroundStyle(Theme.textFaint)
        }
    }

    private func details(_ i: Wire.Integration) -> some View {
        let kind = i.kind.rawValue
        let draft = drafts[kind] ?? [:]
        return SettingsBlock(spacing: 12) {
            ForEach(i.fields, id: \.name) { f in
                fieldEditor(f, of: i)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Webhook URL").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    Text(webhookURL(i))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(webhookURL(i), forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if !i.fromEnv.isEmpty {
                Label("Set by environment: \(i.fields.filter { i.fromEnv.contains($0.name) }.map(\.label).joined(separator: ", ")). A value saved here wins over it.", systemImage: "server.rack")
                    .font(SettingsKit.caption).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let by = i.updatedBy, let at = i.updatedAt {
                (Text("Saved by @\(by) · ") + Text(Date(timeIntervalSince1970: Double(at) / 1000), format: .relative(presentation: .named)))
                    .font(SettingsKit.caption).foregroundStyle(Theme.textFaint)
            }
            if isAdmin {
                HStack {
                    Spacer()
                    Button("Revert") { drafts[kind] = nil }.disabled(draft.isEmpty)
                    Button(i.enabled || i.updatedBy == nil ? "Save" : "Save and Turn On") {
                        var values = Self.kept(i)
                        for (name, value) in draft { values[name] = value }
                        client.save(integration: i.kind, enabled: true, values: values)
                        drafts[kind] = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.isEmpty && i.enabled)
                }
            }
        }
    }

    private func fieldEditor(_ f: Wire.IntegrationField, of i: Wire.Integration) -> some View {
        let kind = i.kind.rawValue
        let isSet = i.values[f.name] != nil
        let binding = Binding(
            get: { drafts[kind]?[f.name] ?? (f.secret ? "" : (i.fromEnv.contains(f.name) ? "" : i.values[f.name] ?? "")) },
            set: { drafts[kind, default: [:]][f.name] = $0 }
        )
        let prompt = f.secret
            ? (isSet ? "••••••••" : f.required ? "Required" : "Optional")
            : (i.fromEnv.contains(f.name) ? i.values[f.name] ?? "" : f.required ? "Required" : "Optional")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(f.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                if i.fromEnv.contains(f.name) {
                    Text("environment").font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().strokeBorder(SettingsKit.groupStroke))
                }
            }
            Group {
                if f.secret {
                    SecureField(f.label, text: binding, prompt: Text(prompt))
                } else {
                    TextField(f.label, text: binding, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5, design: .monospaced))
            .labelsHidden()
            .disabled(!isAdmin)
            Text(f.help + (f.secret && isSet ? " Leave it blank to keep the one that's set." : ""))
                .font(SettingsKit.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The URL to paste into Slack, Linear or Jira: the server's own, when it only gave a path.
    private func webhookURL(_ i: Wire.Integration) -> String {
        guard i.webhookUrl.hasPrefix("/"), let server = client.server else { return i.webhookUrl }
        var base = server.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base + i.webhookUrl + (i.kind == .jira ? "?secret=<webhook secret>" : "")
    }

    /// What to send to keep it as it is: secrets blank (kept), plain values as stored, and the ones the
    /// env vars give left out, so saving doesn't copy them into Settings.
    static func kept(_ i: Wire.Integration) -> [String: String] {
        i.values.filter { !i.fromEnv.contains($0.key) }
    }

    static func icon(_ kind: Wire.IntegrationKind) -> String {
        switch kind {
        case .slack: "number"
        case .linear: "checklist"
        case .jira: "ticket"
        default: "link"
        }
    }

    static func color(_ kind: Wire.IntegrationKind) -> Color {
        switch kind {
        case .slack: .purple
        case .linear: .indigo
        case .jira: .blue
        default: .gray
        }
    }
}
