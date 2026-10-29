import SwiftUI

struct FactorySidebar: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "repos"
    /// The row a dragged goal would land above, for the insertion line.
    @State private var goalDropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                WorkspaceSwitcher()
                    .contentShape(Rectangle())
                    .onTapGesture { state.startOnboarding() }
                    .help("Connect to another factory (Esc to go back)")
                NotificationBell()
            }
            .padding(.top, 48)
            .padding(.bottom, 14)

            VStack(spacing: 2) {
                navRow("Inbox", icon: "tray", destination: .inbox, badge: "\(state.myInbox.count)")
                    .contextMenu { NotificationMenu() }
                navRow("Requests", icon: "tray.and.arrow.down", destination: .intake, count: state.newIntake == 0 ? nil : "\(state.newIntake)")
                navRow("My tasks", icon: "checkmark.circle", destination: .myTasks)
                navRow("Needs a hand", icon: "hand.raised", destination: .needsHand, badge: state.handRaises.isEmpty ? nil : "\(state.handRaises.count)")
                    .contextMenu { NotificationMenu() }
                navRow("Activity", icon: "waveform.path.ecg", destination: .activity)
                navRow("Scratchpad", icon: "note.text", destination: .scratchpad, count: "\(state.notes.count)")
                navRow("Usage", icon: "gauge.with.dots.needle.33percent", destination: .usage)
                if let until = Notifier.shared.snoozedUntil, Notifier.shared.isSnoozed {
                    row(selected: false) {
                        Image(systemName: "bell.slash").font(.system(size: 11)).frame(width: 16)
                        Text("Snoozed until \(Notifier.untilText(until))")
                        Spacer()
                    }
                    .foregroundStyle(Theme.textMuted)
                    .onTapGesture { Notifier.shared.resume() }
                    .help("Resume notifications")
                }
            }

            // Goals, people and machines grow with the org; they scroll so the window never has to.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Goals") { if client.isSignedIn { state.goalSheet = .new } }
                    VStack(spacing: 2) {
                        if state.isLoadingFactory { GoalsSkeleton().frame(maxWidth: .infinity, alignment: .leading) }
                        // Only the goals you follow; the rest (and archived ones) are a click away in All goals.
                        // Drag them into your own order; a goal dropped on a row lands above it.
                        let goals = state.isLoadingFactory ? [] : state.sidebarGoals
                        ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in
                            goalRow(goal).opacity(state.isFollowing(goal) ? 1 : 0.6)
                                .draggable(goal.name) { goalRow(goal).frame(width: 200) }
                                .goalDrop(id: goal.name, target: $goalDropTarget) { dropGoal($0, at: index) }
                        }
                        if !FactoryData.goals.isEmpty {
                            row(selected: state.destination == .allGoals) {
                                Image(systemName: "square.grid.2x2").font(.system(size: 11)).frame(width: 16)
                                Text("All goals")
                                Spacer()
                            }
                            .foregroundStyle(Theme.textMuted)
                            .onTapGesture { state.destination = .allGoals }
                            .goalDrop(id: "All goals", target: $goalDropTarget) { dropGoal($0, at: goals.count) }
                        }
                        if client.isSignedIn && client.hasSnapshot && client.goals.isEmpty {
                            row(selected: false) {
                                Image(systemName: "plus.circle").font(.system(size: 12)).frame(width: 16)
                                Text("New goal")
                                Spacer()
                            }
                            .foregroundStyle(Theme.textMuted)
                            .onTapGesture { state.goalSheet = .new }
                        }
                    }

                    sectionHeader("People") { if client.isSignedIn { settingsTab = "people"; openSettings() } }
                    VStack(spacing: 2) {
                        if client.isSignedIn {
                            ForEach(client.sidebarMembers, id: \.login) { member in
                                let presence = client.online.first { $0.login == member.login }
                                personRow(LiveAdapter.person(member.login, members: client.members), viewing: presence?.viewing, online: presence != nil)
                            }
                        } else {
                            ForEach(FactoryData.presence, id: \.person.id) { entry in
                                personRow(entry.person, viewing: entry.viewing)
                            }
                        }
                    }

                    if client.isSignedIn {
                        sectionHeader("Machines") { state.closeFocus(); state.destination = .machines }
                        VStack(spacing: 2) {
                            ForEach(client.sidebarMachines, id: \.id) { machine in liveMachineRow(machine) }
                        }
                    } else {
                        sectionHeader("Machines") { state.machineSheet = .new }
                        VStack(spacing: 2) {
                            ForEach(state.machines.filter { $0.isMine || $0.teamSlots > 0 || $0.lendIdle }) { machine in machineRow(machine) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            // Pinned under the scroll area, so it's always at the very bottom while an update is in play.
            UpdateFooter()
                .animation(.easeOut(duration: 0.2), value: Updater.shared.phase.showsInFooter)
                .padding(.horizontal, -12)
        }
        .padding(.horizontal, 12)
        // A demo script's `ui:settings`: Settings opens without the menu.
        .onReceive(NotificationCenter.default.publisher(for: AppState.demoSettings)) { _ in openSettings() }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
                .onTapGesture { state.toggleSidebar() }
                .help("Collapse sidebar (⌃⌘S)")
                .padding(.top, 9)
                .padding(.trailing, 12)
        }
    }

    private func sectionHeader(_ title: String, add: (() -> Void)? = nil) -> some View {
        HStack {
            SectionLabel(title: title)
            Spacer()
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .onTapGesture { add?() }
        }
        .padding(.horizontal, 9)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private func navRow(_ title: String, icon: String, destination: Destination, badge: String? = nil, count: String? = nil) -> some View {
        row(selected: state.destination == destination) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
            Text(title)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.State.awaitingApproval)
            }
            if let count {
                Text(count)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .onTapGesture { state.destination = destination }
    }

    private func dropGoal(_ name: String, at index: Int) -> Bool {
        guard let goal = state.sidebarGoals.first(where: { $0.name == name }) else { return false }
        state.moveGoal(goal, .to(index))
        return true
    }

    private func goalRow(_ goal: Goal) -> some View {
        let stats = state.stats(for: goal)

        return row(selected: state.destination == .goal(goal.name)) {
            ProgressRing(progress: Double(stats.merged) / Double(max(stats.total, 1)), color: goal.color)
                .frame(width: 16)
            Text(goal.name)
            Spacer()
            Text("\(stats.merged)/\(stats.total)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
        }
        .onTapGesture { state.destination = .goal(goal.name) }
        .contextMenu { GoalContextMenu(goal: goal) }
    }

    private func personRow(_ person: Person, viewing: String?, online: Bool = true) -> some View {
        let isMe = person.id == FactoryData.me.id

        return row(selected: false) {
            AgentAvatar(agent: person, size: 18, online: online).frame(width: 16)
                .opacity(online ? 1 : 0.55)
            Text(isMe ? "\(person.firstName) (you)" : person.firstName)
            Spacer()
            if let viewing {
                Image(systemName: "eye")
                    .font(.system(size: 9.5))
                    .foregroundStyle(person.color)
                Text(viewing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .onTapGesture {
            if let viewing { state.openTask(viewing) }
        }
        .help(viewing.map { "\(person.firstName) is viewing \($0)" } ?? (online ? "Online" : "Offline"))
    }

    private func machineRow(_ machine: Machine) -> some View {
        row(selected: state.destination == .machines && state.focusedTask == nil) {
            Image(systemName: machine.kind.icon)
                .font(.system(size: 12))
                .foregroundStyle(machine.status.isOffline ? Theme.State.cancelled : Theme.text.opacity(0.75))
                .frame(width: 16)
            Text(machine.id)
                .lineLimit(1)
                .foregroundStyle(machine.status == .sleeping ? Theme.textMuted : Theme.text.opacity(0.8))
            if !machine.isMine {
                AgentAvatar(agent: machine.owner, size: 13)
            }
            Spacer()
            if machine.status.isOffline {
                Image(systemName: "wifi.slash").font(.system(size: 10)).foregroundStyle(Theme.State.cancelled)
            } else if machine.pause != nil {
                Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(Theme.State.awaitingApproval)
            }
            SlotPips(machine: machine, size: 6, teamOnly: !machine.isMine)
        }
        .onTapGesture { state.closeFocus(); state.destination = .machines }
        .help("\(machine.isMine ? "Your" : "\(machine.owner.firstName)'s") \(machine.model) · \(machine.status.title) · \(machine.sessions.count) of \(machine.capacity) slots busy")
    }

    private func liveMachineRow(_ machine: Wire.Machine) -> some View {
        let mine = machine.owner == client.me?.login
        let owner = LiveAdapter.person(machine.owner, members: client.members)
        return row(selected: state.destination == .machines && state.focusedTask == nil) {
            Image(systemName: machine.health?.battery != nil ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 12))
                .foregroundStyle(machine.online ? Theme.text.opacity(0.75) : Theme.State.cancelled)
                .frame(width: 16)
            Text(machine.name)
                .lineLimit(1)
                .foregroundStyle(machine.online ? Theme.text.opacity(0.8) : Theme.textMuted)
            if !mine {
                AgentAvatar(agent: owner, size: 13)
            }
            Spacer()
            if !machine.online {
                Image(systemName: "wifi.slash").font(.system(size: 10)).foregroundStyle(Theme.State.cancelled)
            }
            LivePips(machine: machine, size: 6, sharedOnly: !mine)
        }
        .onTapGesture { state.closeFocus(); state.destination = .machines }
        .help(mine ? "Yours · \(machine.online ? "\(machine.sessions.count) sessions" : "offline")"
              : "Shared by \(owner.firstName) · \(machine.online ? "\(LivePips.sharedCount(machine, tasks: client.tasks)) team slots" : "offline")")
    }

    private func agentRow(_ agent: Agent, state taskState: TaskState, task: String) -> some View {
        row(selected: false) {
            AgentAvatar(agent: agent, size: 18).frame(width: 16)
            Text(agent.name)
            Spacer()
            Circle().fill(taskState.color).frame(width: 6, height: 6)
            Text(task)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
        }
        .onTapGesture { state.openTask(task) }
    }

    private func row<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .font(Theme.uiFont)
            .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.8))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.fillSelected : .clear))
            .contentShape(Rectangle())
    }
}

