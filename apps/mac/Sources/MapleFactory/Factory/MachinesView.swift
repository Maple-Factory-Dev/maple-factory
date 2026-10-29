import SwiftUI

/// Everyone's machines, what each slot is running, how much each person shares with the team,
/// and the queue of approved work waiting for a slot.
struct MachinesView: View {
    @Environment(AppState.self) private var state

    private var narrow: Bool { state.contentWidth < 960 }

    var body: some View {
        let fleet = state.fleet

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Machines")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            Text("Add this Mac")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.fill)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { state.machineSheet = .new }
                    }
                    Text("Agents run on your own computers, and every machine runs its owner's tasks first. Owners can open some slots to the team; only tasks marked shareable can use those. Anyone can watch or steer any session, wherever it runs.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                HStack(spacing: 10) {
                    stat("\(fleet.running)", "running", color: Theme.State.building)
                    stat("\(fleet.teamUsed)/\(fleet.team)", "team slots busy", color: Theme.accent)
                    stat("\(state.queue.count)", "queued", color: Theme.State.awaitingApproval)
                    let offline = state.machines.filter { $0.status.isOffline }.count
                    if offline > 0 { stat("\(offline)", "offline", color: Theme.State.cancelled) }
                }

                ForEach(state.machines.filter { !$0.stranded.isEmpty }) { machine in
                    OfflineBanner(machine: machine)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: narrow ? 1 : 2),
                          spacing: 16) {
                    ForEach(state.machines) { machine in
                        MachineCard(machine: machine)
                    }
                }

                QueueSection()
            }
            .padding(.horizontal, narrow ? 24 : 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(UserDefaults.standard.string(forKey: "scroll") == "bottom" ? .bottom : .top)
    }

    private func stat(_ value: String, _ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule().fill(Theme.fill))
    }
}

// MARK: Machine card

