import SwiftUI
import UniformTypeIdentifiers

/// The factory's settings (⌘,): what the org shares, what's yours, and this Mac's runner.
struct OrgSettingsView: View {
    @Environment(FactoryClient.self) private var client
    @AppStorage("settingsTab") private var tab = "repos"

    /// The Settings window's size, here and headless.
    static let size = CGSize(width: 900, height: 660)
    /// Its height: a headless run's `-height` can make it taller, to show a long pane whole.
    static var height: CGFloat { Headless.isOn ? max(size.height, AppDefaults.double(forKey: "height")) : size.height }
    /// A demo script's `ui:settings-row:<pane>`, as a click on that sidebar row would.
    static let demoPick = Notification.Name("OrgSettingsView.demoPick")

    enum Pane: String, CaseIterable {
        case general, account, appearance, repos, secrets, people, prompts, connectors, integrations, merging, scout, runner, notifications, updates

        var title: String {
            switch self {
            case .general: "General"
            case .account: "Account"
            case .appearance: "Appearance"
            case .repos: "Repositories"
            case .secrets: "Secrets"
            case .people: "People"
            case .prompts: "Prompts"
            case .connectors: "Connectors"
            case .integrations: "Integrations"
            case .merging: "Merging"
            case .scout: "Scout"
            case .runner: "Runner"
            case .notifications: "Notifications"
            case .updates: "Updates"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .account: "person.crop.circle"
            case .appearance: "paintpalette"
            case .repos: "shippingbox"
            case .secrets: "key"
            case .people: "person.2"
            case .prompts: "text.bubble"
            case .connectors: "puzzlepiece.extension"
            case .integrations: "link"
            case .merging: "arrow.triangle.merge"
            case .scout: "binoculars"
            case .runner: "laptopcomputer"
            case .notifications: "bell"
            case .updates: "arrow.down.circle"
            }
        }

        /// The sidebar tile's color behind the icon.
        var color: Color {
            switch self {
            case .general: .gray
            case .account: .blue
            case .appearance: .pink
            case .repos: .brown
            case .secrets: .yellow
            case .people: .blue
            case .prompts: .purple
            case .connectors: .indigo
            case .integrations: .orange
            case .merging: .green
            case .scout: .teal
            case .runner: .gray
            case .notifications: .red
            case .updates: .blue
            }
        }
    }

    struct SidebarGroup: Equatable {
        let title: String?
        let panes: [Pane]
    }

    /// Account is the header at the top of the sidebar; Updates is pinned to its foot.
    static let headerPane = Pane.account
    static let sidebarGroups = [
        SidebarGroup(title: nil, panes: [.general]),
        SidebarGroup(title: "Factory", panes: [.appearance, .repos, .secrets, .people, .prompts, .connectors, .integrations, .merging, .scout]),
        SidebarGroup(title: "This Mac", panes: [.runner, .notifications]),
    ]
    static let footerPane = Pane.updates
    /// Every pane the sidebar shows, top to bottom.
    static var sidebarPanes: [Pane] { [headerPane] + sidebarGroups.flatMap(\.panes) + [footerPane] }

