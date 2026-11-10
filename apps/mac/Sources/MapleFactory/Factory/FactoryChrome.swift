import SwiftUI

struct FactoryTopBar: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var showShare = false

    var body: some View {
        HStack(spacing: 8) {
            if state.isLoadingFactory {
                // No title or layout picker until the factory says what's there.
                EmptyView()
            } else if state.isComposing {
                composeBreadcrumb
            } else if let focused = state.focusedTask {
                focusBreadcrumb(state.task(focused))
            } else {
                switch state.destination {
                case .goal: layoutPicker
            case .inbox: title("Inbox", icon: "tray")
            case .myTasks: title("My tasks", icon: "checkmark.circle")
                case .dayReport: title("Day report", icon: "doc.text")
                case .activity: title("Activity", icon: "waveform.path.ecg")
                case .scratchpad: title("Scratchpad", icon: "note.text")
                case .usage: title("Usage", icon: "gauge.with.dots.needle.33percent")
                case .statistics: title("Statistics", icon: "chart.bar.xaxis")
                case .needsHand: title("Needs a hand", icon: "hand.raised")
                case .machines: title("Machines", icon: "cpu")
                case .intake: title("Requests", icon: "tray.and.arrow.down")
                case .allGoals: title("All goals", icon: "scope")
                case .docs, .doc: title("Docs", icon: "doc.richtext")
                case .decisions: title("Decisions", icon: "checkmark.seal")
                }
            }

            Spacer()

            if !state.isCompact {
                searchHint
            }
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus").font(.system(size: 11))
                if !state.isCompact { Text("Share") }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            )
            .contentShape(Rectangle())
            .onTapGesture { showShare.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Share")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showShare.toggle() }
            .popover(isPresented: $showShare, arrowEdge: .bottom) { SharePopover() }
            .padding(.leading, 4)
            .padding(.trailing, 6)

            AppearanceButton()
            if state.taskPanelEnabled {
                iconButton("sidebar.right", active: state.showInspector && state.focusedTask == nil)
                    .onTapGesture { state.toggleTaskPanel() }
                    .help("Toggle task panel (⌥⌘I)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Task panel")
                    .accessibilityAddTraits(.isButton)
            }

            if client.isSignedIn && !state.isLoadingFactory {
                StopTheLineButton()
            }

            // An unsent brief is waiting (MF-404): ⌘N picks it back up, so say so.
            let resumes = state.hasUnsentDraft
            HStack(spacing: 6) {
                Image(systemName: resumes ? "pencil.line" : "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                Text(resumes ? "Resume draft" : "New task")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            )
            .overlay(alignment: .topTrailing) {
                if resumes {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { state.startCompose() }
            .help(resumes ? "Resume your unsent draft (⌘N)" : "New task (⌘N)")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// Where ⌘K is, for anyone who hasn't found it.
    private var searchHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
            Text("Search")
            Text("⌘K")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke))
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textMuted)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.fill)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
        )
        .contentShape(Rectangle())
        .onTapGesture { state.togglePalette() }
        .help("Jump to a task, goal or page (⌘K)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Command menu")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.togglePalette() }
        .padding(.trailing, 6)
    }

    private func focusBreadcrumb(_ task: FactoryTask) -> some View {
        HStack(spacing: 8) {
            Button {
                state.closeFocus()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(backTitle)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The proof lightbox and the ⌘K palette own Esc while they're up.
            .keyboardShortcut(state.lightbox == nil && !state.showPalette ? .cancelAction : nil)
            .help("Back (Esc)")

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            Text(task.id)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }

    private var backTitle: String {
        switch state.destination {
        case .goal(let name): name
        case .inbox: "Inbox"
        case .myTasks: "My tasks"
        case .dayReport: "Day report"
        case .activity: "Activity"
        case .scratchpad: "Scratchpad"
        case .usage: "Usage"
        case .statistics: "Statistics"
        case .needsHand: "Needs a hand"
        case .machines: "Machines"
        case .intake: "Requests"
        case .allGoals: "All goals"
        case .docs, .doc: "Docs"
        case .decisions: "Decisions"
        }
    }

    private var composeBreadcrumb: some View {
        HStack(spacing: 8) {
            Button {
                state.cancelCompose()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    Text("Cancel")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(state.lightbox == nil && !state.showPalette ? .cancelAction : nil)

            Text("Composing in")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
            Circle().fill(FactoryData.goal(named: state.draft.goal).color).frame(width: 7, height: 7)
            Text(state.draft.goal)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: 2) {
            ForEach(GoalLayout.allCases, id: \.self) { option in
                let active = state.layout == option
                Text(option.rawValue)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textMuted)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.cardBG : .clear))
                    .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { state.layout = option }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
    }

    private func title(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.textMuted)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        }
        .font(.system(size: 13))
        .padding(.leading, 4)
    }

    private func iconButton(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(active ? Theme.text : Theme.textMuted)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.fill : .clear))
            .contentShape(Rectangle())
    }
}