struct MachineCard: View {
    @Environment(AppState.self) private var state
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 6) {
                ForEach(0..<machine.capacity, id: \.self) { slot in
                    SlotRow(machine: machine, slot: slot)
                }
            }

            if machine.status.accepting { guards }

            controls
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(machine.status.isOffline ? Theme.State.cancelled.opacity(0.4) : Theme.stroke))
        )
        .opacity(machine.status == .sleeping ? 0.75 : 1)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: machine.kind.icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(machine.id)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 4) {
                        Circle().fill(machine.status.color).frame(width: 6, height: 6)
                        Text(machine.status.title)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(machine.status.color)
                    if machine.pause != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "pause.fill").font(.system(size: 8))
                            Text("Paused")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.State.awaitingApproval)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Theme.State.awaitingApproval.opacity(0.13)))
                    }
                }
                HStack(spacing: 5) {
                    AgentAvatar(agent: machine.owner, size: 15)
                    Text("\(machine.isMine ? "Yours" : "\(machine.owner.firstName)'s") · \(machine.model)")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            SlotPips(machine: machine, size: 9)
            if machine.isMine, machine.status.accepting {
                PauseMenu(machine: machine)
            }
            if machine.isMine {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
                    .contentShape(Rectangle())
                    .onTapGesture { state.machineSheet = .edit(machine.id) }
                    .help("Slots, load and usage limits")
            }
        }
    }

    /// Load and usage caps: the reasons a machine with free slots might still not take work.
    private var guards: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pause = machine.pause {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 11))
                    Text("Not taking new work\(pause.until.map { " until \($0)" } ?? " until you resume"). \(pause.handedOff ? "Teammates' sessions were handed off; yours finish here." : "Running sessions finish their tasks here.")")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if machine.isMine {
                        Text("Resume")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke)))
                            .contentShape(Rectangle())
                            .onTapGesture { state.resumeMachine(machine.id) }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.State.awaitingApproval)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.State.awaitingApproval.opacity(0.09)))
            }
            if let hit = state.limitHit(machine) {
                notice("gauge.with.dots.needle.100percent",
                       "At its usage limit: \(hit). \(machine.limitScope == .all ? "Not starting new work." : "Only \(machine.isMine ? "your" : "\(machine.owner.firstName)'s") own tasks start.")")
            }
            if machine.highLoad {
                notice("flame", "Under heavy load (\(Int(machine.load * 100))%, limit \(Int(machine.loadCap * 100))%). Not picking up team work.")
            }
            HStack(spacing: 14) {
                meter("Load", value: machine.load, cap: machine.loadCap)
                ForEach(machine.limits) { limit in
                    if let account = FactoryData.usageAccounts.first(where: { $0.id == limit.accountID }) {
                        if let cap = limit.session, let window = account.sessionWindow {
                            meter("5h", value: window.used, cap: cap)
                        }
                        if let cap = limit.weekly, let window = account.weekWindow {
                            meter("Week", value: window.used, cap: cap)
                        }
                    }
                }
            }
        }
    }

    private func meter(_ label: String, value: Double, cap: Double) -> some View {
        let over = value >= cap

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 2)
                Text("\(Int(value * 100))%").foregroundStyle(over ? Theme.State.awaitingApproval : Theme.text)
                Text("/ \(Int(cap * 100))").foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 11).monospacedDigit())
            UsageBar(value: value, color: over ? Theme.State.awaitingApproval : Theme.textMuted.opacity(0.6), pace: cap)
                .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .help("\(label): \(Int(value * 100))% now. Stops taking \(label == "Load" ? "team " : "")work at \(Int(cap * 100))%.")
    }

    private func notice(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.State.awaitingApproval)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.State.awaitingApproval.opacity(0.09)))
    }

    @ViewBuilder private var controls: some View {
        Hairline()
        if machine.isMine {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shared with the team")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("\(machine.teamSlots) of \(machine.capacity) slots · \(machine.personalSlots) just for you")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    stepper
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lend idle slots")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(machine.status == .onBattery && machine.lendIdle
                             ? "Paused while on battery"
                             : "Team work can borrow your free slots, and gives them back when it finishes.")
                            .font(.system(size: 12))
                            .foregroundStyle(machine.status == .onBattery && machine.lendIdle ? Theme.State.awaitingApproval : Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { machine.lendIdle }, set: { state.setLendIdle(machine.id, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                Text(machine.status.isOffline ? "Bring back online (demo)" : "Simulate going offline (demo)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .underline()
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggleOffline(machine.id) }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10.5))
                Text("\(machine.teamSlots) of \(machine.capacity) slots shared with the team. Only \(machine.owner.firstName) can change that.")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
        }
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: machine.teamSlots > 0) { state.setTeamSlots(machine.id, to: machine.teamSlots - 1) }
            Text("\(machine.teamSlots)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 26)
            stepButton("plus", enabled: machine.teamSlots < machine.capacity) { state.setTeamSlots(machine.id, to: machine.teamSlots + 1) }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
    }
}

/// One slot on a machine: who it belongs to and what's running in it.
private struct SlotRow: View {
    @Environment(AppState.self) private var state
    let machine: Machine
    let slot: Int

    /// Team slots come first; sessions fill their kind of slot in order.
    private var occupant: Session? {
        let isTeam = slot < machine.teamSlots
        let pool = machine.sessions.filter { isTeam ? $0.kind == .team : $0.kind != .team }
        let index = isTeam ? slot : slot - machine.teamSlots
        return pool.indices.contains(index) ? pool[index] : nil
    }

