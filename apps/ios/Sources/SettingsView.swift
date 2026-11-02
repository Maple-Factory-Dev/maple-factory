import MapleKit
import SwiftUI

/// The iPhone screens that mirror the Mac's settings panes.
enum SettingsRoute: String, Hashable {
    case repos, people, secrets, merging

    var title: String {
        switch self {
        case .repos: "Repositories"
        case .people: "People"
        case .secrets: "Secrets"
        case .merging: "Merging"
        }
    }

    /// The Mac pane's icon and tile color.
    var icon: String {
        switch self {
        case .repos: "shippingbox"
        case .people: "person.2"
        case .secrets: "key"
        case .merging: "arrow.triangle.merge"
        }
    }

    var color: Color {
        switch self {
        case .repos: .brown
        case .people: .blue
        case .secrets: .yellow
        case .merging: .green
        }
    }
}

/// Settings, laid out like the iOS Settings app: an account header, then rows with colored icon tiles.
struct SettingsView: View {
    @Environment(FactoryStore.self) private var store

    var body: some View {
        List {
            if let me = store.feed.me {
                Section {
                    HStack(spacing: 14) {
                        Avatar(login: me.login, url: me.avatarUrl, size: 58)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.name ?? me.login).font(.title3.weight(.semibold))
                            Text("@\(me.login) · \(me.role == "admin" ? "Admin" : "Member")").font(.subheadline).foregroundStyle(.secondary)
                            Text(store.factoryName).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings-account")
                }
            }

            Section("Factory") {
                ForEach([SettingsRoute.repos, .people, .secrets, .merging], id: \.self) { route in
                    NavigationLink(value: route) {
                        SettingsRow(route.title, icon: route.icon, color: route.color, value: count(route))
                    }
                    .accessibilityIdentifier("settings-\(route.rawValue)")
                }
                NavigationLink(value: UsageRoute()) {
                    SettingsRow("Usage", icon: "gauge.with.dots.needle.33percent", color: .orange)
                }
                if store.isAdmin {
                    NavigationLink(value: StatsRoute()) { SettingsRow("Statistics", icon: "chart.bar", color: .purple) }
                }
            }

            Section("This iPhone") {
                NavigationLink(value: NotificationsRoute()) {
                    SettingsRow("Notifications", icon: "bell.badge", color: .red, value: store.pushSummary)
                }
            }

            if store.saved.count > 1 {
                Section("Switch factory") {
                    ForEach(store.saved.filter { $0.server != store.server }) { factory in
                        Button { store.switchTo(factory) } label: {
                            SettingsRow(factory.name, icon: "building.2", color: .gray, value: factory.host)
                        }
                        .tint(.primary)
                    }
                }
            }

            Section {
                if store.status == .demo {
                    Button("Leave the demo") { store.close() }
                } else {
                    Button("Sign out", role: .destructive) { store.signOut() }
                }
            } footer: {
                footer
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .repos: RepositoriesSettingsView()
            case .people: PeopleSettingsView()
            case .secrets: SecretsSettingsView()
            case .merging: MergingSettingsView()
            }
        }
        .navigationDestination(for: StatsRoute.self) { _ in StatisticsView() }
        .navigationDestination(for: UsageRoute.self) { _ in UsageView() }
        .navigationDestination(for: NotificationsRoute.self) { _ in NotificationSettingsView() }
    }

    private func count(_ route: SettingsRoute) -> String? {
        switch route {
        case .repos: store.feed.repos.isEmpty ? nil : "\(store.feed.repos.count)"
        case .people: store.feed.members.isEmpty ? nil : "\(store.feed.members.count)"
        case .secrets: store.feed.secrets.isEmpty ? nil : "\(store.feed.secrets.count)"
        case .merging: store.feed.policy.map { $0.autoMerges == false ? "Manual" : "Automatic" }
        }
    }

    private var footer: some View {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let lines = [
            store.server.map { $0.host() ?? $0.absoluteString } ?? (store.status == .demo ? "Demo factory" : nil),
            store.feed.serverVersion.map { "Server \($0)" },
            app.isEmpty ? nil : "App \(app)",
        ].compactMap { $0 }
        return Text(lines.joined(separator: " · "))
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
    }
}

/// A Settings row: a rounded colored tile with a white symbol, a title, and an optional value.
struct SettingsRow: View {
    let title: String
    let icon: String
    let color: Color
    var value: String?

    init(_ title: String, icon: String, color: Color, value: String? = nil) {
        self.title = title
        self.icon = icon
        self.color = color
        self.value = value
    }

    var body: some View {
        LabeledContent {
            if let value { Text(value) }
        } label: {
            Label { Text(title) } icon: { SettingsTile(icon: icon, color: color) }
        }
    }
}

/// The iOS Settings app's icon: a white SF Symbol on a rounded colored square.
struct SettingsTile: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
    }
}

/// The footnote a non-admin sees on a settings screen.
struct AdminOnlyNote: View {
    var text = "Only admins can change this."

    var body: some View {
        Label(text, systemImage: "lock").accessibilityIdentifier("admin-only-note")
    }
}
