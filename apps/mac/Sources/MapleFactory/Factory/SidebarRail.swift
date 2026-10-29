import SwiftUI

/// The collapsed sidebar: one icon per destination, goal, person and agent, with hover tooltips.
struct SidebarRail: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    var body: some View {
        VStack(spacing: 4) {
            item(client.workspaceName, detail: "Connect to another factory") {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.card)
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
                    )
            }
            .onTapGesture { state.startOnboarding() }
            .padding(.top, 44)
            .padding(.bottom, 10)

            nav("Inbox", icon: "tray", destination: .inbox, badge: state.myInbox.count)
            nav("Requests", icon: "tray.and.arrow.down", destination: .intake, badge: state.newIntake, badgeColor: Theme.State.building)
            nav("My tasks", icon: "checkmark.circle", destination: .myTasks)
            nav("Needs a hand", icon: "hand.raised", destination: .needsHand, badge: state.handRaises.count, badgeColor: Theme.State.cancelled)
            nav("Activity", icon: "waveform.path.ecg", destination: .activity)
            nav("Scratchpad", icon: "note.text", destination: .scratchpad, detail: "\(state.notes.count) notes")
            nav("Usage", icon: "gauge.with.dots.needle.33percent", destination: .usage, detail: "34% session · 41% week")
            item("Notifications", detail: Notifier.shared.statusText,
                 dot: Notifier.shared.isSnoozed ? Theme.State.awaitingApproval : nil) {
                Menu {
                    NotificationMenu()
                } label: {
                    Image(systemName: Notifier.shared.bellIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text.opacity(0.75))
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }

            divider

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.sidebarGoals) { goal in
                        let stats = state.stats(for: goal)
                        let selected = state.destination == .goal(goal.name)
                        item(goal.name, detail: "\(stats.merged) of \(stats.total) merged", selected: selected) {
                            ProgressRing(progress: Double(stats.merged) / Double(max(stats.total, 1)), color: goal.color, size: 16)
                        }
                        .onTapGesture { state.destination = .goal(goal.name) }
                    }

                    divider

                    ForEach(FactoryData.presence, id: \.person.id) { entry in
                        let isMe = entry.person.id == FactoryData.me.id
                        item(isMe ? "\(entry.person.firstName) (you)" : entry.person.firstName,
                             detail: entry.viewing.map { "Viewing \($0)" } ?? "Online") {
                            AgentAvatar(agent: entry.person, size: 22, online: true)
                        }
                        .onTapGesture {
                            if let viewing = entry.viewing { state.selectedTask = viewing; state.showInspector = true }
                        }
                    }

                    divider

                    if client.isSignedIn {
                        ForEach(client.machines, id: \.id) { machine in
                            item(machine.name,
                                 detail: "\(machine.owner == client.me?.login ? "Yours" : machine.owner) · \(machine.online ? "\(machine.sessions.count) sessions" : "offline")",
                                 selected: state.destination == .machines && state.focusedTask == nil,
                                 dot: machine.online ? nil : Theme.State.cancelled) {
                                VStack(spacing: 4) {
                                    Image(systemName: machine.health?.battery != nil ? "laptopcomputer" : "desktopcomputer")
                                        .font(.system(size: 14))
                                        .foregroundStyle(machine.online ? Theme.text.opacity(0.75) : Theme.textFaint)
                                    LivePips(machine: machine, size: 4)
                                }
                            }
                            .onTapGesture { state.closeFocus(); state.destination = .machines }
                        }
                    } else {
                    ForEach(state.machines) { machine in
                        item(machine.id,
                             detail: "\(machine.isMine ? "Yours" : "\(machine.owner.firstName)'s") · \(machine.status.isOffline ? machine.status.title : "\(machine.sessions.count)/\(machine.capacity) busy")",
                             selected: state.destination == .machines && state.focusedTask == nil,
                             dot: machine.status.isOffline ? Theme.State.cancelled : machine.pause != nil ? Theme.State.awaitingApproval : nil) {
                            VStack(spacing: 4) {
                                Image(systemName: machine.kind.icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(machine.status == .sleeping ? Theme.textFaint : Theme.text.opacity(0.75))
                                SlotPips(machine: machine, size: 4)
                            }
                        }
                        .onTapGesture { state.closeFocus(); state.destination = .machines }
                    }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity, alignment: .top)

            item("Expand sidebar", detail: "⌃⌘S") {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }
            .onTapGesture { state.toggleSidebar() }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 22, height: 1)
            .padding(.vertical, 8)
    }

    private func nav(_ title: String, icon: String, destination: Destination, badge: Int = 0,
                     badgeColor: Color = Theme.State.awaitingApproval, detail: String? = nil) -> some View {
        let selected = state.destination == destination && state.focusedTask == nil && !state.isComposing

        return item(title, detail: detail ?? (badge > 0 ? "\(badge) waiting" : nil), selected: selected) {
            Image(systemName: selected ? "\(icon).fill" : icon)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.75))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(badgeColor))
                            .offset(x: 10, y: -8)
                    }
                }
        }
        .onTapGesture {
            state.closeFocus()
            state.destination = destination
        }
    }

    private func item<Content: View>(_ title: String, detail: String? = nil, selected: Bool = false,
                                     dot: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 40, height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.fillSelected : .clear))
            .overlay(alignment: .bottomTrailing) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Theme.sidebarBG, lineWidth: 1.5))
                        .offset(x: -6, y: -5)
                }
            }
            .contentShape(Rectangle())
            .railTooltip(title, detail: detail)
    }
}

// MARK: Tooltip

extension View {
    /// A quick tooltip that floats to the right of a rail item, instead of the slow system one.
    func railTooltip(_ title: String, detail: String? = nil) -> some View {
        modifier(RailTooltip(title: title, detail: detail))
    }
}

private struct RailTooltip: ViewModifier {
    let title: String
    let detail: String?
    @State private var hovering = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        if hovering { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.08)) { shown = false }
                }
            }
            .overlay(alignment: .leading) {
                if shown {
                    tip
                        .fixedSize()
                        .offset(x: 50)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(x: -4)))
                }
            }
    }

    private var tip: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tooltipText)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tooltipText.opacity(0.65))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.tooltipBG)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
    }
}