struct FactoryStatusBar: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    /// Your plan account closest to its 5-hour limit (anyone's, if your machines report none).
    private var busiestAccount: UsageAccount? {
        UsageSummary.busiest(LiveAdapter.usageAccounts(machines: client.machines, members: client.members), me: client.me?.login)
    }

    /// The server dot's tooltip: what the connection is doing, in words (the dot alone is only a colour).
    static func connectionHelp(status: FactoryClient.Status, host: String?) -> String {
        let host = host.flatMap { $0.isEmpty ? nil : $0 } ?? "the factory"
        switch status {
        case .live: return "Connected to \(host). Click for machines."
        case .connecting: return "Connecting to \(host)…"
        case .reconnecting(let attempt, let reason):
            return "Reconnecting to \(host): \(reason) (attempt \(attempt)). Actions aren't sent while offline."
        case .tooNew: return "This factory is newer than the app. Update Maple Factory to keep working."
        case .signedOut: return "Not signed in."
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            if client.isSignedIn {
                HStack(spacing: 5) {
                    Circle().fill(client.status == .live ? Theme.State.merged : Theme.State.awaitingApproval).frame(width: 6, height: 6)
                    Text(client.server?.host() ?? "")
                }
                .contentShape(Rectangle())
                .onTapGesture { state.closeFocus(); state.destination = .machines }
                .help(Self.connectionHelp(status: client.status, host: client.server?.host()))
            } else {
                Circle().fill(Theme.State.merged).frame(width: 6, height: 6)
            }
            Spacer()
            if state.isLive {
                if let account = busiestAccount, let session = account.sessionWindow,
                   let text = UsageSummary.text(account, compact: state.isCompact) {
                    HStack(spacing: 5) {
                        ProductMark(product: account.product).scaleEffect(0.55).frame(width: 13, height: 13)
                        Text(text)
                    }
                    .foregroundStyle(session.used >= 0.9 ? Theme.State.cancelled : session.runsOutEarly ? Theme.State.awaitingApproval : Theme.textMuted)
                    .contentShape(Rectangle())
                    .onTapGesture { state.destination = .usage; state.focusedTask = nil }
                    .help("\(account.title): the busiest of your plan accounts. Click for all of them.")
                }
                Text(client.status == .live ? "Live" : client.status == .connecting ? "Connecting…" : client.status == .tooNew ? "Update needed" : "Reconnecting…")
            } else {
                HStack(spacing: 5) {
                    ProductMark(product: .claudeCode).scaleEffect(0.55).frame(width: 13, height: 13)
                    Text(UsageSummary.demoText(compact: state.isCompact))
                }
                .contentShape(Rectangle())
                .onTapGesture { state.destination = .usage; state.focusedTask = nil }
                .help("Usage across all accounts")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

/// The one empty state every page uses (MF-406): an icon, a title, a line of detail, and up to two ways on: an
/// accent button and a plain link. Built on `ContentUnavailableView` so it matches Docs, Decisions and Settings.
struct EmptyState: View {
    struct Action {
        let title: String
        var icon: String? = nil
        let run: () -> Void
    }

    let title: String
    let icon: String
    var detail: String? = nil
    var action: Action? = nil
    var secondary: Action? = nil

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.textFaint)
            }
        } description: {
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textMuted).frame(maxWidth: 380)
            }
        } actions: {
            if action != nil || secondary != nil {
                VStack(spacing: 8) {
                    if let action {
                        Button(action: action.run) {
                            HStack(spacing: 5) {
                                if let icon = action.icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                                Text(action.title)
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let secondary {
                        Button(action: secondary.run) {
                            Text(secondary.title).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The main window's connection pill (MF-401), worded like iOS's (MF-349): "Offline · Reconnecting…" once the feed
/// has been down a few seconds, and "Update needed" at once when the factory is newer than this build, on every page.
/// The status bar's dot is too small to notice when every button still looks live.
struct ConnectionBanner: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    /// A blip shorter than this doesn't flash the pill.
    static let delay: TimeInterval = 3

    enum Kind: Equatable { case offline, updateNeeded }

    /// What to show for this status, `since` the feed went reconnecting, at `now`; nil hides it.
    static func visible(status: FactoryClient.Status, since: Date?, now: Date) -> Kind? {
        switch status {
        case .tooNew: return .updateNeeded
        case .reconnecting:
            guard let since, now.timeIntervalSince(since) >= delay else { return nil }
            return .offline
        default: return nil
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if client.isSignedIn, let kind = Self.visible(status: client.status, since: client.reconnectingSince, now: context.date) {
                    pill(kind)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: Self.visible(status: client.status, since: client.reconnectingSince, now: context.date))
        }
    }

    private var reason: String {
        if case .reconnecting(let attempt, let reason) = client.status { return "\(reason) (attempt \(attempt)). Actions aren't sent while offline." }
        return "This factory is newer than the app. Update Maple Factory to keep working."
    }

    private func pill(_ kind: Kind) -> some View {
        let tint = kind == .offline ? Theme.State.awaitingApproval : Theme.State.cancelled
        return Button {
            state.closeFocus()
            state.destination = .machines
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind == .offline ? "wifi.slash" : "arrow.down.app").foregroundStyle(tint)
                Text(kind == .offline ? "Offline" : "Update needed").fontWeight(.semibold).foregroundStyle(tint)
                if kind == .offline {
                    Text("·").foregroundStyle(Theme.textMuted)
                    Text("Reconnecting…").foregroundStyle(Theme.textMuted)
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.editorBG))
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help(reason)
        .accessibilityIdentifier("connection.banner")
        .padding(.top, 8)
    }
}