    var body: some View {
        let isTeam = slot < machine.teamSlots

        HStack(spacing: 10) {
            Text(isTeam ? "Team" : "Personal")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isTeam ? Theme.accent : Theme.textMuted)
                .frame(width: 56, alignment: .leading)

            if let session = occupant {
                occupied(session)
            } else {
                Text(idleLabel(isTeam: isTeam))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture { if let session = occupant, !session.isReview { state.openSession(session.taskID) } }
        .help(occupant.map { "Open \($0.taskID)'s live session" } ?? "")
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(occupant == nil ? Color.clear : Theme.fillSubtle)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(occupant?.stranded != nil ? Theme.State.cancelled.opacity(0.5) : Theme.stroke,
                                      style: StrokeStyle(lineWidth: 1, dash: occupant == nil || occupant?.stranded != nil ? [4, 3] : []))
                )
        )
    }

    private func idleLabel(isTeam: Bool) -> String {
        if machine.status == .sleeping { return "Asleep" }
        if machine.status.isOffline { return "Offline" }
        if machine.pause != nil { return "Idle · paused" }
        if isTeam { return "Idle · \(machine.isMine ? "your" : "\(machine.owner.firstName)'s") tasks first, then shareable ones" }
        return machine.canLend ? "Idle · lendable to shareable tasks" : "Idle · \(machine.isMine ? "yours" : "\(machine.owner.firstName)'s") only"
    }

    @ViewBuilder private func occupied(_ session: Session) -> some View {
        let task = state.task(session.taskID)
        let agent = session.isReview ? FactoryData.reviewer : task.agent

        if let agent { AgentAvatar(agent: agent, size: 20) }
        Text(task.id)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.textMuted)
        Text(session.isReview ? "Reviewing · \(task.title)" : task.title)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
        if session.kind == .lent {
            Text("Lent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
        }
        if task.owner.id != machine.owner.id {
            AgentAvatar(agent: task.owner, size: 14)
                .help("\(task.owner.firstName)'s task")
        }
        Spacer(minLength: 6)
        if let stranded = session.stranded {
            Label(stranded.autoResumeIn.map { "moves in \($0)" } ?? "waiting", systemImage: "wifi.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.State.cancelled)
                .lineLimit(1)
        } else if task.hand != nil {
            Label("needs a hand", systemImage: "hand.raised.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.State.cancelled)
                .lineLimit(1)
        } else if task.question != nil {
            Text("waiting on you")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.State.awaitingApproval)
        } else {
            Circle().fill(session.isReview ? Theme.State.reviewing : task.state.color).frame(width: 6, height: 6)
            Text(session.elapsed)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
        }
    }
}

/// Filled, lent and free slots at a glance, for cards and the sidebar.
struct SlotPips: View {
    let machine: Machine
    var size: CGFloat = 6
    /// A teammate's machine: only the slots it lends the team.
    var teamOnly = false

    var body: some View {
        if teamOnly { team } else { all }
    }

    /// Its team slots, or every slot the owner isn't using when it lends idle ones too.
    private var team: some View {
        let count = machine.lendIdle ? max(machine.teamSlots, machine.capacity - machine.personalUsed) : machine.teamSlots
        return HStack(spacing: size * 0.4) {
            ForEach(0..<count, id: \.self) { slot in
                let used = slot < machine.teamUsed
                RoundedRectangle(cornerRadius: size * 0.3)
                    .fill(machine.status.isOffline && used ? Theme.State.cancelled : used ? Theme.accent : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(used ? .clear : Theme.accent.opacity(0.5)))
                    .frame(width: size, height: size)
            }
        }
    }

    private var all: some View {
        HStack(spacing: size * 0.4) {
            ForEach(0..<machine.capacity, id: \.self) { slot in
                let isTeam = slot < machine.teamSlots
                let used = isTeam ? slot < machine.teamUsed : slot - machine.teamSlots < machine.personalUsed
                RoundedRectangle(cornerRadius: size * 0.3)
                    .fill(machine.status.isOffline && used ? Theme.State.cancelled
                          : used ? (isTeam ? Theme.accent : Theme.textMuted) : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(isTeam && !used ? Theme.accent.opacity(0.5) : .clear))
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: Offline

/// A machine went dark with sessions on it: what's safe, what's at risk, and what happens next.
struct OfflineBanner: View {
    @Environment(AppState.self) private var state
    let machine: Machine

    private var offlineFor: String {
        guard case .offline(let since) = machine.status else { return "" }
        return since == "now" ? "just now" : "\(since) ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").foregroundStyle(Theme.State.cancelled)
                (Text("\(machine.id) went offline").fontWeight(.semibold).foregroundStyle(Theme.text)
                 + Text(" \(offlineFor) with \(machine.stranded.count) session\(machine.stranded.count == 1 ? "" : "s") on it")
                    .foregroundStyle(Theme.textMuted))
                    .font(.system(size: 13))
                Spacer()
                AgentAvatar(agent: machine.owner, size: 18)
            }
            ForEach(machine.stranded) { session in
                StrandedRow(machine: machine, session: session)
            }
            Text("Agents push a checkpoint after every plan step. Team sessions move to another machine after 10 minutes; personal ones wait for their owner.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.State.cancelled.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.State.cancelled.opacity(0.25)))
        )
    }
}

/// One session stuck on a dark machine, with the choice to wait or move it.
struct StrandedRow: View {
    @Environment(AppState.self) private var state
    let machine: Machine
    let session: Session
    var showsOpen = true

    var body: some View {
        let task = state.task(session.taskID)
        let stranded = session.stranded

        HStack(alignment: .top, spacing: 10) {
            if let agent = task.agent { AgentAvatar(agent: agent, size: 22) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    Text(task.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                }
                HStack(spacing: 12) {
                    Label(stranded?.checkpoint ?? "", systemImage: "checkmark.icloud")
                        .foregroundStyle(Theme.State.merged)
                    if let unpushed = stranded?.unpushed {
                        Label("\(unpushed) not pushed", systemImage: "exclamationmark.icloud")
                            .foregroundStyle(Theme.State.awaitingApproval)
                    }
                }
                .font(.system(size: 11.5))
                .labelStyle(.titleAndIcon)
                Text(task.shareable
                     ? "Shareable: resumes on another free slot in \(stranded?.autoResumeIn ?? "10m") unless \(machine.id) comes back."
                     : "Not shareable: waits for \(machine.isMine ? "one of your machines" : "one of \(machine.owner.firstName)'s machines").")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if showsOpen {
                    button("Open", primary: false) {
                        state.destination = .goal(task.goal)
                        state.openFocus(task.id)
                    }
                }
                if session.kind != .personal || machine.isMine {
                    button("Resume elsewhere", primary: true) { state.resumeElsewhere(task.id) }
                }
            }
        }
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12, weight: primary ? .semibold : .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: Queue

private struct QueueSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(state.queue.count) approved, waiting for a slot")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }

            if state.queue.isEmpty {
                Text("Nothing waiting. Every approved task has a slot.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 6)
            }

            VStack(spacing: 0) {
                ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, item in
                    row(index + 1, item)
                    if index < state.queue.count - 1 { Hairline().padding(.leading, 44) }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            )
            .opacity(state.queue.isEmpty ? 0 : 1)
        }
    }

    private func row(_ position: Int, _ item: QueuedTask) -> some View {
        let task = state.task(item.taskID)

        return HStack(alignment: .top, spacing: 12) {
            Text("\(position)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.fill))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(task.id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    Text(task.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Circle().fill(FactoryData.goal(named: task.goal).color).frame(width: 6, height: 6)
                }
                Text(state.waitingReason(item))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let secret = item.requires {
                HStack(spacing: 4) {
                    Image(systemName: "key").font(.system(size: 10))
                    Text(secret)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.8))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Theme.fill))
            }
            ShareableChip(task: task)
            AvatarPair(owner: task.owner, agent: task.agent)
        }
        .padding(14)
    }
}

