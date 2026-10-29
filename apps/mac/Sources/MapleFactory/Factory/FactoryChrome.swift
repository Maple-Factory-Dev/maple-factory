import SwiftUI

struct FactoryTopBar: View {
    @Environment(AppState.self) private var state
    @State private var showShare = false

    var body: some View {
        HStack(spacing: 8) {
            if state.isComposing {
                composeBreadcrumb
            } else if let focused = state.focusedTask {
                focusBreadcrumb(state.task(focused))
            } else {
                switch state.destination {
                case .goal: layoutPicker
            case .inbox: title("Inbox", icon: "tray")
            case .myTasks: title("My tasks", icon: "checkmark.circle")
                case .activity: title("Activity", icon: "waveform.path.ecg")
                case .scratchpad: title("Scratchpad", icon: "note.text")
                case .usage: title("Usage", icon: "gauge.with.dots.needle.33percent")
                case .needsHand: title("Needs a hand", icon: "hand.raised")
                case .machines: title("Machines", icon: "cpu")
                case .intake: title("Requests", icon: "tray.and.arrow.down")
                case .allGoals: title("All goals", icon: "scope")
                }
            }

            Spacer()

            if !state.isCompact {
                Facepile(people: FactoryData.presence.map(\.person), size: 26)
                    .help("\(FactoryData.presence.count) people online")
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
            if !state.isCompact { iconButton("line.3.horizontal.decrease") }
            iconButton("sidebar.right", active: state.showInspector && state.focusedTask == nil)
                .onTapGesture { state.toggleTaskPanel() }
                .help("Toggle task panel (⌥⌘I)")

            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                Text("New task")
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
            .contentShape(Rectangle())
            .onTapGesture { state.startCompose() }
            .help("New task (⌘N)")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Hairline() }
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
            .keyboardShortcut(.cancelAction)
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
        case .activity: "Activity"
        case .scratchpad: "Scratchpad"
        case .usage: "Usage"
        case .needsHand: "Needs a hand"
        case .machines: "Machines"
        case .intake: "Requests"
        case .allGoals: "All goals"
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
            .keyboardShortcut(.cancelAction)

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
        let accounts = LiveAdapter.usageAccounts(machines: client.machines, members: client.members).filter { $0.sessionWindow != nil }
        let mine = accounts.filter { $0.owner?.github == client.me?.login }
        return (mine.isEmpty ? accounts : mine).max { ($0.sessionWindow?.used ?? 0) < ($1.sessionWindow?.used ?? 0) }
    }

    private func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }

    var body: some View {
        HStack(spacing: 16) {
            if client.isSignedIn {
                let online = client.machines.filter(\.online)
                let sessions = online.reduce(0) { $0 + $1.sessions.count }
                HStack(spacing: 5) {
                    Circle().fill(client.status == .live ? Theme.State.merged : Theme.State.awaitingApproval).frame(width: 6, height: 6)
                    Text(state.isCompact
                         ? "\(sessions) sessions"
                         : "\(client.server?.host() ?? "") · \(online.count) of \(client.machines.count) machines · \(sessions) sessions")
                }
                .contentShape(Rectangle())
                .onTapGesture { state.closeFocus(); state.destination = .machines }
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Theme.State.merged).frame(width: 6, height: 6)
                    Text(state.isCompact
                         ? "\(state.fleet.running) running"
                         : "\(FactoryData.presence.count) online · \(state.fleet.running) running · \(state.queue.count) queued")
                }
            }
            Spacer()
            if state.isLive {
                if let account = busiestAccount, let session = account.sessionWindow {
                    HStack(spacing: 5) {
                        ProductMark(product: account.product).scaleEffect(0.55).frame(width: 13, height: 13)
                        Text(state.isCompact
                             ? "\(percent(session.used))\(account.weekWindow.map { " · \(percent($0.used))" } ?? "")"
                             : "\(percent(session.used)) session\(account.weekWindow.map { " · \(percent($0.used)) week" } ?? "")")
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
                    Text(state.isCompact ? "34% · 41%" : "34% session · 41% week")
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

struct PlaceholderView: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.textFaint)
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
            Text("Not mocked up yet").font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