    private var current: Pane { Pane(rawValue: tab) ?? .repos }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                switch current {
                case .general: GeneralSettings()
                case .account: AccountSettings()
                case .appearance: AppearanceSettings()
                case .repos: RepositoriesSettings()
                case .secrets: SecretsSettings()
                case .people: PeopleSettings()
                case .prompts: PromptSettings()
                case .connectors: ConnectorSettings()
                case .integrations: IntegrationSettings()
                case .merging: MergingSettings()
                case .scout: ScoutSettings()
                case .runner: RunnerSettings()
                case .notifications: NotificationSettings()
                case .updates: UpdateSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SettingsKit.paneBG)
        }
        .ignoresSafeArea()
        .background(HiddenTitleBar())
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPick)) { note in
            if let pane = (note.object as? String).flatMap(Pane.init) { tab = pane.rawValue }
        }
        .navigationTitle(current.title)
        .frame(width: Self.size.width, height: Self.height)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 40)
            accountHeader.padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Self.sidebarGroups.enumerated()), id: \.offset) { _, group in
                        if let title = group.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textFaint)
                                .padding(.leading, 8)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                        }
                        ForEach(group.panes, id: \.self) { row($0) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
            }
            .scrollIndicators(.never)
            Hairline().padding(.horizontal, 20)
            row(Self.footerPane).padding(12)
        }
        .frame(width: 232)
        .background(SettingsKit.sidebarBG)
    }

    /// Who's signed in and to which factory; a click opens Account.
    private var accountHeader: some View {
        Button { tab = Self.headerPane.rawValue } label: {
            HStack(spacing: 10) {
                if let me = client.me {
                    AgentAvatar(agent: LiveAdapter.person(me.login, members: client.members), size: 34)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.gray.gradient))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.me.map { $0.name ?? "@\($0.login)" } ?? "Not signed in")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(client.workspaceName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9).fill(current == Self.headerPane ? Self.selection : .clear))
        }
        .buttonStyle(.plain)
        .help(client.me.map { "@\($0.login) · \(client.workspaceName)" } ?? "Account")
    }

    private static let selection = Color(light: .black.opacity(0.08), dark: .white.opacity(0.1))

    private func row(_ pane: Pane) -> some View {
        Button { tab = pane.rawValue } label: {
            HStack(spacing: 9) {
                SettingsTile(icon: pane.icon, color: pane.color)
                Text(pane.title).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if pane == .runner, let machine = client.thisMac {
                    Circle().fill(machine.online ? Theme.State.merged : Theme.textFaint).frame(width: 6, height: 6)
                        .help(machine.online ? "Online" : "Offline")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(current == pane ? Self.selection : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// The Settings window without a title bar: the sidebar runs up under the traffic lights.
private struct HiddenTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = nil
        }
    }
}

/// How the app behaves on this Mac: what clicking a task opens, and what the Dock shows.
struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @AppStorage(DockIcon.settingKey) private var dockShowsFactoryIcon = true

    var body: some View {
        @Bindable var state = state
        SettingsPane("General", subtitle: "How Maple Factory behaves on this Mac.") {
            SettingsSection("Tasks", caption: "The task panel button in the toolbar (⌥⌘I) appears only with Peek in the side panel.") {
                SettingsPicker("When you click a task", selection: $state.taskOpening) {
                    ForEach(AppState.TaskOpening.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            SettingsSection("Dock") {
                SettingsToggle("Show the factory's icon in the Dock",
                               detail: "When the factory you're in has an icon (Settings › Appearance), the Dock shows it; switching factories changes it. Off, or for a factory without one, the Dock shows Maple's.",
                               isOn: $dockShowsFactoryIcon)
            }
            SettingsSection("Privacy") {
                SettingsToggle("Send crash and error reports",
                               detail: "Crashes and errors go to Maple Factory's Sentry project with the app's version and your factory's org. Never what you typed, your GitHub account, screenshots or network requests.",
                               isOn: sendsErrorReports)
                    .disabled(ErrorReports.forcedOff || Self.debugBuild)
                if ErrorReports.forcedOff {
                    SettingsNote("Off: MAPLE_TELEMETRY=off is set in this app's environment.")
                } else if Self.debugBuild {
                    SettingsNote("This debug build never sends reports.", systemImage: "hammer")
                }
                SettingsBlock {
                    Link("What's sent, and what never is", destination: URL(string: "https://maplefactory.dev/security#errors")!)
                        .font(.system(size: 12))
                }
            }
        }
    }

    @State private var sendsErrorReportsValue = ErrorReports.enabled
    private var sendsErrorReports: Binding<Bool> {
        Binding(get: { sendsErrorReportsValue && !ErrorReports.forcedOff }, set: { sendsErrorReportsValue = $0; ErrorReports.enabled = $0 })
    }

    #if DEBUG
    private static let debugBuild = true
    #else
    private static let debugBuild = false
    #endif
}

/// A pane with nothing to show until there's a factory.
struct SettingsUnavailable: View {
    var title = "Not connected"
    var systemImage = "network.slash"
    let detail: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

/// Which factory this app is signed in to, and as whom.
struct AccountSettings: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    var body: some View {
        SettingsPane("Account", subtitle: "The factory this app is connected to. Switch or add factories from the factory menu at the top of the sidebar.") {
            if let me = client.me, let server = client.server {
                SettingsSection {
                    SettingsBlock {
                        HStack(spacing: 12) {
                            AgentAvatar(agent: LiveAdapter.person(me.login, members: client.members), size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.name ?? me.login).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("@\(me.login) · \(me.role.capitalized)").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
                SettingsSection("Factory") {
                    SettingsValueRow("Name", value: client.workspaceName)
                    SettingsValueRow("Address", value: server.absoluteString)
                    SettingsValueRow("Status", value: client.status == .live ? "Connected" : client.status == .tooNew ? "Update needed" : "Reconnecting…")
                    if let version = client.serverVersion { SettingsValueRow("Server", value: "maple-server \(version)") }
                    if let update = client.serverUpdate {
                        SettingsBlock(spacing: 4) {
                            Label("maple-server \(update.version) is out", systemImage: "arrow.down.circle")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.State.awaitingApproval)
                            Text(LocalizedStringKey(update.how)).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
                SettingsSection {
                    SettingsButtonRow("Signed in to \(client.workspaceName)", button: "Sign Out of \(client.workspaceName)", role: .destructive) { state.signOut() }
                }
            } else {
                SettingsUnavailable(detail: "Add a factory from the factory menu at the top of the sidebar.")
            }
        }
    }
}

/// The factory's name and icon, for everyone in it: the sidebar, the factory menu and the Dock. Admins
/// change them; everyone else sees them with the lock note.
struct AppearanceSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var busy = false
    @State private var problem: String?
    @State private var targeted = false

    private var isAdmin: Bool { client.isAdmin }
    /// A demo script's `icon:<file>` (or `icon:remove`), as Choose Image… or Remove would.
    static let demoPick = Notification.Name("AppearanceSettings.demoPick")

    var body: some View {
        SettingsPane("Appearance", subtitle: "The factory's name and icon, for everyone in it: at the top of the sidebar, in the factory menu, and (the icon) in the Dock on each Mac that shows it (Settings › General).") {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory to see its name and icon.")
            } else {
                FactoryNameCard()
                SettingsSection("Icon", caption: isAdmin
                                ? "Choose an image or drop one on the preview. A square image of at least 512 × 512 px looks best: PNG, JPEG or WebP, up to 2 MB."
                                : "A square image of at least 512 × 512 px looks best: PNG, JPEG or WebP, up to 2 MB.") {
                    SettingsBlock { preview }
                    if isAdmin {
                        SettingsRow("Factory icon", detail: problem, detailColor: Theme.State.cancelled) {
                            Button("Remove", role: .destructive) { remove() }.disabled(busy || client.iconLink == nil)
                            Button("Choose Image…") { choose() }.disabled(busy)
                        }
                    } else {
                        SettingsNote("Only admins can change this.")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPick)) { note in
            guard isAdmin, let path = note.object as? String else { return }
            if path == "remove" { remove() } else { upload(URL(fileURLWithPath: path)) }
        }
    }

    /// The icon where people see it: the sidebar and the Dock. Admins drop an image on it.
    private var preview: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    FactoryIcon(name: client.workspaceName, image: client.icon, size: 22)
                    Text(client.workspaceName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(width: 200, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(SettingsKit.sidebarBG))
                Text("Sidebar").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            VStack(spacing: 8) {
                Image(nsImage: client.icon.map(MapleIcon.dockImage) ?? MapleIcon.dockImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Dock").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Theme.accent : Theme.stroke, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: isAdmin ? [5, 4] : []))
        )
        .overlay { if busy { ProgressView().controlSize(.small) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard isAdmin, let url = urls.first else { return false }
            upload(url)
            return true
        } isTargeted: { targeted = isAdmin && $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the factory's icon: a square image of at least 512 × 512 px."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        upload(url)
    }

    private func upload(_ url: URL) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try Data(contentsOf: url)
                guard NSImage(data: data) != nil else { throw FactoryClient.ClientError.message("That isn't an image.") }
                try await client.upload(iconData: data)
            } catch {
                problem = FactoryClient.describe(error)
            }
        }
    }

    private func remove() {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await client.removeIcon() } catch { problem = FactoryClient.describe(error) }
        }
    }
}

/// The factory's name: what an admin calls it in place of the GitHub org. Blank, or Use Org Name, goes back to the org's.
struct FactoryNameCard: View {
    @Environment(FactoryClient.self) private var client
    @State private var draft = ""
    @State private var busy = false
    @State private var problem: String?

    private var isAdmin: Bool { client.isAdmin }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unchanged: Bool { trimmed == (client.displayName ?? "") }
    /// A demo script's `name:<text>` (typed in, then Save) or `name:clear` (Use Org Name).
    static let demo = Notification.Name("FactoryNameCard.demo")

    var body: some View {
        SettingsSection("Name", caption: trimmed.count > FactoryClient.maxName ? nil : "Shown instead of \(client.orgName). Leave it blank to use the org's name.") {
            SettingsRow("Factory name") {
                TextField(client.orgName, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .disabled(!isAdmin || busy)
                    .onSubmit(save)
                if isAdmin {
                    Button("Save") { save() }.disabled(busy || unchanged || trimmed.count > FactoryClient.maxName)
                }
            }
            if trimmed.count > FactoryClient.maxName {
                SettingsNote("The name can be up to \(FactoryClient.maxName) characters.", systemImage: "exclamationmark.triangle", color: Theme.State.cancelled)
            }
            if isAdmin {
                SettingsButtonRow("GitHub organization", value: client.orgName, button: "Use Org Name", disabled: busy || client.displayName == nil) { clear() }
                if let problem {
                    SettingsNote(problem, systemImage: "exclamationmark.triangle", color: Theme.State.cancelled)
                }
            } else {
                SettingsNote("Only admins can change this.")
            }
        }
        .onAppear { draft = client.displayName ?? "" }
        // Someone else renamed it (name.updated): show theirs.
        .onChange(of: client.displayName) { _, name in draft = name ?? "" }
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            guard isAdmin, let text = note.object as? String else { return }
            if text == "clear" { return clear() }
            Task {
                draft = ""
                for character in text {
                    draft.append(character)
                    try? await Task.sleep(for: .milliseconds(45))
                }
                save()
            }
        }
    }

    private func save() {
        guard isAdmin, !unchanged, trimmed.count <= FactoryClient.maxName else { return }
        run { try await client.setName(trimmed) }
    }

    private func clear() {
        draft = ""
        run { try await client.clearName() }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { problem = FactoryClient.describe(error) }
        }
    }
}

/// This Mac's banners for tasks that need you.
struct NotificationSettings: View {
    @Bindable private var notifier = Notifier.shared

    var body: some View {
        SettingsPane("Notifications", subtitle: "A banner when a task newly needs you (a raised hand, a question, a plan to approve or a PR to review) while Maple Factory is in the background. Snooze them from the bell in the sidebar.") {
            SettingsSection("Banners") {
                SettingsToggle("Notifications", isOn: $notifier.enabled)
                if notifier.isSnoozed {
                    SettingsButtonRow("Status", value: notifier.statusText, button: "Resume Notifications") { notifier.resume() }
                } else {
                    SettingsValueRow("Status", value: notifier.statusText)
                }
            }
            if notifier.denied {
                SettingsSection("macOS") {
                    SettingsButtonRow("macOS isn't letting Maple Factory show notifications.", button: "Open System Settings") { notifier.openSystemSettings() }
                }
            }
        }
        .task { await notifier.refreshPermission() }
    }
}

/// The app's own updates: which releases it takes, and checking now.
struct UpdateSettings: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        SettingsPane("Updates", subtitle: "Maple Factory updates itself from maplefactory.dev. Runners and the factory's server update on their own.") {
            SettingsSection("Maple Factory", caption: updater.available ? nil : "This build doesn't update itself (it isn't a release build).") {
                SettingsValueRow("Version", value: updater.version)
                SettingsButtonRow("Check for updates", value: updater.available ? status : nil, button: "Check Now", disabled: !updater.canCheck) {
                    updater.checkForUpdates()
                }
            }
            SettingsSection("Releases", caption: updater.channel == .beta
                            ? "Beta gets prereleases as well as releases. Going back to Stable keeps the beta you have until a release passes it."
                            : nil) {
                SettingsToggle("Check for updates automatically", isOn: $updater.automaticChecks)
                SettingsPicker("Channel", selection: $updater.channel) {
                    ForEach(Updater.Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .disabled(!updater.available)
        }
    }

    private var status: String {
        switch updater.result {
        case .some(.some(let version)): return "\(version) is available"
        case .some(.none): return "Up to date"
        case .none: return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        }
    }
}

/// Settings › Runner's answer to Check for Update, inline under This Mac.
struct RunnerCheckRow: View {
    let check: RunnerCheck
    let machine: Wire.Machine

    var body: some View {
        switch check {
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for a runner update…")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowPadding()
        case .answered(let text, _):
            if text.hasSuffix(" is available for \(machine.name).") {
                SettingsNote(text, systemImage: "arrow.down.circle", color: Theme.State.awaitingApproval)
            } else if text.contains(" is on the latest runner (") {
                SettingsNote(text, systemImage: "checkmark.circle", color: Theme.State.merged)
            } else {
                SettingsNote(text, systemImage: "exclamationmark.triangle", color: Theme.State.cancelled)
            }
        case .noAnswer:
            SettingsNote("The factory didn't answer the check. Try again in a moment.", systemImage: "exclamationmark.triangle", color: Theme.State.cancelled)
        }
    }
}

/// This Mac's runner: whether it's in the factory, its version, and how much work it takes.
struct RunnerSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding: String?
    @State private var error: String?
    @State private var nickname = ""
    @State private var showingChanges = false

    /// Available but not asked for: the header says so, without a row of its own.
    private static func outdatedOnly(_ phase: RunnerUpdatePhase) -> Bool {
        if case .outdated = phase { true } else { false }
    }

    private func rename(_ machine: Wire.Machine) {
        client.send(.machineRename(.init(machine: machine.id, name: nickname)))
    }

    var body: some View {
        SettingsPane("Runner", subtitle: "This Mac runs factory sessions in the background, starting at login. These settings are the same ones as on Machines.") {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory first.")
            } else if let machine = client.thisMac {
                SettingsSection("This Mac") {
                    SettingsBlock {
                        HStack(spacing: 10) {
                            SettingsTile(icon: "laptopcomputer", color: .gray, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                                HStack(spacing: 5) {
                                    Circle().fill(machine.online ? Theme.State.merged : Theme.textFaint).frame(width: 6, height: 6)
                                    Text(machine.online ? "Online" : "Offline")
                                    if let version = machine.version { Text("· runner \(version)") }
                                    Text("·")
                                    Button("What's New") { showingChanges = true }
                                        .buttonStyle(.link)
                                        .disabled(client.runnerReleases.isEmpty)
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            let action = client.runnerAction(machine)
                            Button(action == .check ? "Check for Update" : "Update") {
                                // An Update starts afresh: the check's "available" has done its job.
                                if action != .check { client.clearRunnerCheck(machine.id) }
                                client.perform(action, on: machine)
                            }
                            .disabled((action != .check && !machine.online) || client.updatePhase(machine).isBusy
                                      || client.runnerChecks[machine.id]?.isPending == true)
                            Button("Show Log") {
                                NSWorkspace.shared.open(LocalRunner.logFile)
                            }
                        }
                    }
                    // Its progress and how it ended; Settings has its own Update and Show Log beside it.
                    // An update under way comes first; then what Check for Update found, which stands in for
                    // the plain "is available" note and an earlier update's ending.
                    if case let phase = client.updatePhase(machine), phase.isBusy {
                        SettingsBlock { RunnerUpdateRow(machine: machine, canUpdate: false) { showingChanges = true } }
                    } else if let check = client.runnerChecks[machine.id] {
                        RunnerCheckRow(check: check, machine: machine)
                    } else if case let phase = client.updatePhase(machine), phase != .current, !Self.outdatedOnly(phase) {
                        SettingsBlock { RunnerUpdateRow(machine: machine, canUpdate: false) { showingChanges = true } }
                    } else if client.runnerOutdated(machine), let latest = client.runnerLatest {
                        SettingsNote("Runner \(latest) is available.", systemImage: "arrow.down.circle", color: Theme.State.awaitingApproval)
                    }
                    SettingsRow("Name", detail: "What everyone sees for this Mac on Machines, tasks and the sidebar. Leave it empty to use \(machine.id).") {
                        TextField(machine.id, text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { rename(machine) }
                        Button("Rename") { rename(machine) }
                            .disabled(nickname.trimmingCharacters(in: .whitespaces) == machine.name)
                    }
                }
                .runnerChanges(machine, isPresented: $showingChanges)
                .onAppear { nickname = machine.name == machine.id ? "" : machine.name }
                .onDisappear { client.clearRunnerCheck(machine.id) }
                MachineSettingsSheet(machine: machine, embedded: true)
                    .id(machine.id)
            } else if LocalRunner.enrolled != nil {
                SettingsSection {
                    SettingsRow("This Mac is enrolled with another factory (\(LocalRunner.enrolled?.url ?? "")), or it was removed from this one.")
                }
            } else {
                SettingsSection("This Mac") {
                    SettingsRow("This Mac isn't a factory machine", detail: adding ?? "Add it to run agents here, starting at login. No Homebrew needed.") {
                        Button("Add This Mac", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(adding != nil || LocalRunner.helpers == nil)
                    }
                    if let error {
                        SettingsNote(error, systemImage: "exclamationmark.triangle", color: Theme.State.cancelled)
                    }
                }
            }
        }
    }

    private func add() {
        guard let server = client.server else { return }
        adding = "Getting a code…"
        error = nil
        Task {
            do {
                let code = try await client.enrollment().code
                try await LocalRunner.addThisMac(server: server, code: code) { adding = "\($0)…" }
                adding = "Added. It shows up here in a moment."
            } catch {
                adding = nil
                self.error = FactoryClient.describe(error)
            }
        }
    }
}

/// Who's an admin of this factory: GitHub's org owners, and anyone an admin made one here. Admins make
/// and remove the factory's own; GitHub owners stay admins until GitHub says otherwise.
struct FactoryAdminsCard: View {
    @Environment(FactoryClient.self) private var client
    /// A demo script's `admin:grant:<login>` (or `admin:revoke:<login>`), as that row's button would.
    static let demo = Notification.Name("FactoryAdminsCard.demo")

    var body: some View {
        SettingsSection("Factory admins", caption: "Admins change the factory's settings, secrets and prompts. Owners of the GitHub organization always are; an admin can make anyone else who has signed in one too, or revoke their access, which signs them out everywhere at once.") {
            ForEach(client.members, id: \.login) { member in row(member) }
            if !client.isAdmin {
                SettingsNote("Only admins can change who's an admin.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            guard client.isAdmin, let login = note.userInfo?["login"] as? String else { return }
            if note.userInfo?["action"] as? String == "revoke" { client.revokeAdmin(login) } else { client.grantAdmin(login) }
        }
    }

    private func row(_ member: Wire.Member) -> some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: LiveAdapter.person(member.login, members: client.members), size: 20)
            Text(member.name ?? member.login).foregroundStyle(Theme.text).lineLimit(1)
            Text(member.login == client.me?.login ? "@\(member.login) (you)" : "@\(member.login)").foregroundStyle(Theme.textMuted).lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.badge(member))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(member.role == "admin" ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(Theme.fill))
            if client.isAdmin && member.adminSource != "github" && member.login != client.me?.login {
                if member.role == "admin" {
                    Button("Remove admin") { client.revokeAdmin(member.login) }.controlSize(.small)
                } else {
                    Button("Make admin") { client.grantAdmin(member.login) }.controlSize(.small)
                }
                Button("Revoke access") { client.revokeAccess(member.login) }
                    .controlSize(.small)
                    .help("Signs \(member.login) out of every app and browser now and closes their terminals. They can sign in again while GitHub lets them.")
            }
        }
        .font(.system(size: 12.5))
        .settingsRowPadding()
    }

    /// GitHub owner, Admin · added by @x, or Member.
    static func badge(_ member: Wire.Member) -> String {
        guard member.role == "admin" else { return "Member" }
        if member.adminSource == "granted" { return member.adminGrantedBy.map { "Admin · added by @\($0)" } ?? "Admin" }
        // An older server doesn't say why; then GitHub is the only way to be one.
        return "GitHub owner"
    }
}

/// What the org adds to every planning, building and review session's prompt. Admins edit it; a goal
/// can add its own on top (the goal editor's Agent instructions).
struct PromptSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var draft = LiveAdapter.noPrompts
    @State private var saved = false

    private var isAdmin: Bool { client.me?.role == "admin" }
    private var current: Wire.PromptAdditions { client.prompts ?? LiveAdapter.noPrompts }

    var body: some View {
        SettingsPane("Prompts", subtitle: "Added to every factory session's prompt for its role, after the task's brief. A goal's own instructions come after these.") {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory to see its prompts.")
            } else {
                ForEach(PromptFields.roles, id: \.label) { role in
                    SettingsSection(role.label, caption: role.hint) {
                        SettingsBlock {
                            PromptEditor(hint: role.hint, text: $draft[dynamicMember: role.key], editable: isAdmin, height: 96, boxed: false)
                        }
                    }
                }
                HStack {
                    if !isAdmin {
                        Label("Only admins can change these", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    } else if saved && draft == current {
                        Text("Saved").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    if isAdmin {
                        Button("Revert") { draft = current }.disabled(draft == current)
                        Button("Save") {
                            client.save(prompts: draft)
                            saved = true
                        }
                        .keyboardShortcut("s")
                        .disabled(draft == current)
                    }
                }
            }
        }
        .onAppear { draft = current }
        // Another admin's save, or the server's trimmed echo of ours.
        .onChange(of: client.prompts) { _, new in draft = new ?? LiveAdapter.noPrompts }
    }
}

/// Whether approved changes merge on their own, and what the factory does when one won't merge. Org-wide, on the risk policy; admins change it.
struct MergingSettings: View {
    @Environment(FactoryClient.self) private var client

    private var isAdmin: Bool { client.me?.role == "admin" }

    var body: some View {
        SettingsPane("Merging", subtitle: "What happens after a change is approved, for everyone in the factory.") {
            if !client.isSignedIn || client.riskPolicy == nil {
                SettingsUnavailable(detail: "Connect to a factory to see how it merges.")
            } else {
                SettingsSection("After approval") {
                    SettingsToggle("Merge approved changes automatically",
                                   detail: "When a change is proven, reviewed and its checks pass, the factory merges it if its risk level (or its goal's accepted risk) allows. Off: nothing merges on its own; ready changes wait in Pending merge until someone clicks Merge.",
                                   isOn: policy(\.autoMerges))
                    SettingsToggle("Fix merges automatically",
                                   detail: "When an approved change won't merge into its base, a builder brings the branch up to date, resolves the conflicts and pushes, and review runs again. It tries twice before asking you. Off: the factory raises its hand and you pick what to do.",
                                   isOn: policy(\.autoFixMerges))
                    if !isAdmin {
                        SettingsNote("Only admins can change this.")
                    }
                }
                .disabled(!isAdmin)
            }
        }
    }

    /// One of the risk policy's switches, saved as it flips.
    private func policy(_ key: WritableKeyPath<RiskPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { client.riskPolicy?[keyPath: key] ?? true },
            set: { on in
                guard var policy = client.riskPolicy else { return }
                policy[keyPath: key] = on
                client.save(policy: policy)
            }
        )
    }
}

/// How much one Scout run picks up from a goal's leftovers. Org-wide, on the risk policy; admins change it.
struct ScoutSettings: View {
    @Environment(FactoryClient.self) private var client

    private var isAdmin: Bool { client.me?.role == "admin" }

    private var items: Binding<Int> {
        Binding(
            get: { client.riskPolicy?.scoutItems ?? 3 },
            set: { n in
                guard var policy = client.riskPolicy else { return }
                policy.scoutItems = n
                client.save(policy: policy)
            }
        )
    }

    var body: some View {
        SettingsPane("Scout", subtitle: "Scout, on a goal's header, looks over the goal's leftovers (backlog tasks and review findings its merged tasks left open) and drafts plans for the ones still worth doing.") {
            if !client.isSignedIn || client.riskPolicy == nil {
                SettingsUnavailable(detail: "Connect to a factory to see its Scout settings.")
            } else {
                SettingsSection("Scout runs") {
                    SettingsRow("Items per Scout run", detail: "The most leftovers one run turns into drafted plans waiting for approval.") {
                        Stepper(value: items, in: 1...10) {
                            Text("\(items.wrappedValue)").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    if !isAdmin {
                        SettingsNote("Only admins can change this.")
                    }
                }
                .disabled(!isAdmin)
            }
        }
    }
}

/// Planning, Building and Review prompt additions, each a labelled multi-line editor.
struct PromptFields: View {
    @Binding var prompts: Wire.PromptAdditions
    var editable = true
    var height: CGFloat = 64

    static let roles: [(label: String, hint: String, key: WritableKeyPath<Wire.PromptAdditions, String>)] = [
        ("Planning", "How the planner should plan: conventions, what a plan must cover.", \.planner),
        ("Building", "What the builder must do: test commands, style, what not to touch.", \.builder),
        ("Review", "What the review agent should check for.", \.reviewer),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.roles, id: \.label) { role in
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                    PromptEditor(hint: role.hint, text: $prompts[dynamicMember: role.key], editable: editable, height: height)
                }
            }
        }
    }
}

/// One role's prompt addition: a multi-line editor, with its count near the limit.
struct PromptEditor: View {
    let hint: String
    @Binding var text: String
    var editable = true
    var height: CGFloat = 64
    /// Its own rounded box; off inside a Settings group, which is the box.
    var boxed = true

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .disabled(!editable)
            .opacity(editable ? 1 : 0.75)
            .padding(boxed ? 6 : 0)
            .frame(height: height)
            .background {
                if boxed { RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)) }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(editable ? hint : "None").font(.system(size: 12.5)).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, boxed ? 11 : 5).padding(.vertical, boxed ? 6 : 0).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if text.count > 3500 {
                    Text("\(text.count) / 4000").font(.system(size: 11)).foregroundStyle(text.count > 4000 ? Theme.State.awaitingApproval : Theme.textFaint)
                        .padding(6)
                }
            }
    }
}

/// The repos goals can work in: the ones the GitHub App is installed on, and any an admin adds.
/// Clicking one opens its worktree scripts (`RepoScriptsDetail`).
struct RepositoriesSettings: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding = ""
    @State private var refreshing = false
    @State private var filter = ""
    /// The repo whose detail is open (`-reposSelected owner/name` opens one at launch).
    @AppStorage("reposSelected") private var selected = ""

    private var isAdmin: Bool { client.me?.role == "admin" }
    private var selectedRepo: Wire.OrgRepo? {
        selected.isEmpty || !client.isSignedIn ? nil : client.repos.first { $0.name.lowercased() == selected.lowercased() }
    }

    var body: some View {
        if let repo = selectedRepo {
            RepoScriptsDetail(repo: repo) { selected = "" }
        } else {
            list
        }
    }

    private var list: some View {
        SettingsPane("Repositories",
                     subtitle: "The ones the GitHub App is installed on come from GitHub: grant or remove its access there. Goals pick from these. Click one for its worktree scripts.",
                     accessory: AnyView(refresh)) {
            if !client.isSignedIn {
                SettingsUnavailable(detail: "Connect to a factory to see its repositories.")
            } else {
                SettingsSection(client.repos.isEmpty ? "Repositories" : "\(client.repos.count) repositories",
                                accessory: client.repos.isEmpty ? nil : AnyView(RepoList.SearchField(query: $filter, count: client.repos.count).frame(width: 240))) {
                    if client.repos.isEmpty {
                        SettingsRow("No repositories yet", detail: isAdmin ? "Install the GitHub App on your org, or add one below." : "An admin installs the GitHub App on the org, or adds them here.")
                    }
                    ForEach(RepoList.entries(client.repos, query: filter), id: \.self) { entry in
                        switch entry {
                        case .owner(let owner): RepoList.OwnerHeader(owner: owner).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                        case .noMatches(let query): RepoList.NoMatches(query: query).settingsRowPadding()
                        case .repo(let repo): row(repo)
                        }
                    }
                    if isAdmin {
                        SettingsRow("Add a repository") {
                            TextField("owner/name, or its GitHub URL", text: $adding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit(add)
                            Button("Add", action: add)
                                .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if client.githubApp != nil || !client.repoOwners.isEmpty {
                    OtherGitHubAccounts()
                }
            }
        }
    }

    private var refresh: some View {
        Button {
            refreshing = true
            client.send(.reposRefresh)
            Task { try? await Task.sleep(for: .seconds(1.5)); refreshing = false }
        } label: {
            Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(!client.isSignedIn || refreshing)
    }

    private func row(_ repo: Wire.OrgRepo) -> some View {
        RepoList.Row(repo: repo) {
            EmptyView()
        } trailing: {
            if client.scripts(for: repo.name) != nil {
                Text("scripts")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.fill))
                    .help("Has worktree scripts")
            }
            Text(repo.source == .github ? "GitHub App" : "Added by hand")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            if repo.source == .manual && isAdmin {
                Button {
                    client.send(.reposRemove(.init(name: repo.name)))
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(repo.name)")
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textFaint)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
        .onTapGesture { selected = repo.name }
        .help("Open \(repo.name)'s worktree scripts")
    }

    private func add() {
        let name = adding.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        client.send(.reposAdd(.init(name: name)))
        adding = ""
    }
}

/// Repos from GitHub accounts besides the factory's own: the app has to be public to be installed there,
/// and an admin approves each account, or its installation adds nothing (anyone can install a public app).
struct OtherGitHubAccounts: View {
    @Environment(FactoryClient.self) private var client
    @State private var adding = ""

    private var isAdmin: Bool { client.me?.role == "admin" }

    var body: some View {
        SettingsSection("Other GitHub accounts", caption: "Repos in another org (or someone's own account) come in once an admin approves it here and the GitHub App is installed there.") {
            if client.repoOwners.isEmpty {
                SettingsRow("None yet", detail: "Only \(client.org.isEmpty ? "the factory's own account" : client.org)'s installations add repos.")
            }
            ForEach(client.repoOwners, id: \.self) { owner in
                HStack(spacing: 8) {
                    Image(systemName: "building.2").foregroundStyle(Theme.textMuted).frame(width: 16)
                    Text(owner).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                    let count = client.repos.filter { $0.source == .github && $0.name.lowercased().hasPrefix(owner.lowercased() + "/") }.count
                    Text(count == 1 ? "1 repo" : "\(count) repos")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    Spacer()
                    if isAdmin {
                        Button {
                            client.setRepoOwners(client.repoOwners.filter { $0 != owner })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop adding \(owner)'s repos")
                    }
                }
                .settingsRowPadding()
            }
            if isAdmin {
                SettingsRow("Approve an account") {
                    TextField("An org or account's GitHub login", text: $adding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(approve)
                    Button("Approve", action: approve)
                        .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let app = client.githubApp {
                step(1, "Make the app public", "Once, in the app's Advanced settings on GitHub: GitHub only installs a private app on the account that owns it.",
                     link: app.settingsUrl, button: "Open \(app.slug)'s settings")
                step(2, "Install it on the org", "Pick the org and its repos, then Refresh above.",
                     link: app.installUrl, button: "Install on GitHub")
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, link: String, button: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.fill))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let url = URL(string: link) {
                Link(button, destination: url).font(.system(size: 12))
            }
        }
        .settingsRowPadding()
    }

    private func approve() {
        let login = adding.trimmingCharacters(in: .whitespaces)
        guard !login.isEmpty else { return }
        if !client.repoOwners.contains(where: { $0.lowercased() == login.lowercased() }) {
            client.setRepoOwners(client.repoOwners + [login])
        }
        adding = ""
    }
}

/// Who shows in this person's sidebar: a few teammates, not the whole org.
struct PeopleSettings: View {
    @Environment(FactoryClient.self) private var client

    var body: some View {
        SettingsPane("People", subtitle: "Who runs the factory, and who shows in your sidebar.") {
            if client.isSignedIn { FactoryAdminsCard() }
            let others = client.members.filter { $0.login != client.me?.login }
            SettingsSection("People in your sidebar",
                            caption: client.sidebarPicks == nil
                                ? "Until you pick, it shows people on your GitHub teams. Pick the ones you work with; only you see this."
                                : "Only you see this. Everyone in the org can still be mentioned and assigned.",
                            accessory: client.sidebarPicks != nil ? AnyView(Button("Go back to my teams") { client.sidebarPicks = nil }) : nil) {
                if others.isEmpty {
                    SettingsRow("Just you so far", detail: "Members of the org show up here once they sign in.")
                }
                ForEach(others, id: \.login) { member in
                    let shown = client.sidebarMembers.contains { $0.login == member.login }
                    HStack(spacing: 8) {
                        AgentAvatar(agent: LiveAdapter.person(member.login, members: client.members), size: 22)
                        Text(member.name ?? member.login).foregroundStyle(Theme.text).lineLimit(1)
                        Text("@\(member.login)").foregroundStyle(Theme.textMuted).lineLimit(1)
                        if !member.teams.isEmpty {
                            Text(member.teams.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Toggle("Show \(member.name ?? member.login)", isOn: Binding(get: { shown }, set: { on in
                            let current = client.sidebarMembers.map(\.login).filter { $0 != client.me?.login }
                            client.sidebarPicks = on ? current + [member.login] : current.filter { $0 != member.login }
                        }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    .font(.system(size: 13))
                    .settingsRowPadding()
                }
            }
        }
    }
}