/// Shown at the top of a task whose machine went dark.
struct StrandedTaskBanner: View {
    let machine: Machine
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").foregroundStyle(Theme.State.cancelled)
                Text("\(machine.id) went offline mid-build")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("last seen \(session.stranded?.lastSeen ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }
            StrandedRow(machine: machine, session: session, showsOpen: false)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.State.cancelled.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.cancelled.opacity(0.25)))
        )
    }
}

/// Shown at the top of a live task whose machine went dark, was paused or removed mid-flight.
struct LiveStrandedBanner: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let name: String
    let why: String
    let lastSeen: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: why == "was paused" ? "pause.circle" : "wifi.slash").foregroundStyle(Theme.State.cancelled)
                Text("\(name) \(why) mid-\(task.state == .planning ? "plan" : task.state == .reviewing ? "review" : "build")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let lastSeen {
                    Text(LiveAdapter.ago(lastSeen) == "now" ? "just now" : "last seen \(LiveAdapter.ago(lastSeen)) ago")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let pushed = task.pushed {
                        Label("Last push \(pushed.prefix(7)) is safe on the remote", systemImage: "checkmark.icloud")
                            .foregroundStyle(Theme.State.merged)
                    } else {
                        Label("Nothing pushed yet: elsewhere it starts again from \(task.state == .planning ? "the brief" : "its plan")", systemImage: "exclamationmark.icloud")
                            .foregroundStyle(Theme.State.awaitingApproval)
                    }
                    Text("It waits for \(name) unless you move it. Work that was only on \(name) stays there.")
                        .foregroundStyle(Theme.textMuted)
                }
                .font(.system(size: 11.5))
                .labelStyle(.titleAndIcon)
                Spacer(minLength: 8)
                Text("Resume elsewhere")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
                    .contentShape(Rectangle())
                    .onTapGesture { state.resumeElsewhere(task.id) }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.State.cancelled.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.cancelled.opacity(0.25)))
        )
    }
}

