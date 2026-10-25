import SwiftUI

struct FactorySidebar: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var showArchived = false
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "repos"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceSwitcher()
                .contentShape(Rectangle())
                .onTapGesture { state.startOnboarding() }
                .help("Connect to another factory")
                .padding(.top, 48)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                navRow("Inbox", icon: "tray", destination: .inbox, badge: "\(state.myInbox.count)")
                navRow("Requests", icon: "tray.and.arrow.down", destination: .intake, count: state.newIntake == 0 ? nil : "\(state.newIntake)")
                navRow("My tasks", icon: "checkmark.circle", destination: .myTasks)
                navRow("Needs a hand", icon: "hand.raised", destination: .needsHand, badge: state.handRaises.isEmpty ? nil : "\(state.handRaises.count)")
                navRow("Activity", icon: "waveform.path.ecg", destination: .activity)
                navRow("Scratchpad", icon: "note.text", destination: .scratchpad, count: "\(state.notes.count)")
                navRow("Usage", icon: "gauge.with.dots.needle.33percent", destination: .usage)
            }

            // Goals, people and machines grow with the org; they scroll so the window never has to.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Goals") { if client.isSignedIn { state.goalSheet = .new } }
                    VStack(spacing: 2) {
                        ForEach(FactoryData.activeGoals) { goal in goalRow(goal) }
                        let archived = FactoryData.goals.filter(\.archived)
                        if !archived.isEmpty {
                            row(selected: false) {
                                Image(systemName: showArchived ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 16)
                                Text("Archived")
                                Spacer()
                                Text("\(archived.count)").font(.system(size: 11).monospacedDigit())
                            }
                            .foregroundStyle(Theme.textMuted)
                            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { showArchived.toggle() } }
                            if showArchived { ForEach(archived) { goal in goalRow(goal).opacity(0.7) } }
                        }
                        if client.isSignedIn && client.goals.isEmpty {
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
                            ForEach(client.machines, id: \.id) { machine in liveMachineRow(machine) }
                        }
                    } else {
                        sectionHeader("Machines") { state.machineSheet = .new }
                        VStack(spacing: 2) {
                            ForEach(state.machines) { machine in machineRow(machine) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
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
            if let viewing { state.selectedTask = viewing; state.showInspector = true }
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
            SlotPips(machine: machine, size: 6)
        }
        .onTapGesture { state.closeFocus(); state.destination = .machines }
        .help("\(machine.isMine ? "Your" : "\(machine.owner.firstName)'s") \(machine.model) · \(machine.status.title) · \(machine.sessions.count) of \(machine.capacity) slots busy")
    }

    private func liveMachineRow(_ machine: Wire.Machine) -> some View {
        row(selected: state.destination == .machines && state.focusedTask == nil) {
            Image(systemName: machine.health?.battery != nil ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 12))
                .foregroundStyle(machine.online ? Theme.text.opacity(0.75) : Theme.State.cancelled)
                .frame(width: 16)
            Text(machine.name)
                .lineLimit(1)
                .foregroundStyle(machine.online ? Theme.text.opacity(0.8) : Theme.textMuted)
            Spacer()
            if !machine.online {
                Image(systemName: "wifi.slash").font(.system(size: 10)).foregroundStyle(Theme.State.cancelled)
            }
            LivePips(machine: machine, size: 6)
        }
        .onTapGesture { state.closeFocus(); state.destination = .machines }
        .help("\(machine.owner == client.me?.login ? "Yours" : machine.owner) · \(machine.online ? "\(machine.sessions.count) sessions" : "offline")")
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
        .onTapGesture { state.selectedTask = task; state.showInspector = true }
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