/// Where an app update is, at the foot of the sidebar: checking, on offer, downloading, ready to relaunch.
/// Nothing at all while there's no update in play (up to date is a toast instead).
struct UpdateFooter: View {
    private var updater = Updater.shared

    var body: some View {
        let phase = updater.phase
        if phase.showsInFooter {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: phase.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(iconColor(phase))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phase.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if phase.isBusy {
                            HStack(spacing: 6) {
                                if let progress = phase.progress {
                                    ProgressView(value: progress)
                                    Text(phase.detail ?? "")
                                        .font(.system(size: 10.5).monospacedDigit())
                                        .foregroundStyle(Theme.textMuted)
                                        .frame(width: 30, alignment: .trailing)
                                } else {
                                    ProgressView()
                                }
                            }
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .tint(Theme.accent)
                        } else if let detail = phase.detail {
                            HStack(spacing: 0) {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(1)
                                    .help(detail)
                                if phase.showsReleaseNotesLink, let url = updater.releaseNotesURL {
                                    Text(" · ")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textMuted)
                                    Text("\(UpdatePhase.releaseNotesLinkLabel) ↗")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.accent)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .contentShape(Rectangle())
                                        .onTapGesture { NSWorkspace.shared.open(url) }
                                        .pointerStyle(.link)
                                        .help("See the release notes")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let action = phase.action, let label = phase.buttonLabel {
                            button(label, prominent: action == .install || action == .relaunch) { updater.perform(action) }
                        }
                        if phase.isDismissible {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                                .onTapGesture { updater.dismiss() }
                                .help("Not now")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func iconColor(_ phase: UpdatePhase) -> Color {
        switch phase {
        case .failed: Theme.warning
        case .available, .readyToRelaunch: Theme.accent
        default: Theme.textMuted
        }
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? Theme.accent : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(prominent ? .clear : Theme.stroke))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

private extension View {
    /// Takes a goal dragged onto this sidebar row, with an accent line above it while one hovers.
    func goalDrop(id: String, target: Binding<String?>, perform: @escaping (String) -> Bool) -> some View {
        overlay(alignment: .top) {
            if target.wrappedValue == id {
                Capsule().fill(Theme.accent).frame(height: 2).offset(y: -2).allowsHitTesting(false)
            }
        }
        .dropDestination(for: String.self) { names, _ in
            target.wrappedValue = nil
            return names.first.map(perform) ?? false
        } isTargeted: { over in
            if over { target.wrappedValue = id } else if target.wrappedValue == id { target.wrappedValue = nil }
        }
    }
}