/// Whether a task may use teammates' team slots. The owner can flip it; everyone else sees it.
struct ShareableChip: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask

    var body: some View {
        let mine = task.owner.id == FactoryData.me.id

        HStack(spacing: 4) {
            Image(systemName: task.shareable ? "person.3.fill" : "lock.fill").font(.system(size: 9.5))
            Text(task.shareable ? "Shareable" : mine ? "Your machines" : "\(task.owner.firstName)'s machines")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(task.shareable ? Theme.accent : Theme.text.opacity(0.75))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(task.shareable ? Theme.accent.opacity(0.12) : Theme.fill))
        .contentShape(Capsule())
        .onTapGesture { if mine { state.setShareable(task.id, !task.shareable) } }
        .help(mine
              ? (task.shareable ? "Can run in teammates' team slots. Click to keep it on your machines." : "Only runs on your machines. Click to let it use team slots.")
              : (task.shareable ? "\(task.owner.firstName) lets this run in team slots." : "\(task.owner.firstName) keeps this on their own machines."))
    }
}

/// Pause new work on one of your machines: for a while, until tomorrow, or until you resume.
struct PauseMenu: View {
    @Environment(AppState.self) private var state
    let machine: Machine

    var body: some View {
        Menu {
            if machine.pause != nil {
                Button("Resume now") { state.resumeMachine(machine.id) }
            } else {
                Section("Stop taking new work") {
                    Button("For 1 hour") { state.pauseMachine(machine.id, until: "1:15 AM") }
                    Button("Until tomorrow, 9 AM") { state.pauseMachine(machine.id, until: "tomorrow 9 AM") }
                    Button("Until I resume") { state.pauseMachine(machine.id, until: nil) }
                }
                Section {
                    Button("Pause and hand off team work") { state.pauseMachine(machine.id, until: nil, handOff: true) }
                }
            }
        } label: {
            Image(systemName: machine.pause == nil ? "pause" : "play.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(machine.pause == nil ? Theme.textMuted : Theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
        .fixedSize()
        .help(machine.pause == nil ? "Pause new work on \(machine.id)" : "Resume \(machine.id)")
    }
}
