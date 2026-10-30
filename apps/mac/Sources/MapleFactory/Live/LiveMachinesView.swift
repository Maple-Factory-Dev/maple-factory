import SwiftUI

/// The real machines of the factory you're signed in to: their health, their live sessions, and
/// why sessions ended. Opening a session drops into its terminal.
struct LiveMachinesView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var open: OpenSession?
    @State private var adding = false
    /// A session asked for on this machine; it opens as soon as the runner reports it.
    @State private var awaiting: (machine: String, known: Set<String>)?

    struct OpenSession: Equatable {
        let machine: String
        let id: String
    }

    private var narrow: Bool { state.contentWidth < 960 }

    var body: some View {
        Group {
            if let open {
                LiveSessionView(machineID: open.machine, sessionID: open.id) { withAnimation(.snappy) { self.open = nil } }
            } else {
                list
            }
        }
        .onAppear(perform: openFromLaunchArgs)
        .onChange(of: client.machines) { _, machines in
            guard let awaiting, let machine = machines.first(where: { $0.id == awaiting.machine }),
                  let new = machine.sessions.first(where: { !awaiting.known.contains($0.session.id) }) else { return }
            self.awaiting = nil
            withAnimation(.snappy) { open = OpenSession(machine: machine.id, id: new.session.id) }
        }
        .sheet(isPresented: $adding) { AddMachineSheet() }
    }

    /// Tasks that could run but have no slot yet, oldest first, with why.
    private var queued: [Wire.Task] {
        client.tasks.filter { $0.worker == nil && $0.waiting != nil }.sorted { $0.updatedAt < $1.updatedAt }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Waiting for a slot · \(queued.count)")
            VStack(spacing: 6) {
                ForEach(queued, id: \.id) { task in
                    HStack(spacing: 10) {
                        Text(task.id)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                        Text(task.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if task.shareable {
                            Text("Shareable").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.State.planning)
                        }
                        Spacer(minLength: 8)
                        Text(task.waiting ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.State.awaitingApproval)
                            .lineLimit(1)
                        if task.waiting?.contains("free slot") == true, task.state == .planning || task.state == .building {
                            Button { state.forceStart(task.id) } label: { Label("Run now", systemImage: "bolt") }
                                .controlSize(.small)
                                .help("Start it now, over the machine's slot count")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fillSubtle))
                    .contentShape(Rectangle())
                    .onTapGesture { state.openSession(task.id) }
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if client.status == .tooNew { TooNewBanner() }

                if client.machines.isEmpty {
                    emptyState
                } else {
                    stats
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: narrow ? 1 : 2), spacing: 16) {
                        ForEach(client.machines, id: \.id) { machine in
                            LiveMachineCard(machine: machine, onOpen: { id in
                                withAnimation(.snappy) { open = OpenSession(machine: machine.id, id: id) }
                            }, onNew: { agent in
                                awaiting = (machine.id, Set(machine.sessions.map(\.session.id)))
                                client.openSession(machine: machine.id, agent: agent, cwd: "~")
                            })
                        }
                    }
                    if !queued.isEmpty { queue }
                    if !client.ends.isEmpty { RecentEnds() }
                }
            }
            .padding(.horizontal, narrow ? 24 : 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Machines")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.text)
                ConnectionPill()
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    Text("Add machine")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
                .contentShape(Rectangle())
                .onTapGesture { adding = true }
            }
            Text("The machines enrolled in \(client.org.isEmpty ? "this factory" : client.org). Sessions run in tmux on each machine and stream here; open one to watch or type into it.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var stats: some View {
        let online = client.machines.filter(\.online)
        let sessions = online.flatMap(\.sessions)
        let waiting = sessions.filter { $0.activity?.state == .waiting }.count
        return HStack(spacing: 10) {
            stat("\(online.count)/\(client.machines.count)", "online", color: Theme.State.merged)
            stat("\(sessions.count)", sessions.count == 1 ? "session" : "sessions", color: Theme.State.building)
            if waiting > 0 { stat("\(waiting)", "waiting on someone", color: Theme.State.awaitingApproval) }
            let unexpected = client.ends.filter { $0.end.cause.unexpected }.count
            if unexpected > 0 { stat("\(unexpected)", "ended unexpectedly", color: Theme.State.cancelled) }
        }
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
            Text("Add your first machine")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Install the runner on a Mac or Linux box you work on. It dials out to the factory, so nothing needs to be opened up; sessions keep running in tmux even when the runner restarts.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Get the commands")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .contentShape(Rectangle())
                .onTapGesture { adding = true }
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke)))
    }

    /// `-liveSession first` opens the first live session, for screenshots.
    private func openFromLaunchArgs() {
        guard AppDefaults.string(forKey: "liveSession") == "first" else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                if let machine = client.machines.first(where: { !$0.sessions.isEmpty }), let first = machine.sessions.first {
                    open = OpenSession(machine: machine.id, id: first.session.id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

// MARK: Machine card

struct LiveMachineCard: View {
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    let onOpen: (String) -> Void
    let onNew: (String) -> Void

    private var isMine: Bool { machine.owner == client.me?.login }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if client.updatePhase(machine) != .current {
                RunnerUpdateRow(machine: machine, canUpdate: isMine || client.me?.role == "admin") { showingChanges = true }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
            }
            if let health = machine.health, machine.online { meters(health) }
            factory
            sessions
            if let health = machine.health, machine.online { agents(health) }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        )
        .opacity(machine.online || client.updatePhase(machine).isBusy ? 1 : 0.8)
        .runnerChanges(machine, isPresented: $showingChanges)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: machine.health?.battery != nil ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 19))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(machine.name)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    statusChip
                }
                HStack(spacing: 5) {
                    Text(isMine ? "Yours" : machine.owner)
                    if let os = machine.os { Text("·"); Text(os == "macos" ? "macOS" : os.capitalized) }
                    if let version = machine.version { Text("·"); Text("runner \(version)") }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            if machine.online && isMine { newSessionMenu }
            if isMine || client.me?.role == "admin" { moreMenu }
        }
        .alert("Rename \(machine.name)", isPresented: $renaming) {
            TextField(machine.id, text: $nickname)
            Button("Rename") { client.send(.machineRename(.init(machine: machine.id, name: nickname))) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A nickname everyone sees in place of \(machine.id). Leave it empty to go back to that.")
        }
        .confirmationDialog("Remove \(machine.name) from \(client.org)?", isPresented: $confirmRemove) {
            Button("Remove Machine", role: .destructive) { Task { await client.removeMachine(machine.id) } }
        } message: {
            Text("Its runner is disconnected and its token revoked. Sessions on it keep running in tmux there; enroll it again to bring it back.")
        }
    }

    @State private var confirmRemove = false
    @State private var renaming = false
    @State private var nickname = ""
    @State private var editing = false
    @State private var showingChanges = false

    /// The factory's use of it: slots taken, team slots, and whether it's paused.
    private var factory: some View {
        let used = machine.sessions.filter { $0.session.taskId != nil }.count
        let capacity = Int(machine.capacity ?? 0)
        let settings = machine.settings
        return HStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            HStack(spacing: 3) {
                ForEach(0..<max(capacity, used), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < used ? Theme.State.building : Theme.fill)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(index >= capacity - Int(settings?.teamSlots ?? 0) && index < capacity ? Theme.State.planning.opacity(0.6) : .clear))
                        .frame(width: 14, height: 8)
                }
            }
            Text("\(used) of \(capacity) factory slots\(settings.map { $0.teamSlots > 0 || $0.lendIdle ? " · \($0.lendIdle ? "lends idle slots" : "\($0.teamSlots) for the team")" : "" } ?? "")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer()
            if settings?.paused == true {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                    Text(settings?.pausedUntil.map { "Paused until \(Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .omitted, time: .shortened))" } ?? "Paused")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.State.awaitingApproval)
            }
        }
        .sheet(isPresented: $editing) { MachineSettingsSheet(machine: machine) }
    }

    private var moreMenu: some View {
        Menu {
            Button("Factory Settings…") { editing = true }
            Button("Rename…") { nickname = machine.name == machine.id ? "" : machine.name; renaming = true }
            if let settings = machine.settings {
                let teammates = client.factoryTasks.contains { $0.worker?.machine == machine.id && $0.owner.github != machine.owner }
                Button(settings.paused ? "Resume Factory Work" : teammates ? "Pause Factory Work…" : "Pause Factory Work") {
                    // Teammates' tasks are running here: pausing asks whether to hand them off.
                    if !settings.paused && teammates { editing = true; return }
                    var changed = settings
                    changed.paused.toggle()
                    changed.pausedUntil = nil
                    client.send(.machineSettings(.init(machine: machine.id, settings: changed)))
                }
            }
            switch client.runnerAction(machine) {
            case .update(let latest):
                Button("Update Runner to \(latest)") { client.perform(.update(latest), on: machine) }
                    .disabled(!machine.online || client.updatePhase(machine).isBusy)
            case .check:
                Button("Check for Runner Update") { client.perform(.check, on: machine) }
                    .disabled(client.updatePhase(machine).isBusy)
            }
            Button("What's New in the Runner…") { showingChanges = true }
                .disabled(client.runnerReleases.isEmpty)
            Divider()
            Button("Copy Machine ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(machine.id, forType: .string)
            }
            Divider()
            Button("Remove from Factory…", role: .destructive) { confirmRemove = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusChip: some View {
        let restarting = if case .restarting = client.updatePhase(machine) { true } else { false }
        let (text, color): (String, Color) = restarting && !machine.online
            ? ("Restarting", Theme.State.building)
            : machine.online
            ? (machine.health?.battery.map { $0.charging ? "Online" : "On battery" } ?? "Online",
               machine.health?.battery.map { $0.charging ? Theme.State.merged : Theme.State.awaitingApproval } ?? Theme.State.merged)
            : ("Offline\(machine.lastSeen.map { " · \(relative($0))" } ?? "")", Theme.State.cancelled)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
    }

    private var newSessionMenu: some View {
        let installed = (machine.health?.agents ?? []).map(\.name)
        let choices = ["shell"] + installed
        return Menu {
            ForEach(choices, id: \.self) { agent in
                Button(agentTitle(agent)) { onNew(agent) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Session")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start a session on \(machine.name)")
    }

    private func meters(_ health: Wire.Health) -> some View {
        HStack(spacing: 14) {
            meter("CPU", health.cpu / 100, detail: "\(Int(health.cpu.rounded()))%")
            meter("Memory", Double(health.memUsed) / Double(max(health.memTotal, 1)), detail: "\(Int((Double(health.memUsed) / Double(max(health.memTotal, 1)) * 100).rounded()))%")
                .help("\(bytes(health.memUsed)) of \(bytes(health.memTotal)) used")
            meter("Disk", Double(health.diskUsed) / Double(max(health.diskTotal, 1)), detail: "\(bytes(health.diskTotal - health.diskUsed)) free")
            if let battery = health.battery {
                meter("Battery", battery.percent / 100, detail: "\(Int(battery.percent))%\(battery.charging ? " ⚡︎" : "")", low: battery.percent < 20)
            }
        }
    }

    private func meter(_ label: String, _ value: Double, detail: String, low: Bool = false) -> some View {
        let high = label == "Battery" ? low : value > 0.85
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 4)
                Text(detail).foregroundStyle(high ? Theme.State.cancelled : Theme.text.opacity(0.8)).lineLimit(1)
            }
            .font(.system(size: 11).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(high ? Theme.State.cancelled : Theme.text.opacity(0.35))
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var sessions: some View {
        if machine.sessions.isEmpty {
            Text(machine.online ? "No sessions running." : "Sessions on this machine show up when it's back.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else {
            VStack(spacing: 6) {
                ForEach(machine.sessions, id: \.session.id) { live in
                    LiveSessionRow(live: live)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(live.session.id) }
                }
            }
        }
    }

    private func agents(_ health: Wire.Health) -> some View {
        HStack(spacing: 6) {
            ForEach(health.agents, id: \.name) { agent in
                HStack(spacing: 4) {
                    Image(systemName: agent.loggedIn ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(agent.loggedIn ? Theme.State.merged : Theme.State.awaitingApproval)
                    Text(agentTitle(agent.name))
                    if let version = agent.version { Text(version).foregroundStyle(Theme.textFaint) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Theme.fill))
                .help(agent.loggedIn ? "\(agentTitle(agent.name)) is signed in" : "\(agentTitle(agent.name)) isn't signed in on this machine")
            }
        }
    }
}

struct LiveSessionRow: View {
    let live: Wire.LiveSession
    @State private var hovering = false

    var body: some View {
        let state = live.activity?.state ?? .idle
        HStack(spacing: 10) {
            Circle().fill(state.color).frame(width: 7, height: 7)
                .overlay(Circle().stroke(state.color.opacity(0.3), lineWidth: state == .working ? 4 : 0))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let task = live.session.taskId {
                        Text(task)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.State.building)
                            .padding(.horizontal, 5)
                            .frame(height: 17)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.State.building.opacity(0.12)))
                    }
                    Text(agentTitle(live.session.agent))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(shortPath(live.session.cwd))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(live.activity?.message ?? live.activity?.step ?? (live.session.agent == "shell" ? "Interactive shell" : state.title))
                    .font(.system(size: 11.5))
                    .foregroundStyle(state == .waiting ? Theme.State.awaitingApproval : Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(relative(live.session.startedAt))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.text : Theme.textFaint)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.fillSelected : Theme.fillSubtle))
        .onHover { hovering = $0 }
    }
}

// MARK: Ends

/// Sessions that ended while you watched the feed, with what ended them.
struct RecentEnds: View {
    @Environment(FactoryClient.self) private var client
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Recently ended")
            VStack(spacing: 0) {
                ForEach(Array(client.ends.prefix(6).enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Hairline() }
                    EndRow(record: record, expanded: expanded == record.id) {
                        withAnimation(.snappy(duration: 0.2)) { expanded = expanded == record.id ? nil : record.id }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke)))
        }
    }
}

struct EndRow: View {
    @Environment(FactoryClient.self) private var client
    let record: FactoryClient.EndRecord

    private var endTitle: String { record.end.endTitle(me: client.me?.login) }
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let cause = record.end.cause
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: cause.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(cause.color)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(cause.color.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(endTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Text(record.machine).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                    Text(record.end.detail ?? (record.end.by != nil ? "Killed from Maple." : cause.explanation))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(expanded ? nil : 1)
                }
                Spacer(minLength: 6)
                Text(relative(record.end.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textFaint)
                if !record.end.lastOutput.isEmpty {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            if expanded && !record.end.lastOutput.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last thing on screen")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text(record.end.lastOutput.suffix(12).joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xD8DCE3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Term.bg))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

// MARK: Connection

struct ConnectionPill: View {
    @Environment(FactoryClient.self) private var client

    var body: some View {
        let (text, color): (String, Color) = switch client.status {
        case .live: ("Live · \(client.server?.host() ?? "")", Theme.State.merged)
        case .connecting: ("Connecting…", Theme.textMuted)
        case .reconnecting(let attempt, let reason): ("\(reason) Retrying\(attempt > 1 ? " (\(attempt))" : "")…", Theme.State.awaitingApproval)
        case .tooNew: ("Update needed", Theme.State.awaitingApproval)
        case .signedOut: ("Signed out", Theme.textFaint)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// The factory sent something this build can't read, so the feed is down until the app is updated.
struct TooNewBanner: View {
    private var updater: Updater { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.State.awaitingApproval)
            VStack(alignment: .leading, spacing: 2) {
                Text(FactoryClient.tooNewMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("It sends things this version of the app can't read yet. Machines and tasks come back once you update.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            // Without a feed (`swift run`), Sparkle is inert: send them to the download page instead.
            PrimaryButton(title: "Check for Updates", icon: "arrow.down.circle", enabled: !updater.available || updater.canCheck, color: Theme.accent) {
                if updater.available { updater.checkForUpdates() } else { NSWorkspace.shared.open(URL(string: "https://maplefactory.dev")!) }
            }
            .fixedSize()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.State.awaitingApproval.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.awaitingApproval.opacity(0.3)))
        )
    }
}

// MARK: Formatting

extension Wire.AgentState {
    var color: Color {
        switch self {
        case .working: Theme.State.building
        case .waiting: Theme.State.awaitingApproval
        case .done: Theme.State.merged
        case .idle, .other: Theme.State.drafting
        }
    }

    var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for someone"
        case .done: "Finished its turn"
        case .idle: "Ready"
        case .other: "Busy"
        }
    }
}

extension Wire.SessionEnd {
    /// "You ended it", "Ended by chris", or the cause.
    func endTitle(me: String?) -> String {
        guard cause == .killed, let by else { return cause.title }
        return by == me ? "You ended it" : "Ended by \(by)"
    }
}

extension Wire.EndCause {
    /// Ends that nobody chose: worth a look, and what recovery is for.
    var unexpected: Bool { self != .killed && self != .exited }

    var title: String {
        switch self {
        case .exited: "Exited"
        case .killed: "Ended by someone"
        case .signaled: "Killed by a signal"
        case .outOfMemory: "Out of memory"
        case .machineSlept: "Machine slept"
        case .tmuxLost: "tmux went away"
        case .runnerUpdated: "Runner restarted"
        case .authExpired: "Login expired"
        case .usageLimit: "Usage limit"
        case .unknown, .other: "Ended, cause unknown"
        }
    }

    var explanation: String {
        switch self {
        case .exited: "The agent exited on its own."
        case .killed: "Someone pressed Kill or cancelled the task."
        case .signaled: "The process died from a signal nobody here sent."
        case .outOfMemory: "The OS reclaimed it while memory was short."
        case .machineSlept: "The machine went to sleep and the session didn't survive it."
        case .tmuxLost: "The runner's tmux server stopped, taking its sessions with it."
        case .runnerUpdated: "The runner restarted for an update."
        case .authExpired: "The agent's login needs renewing on that machine."
        case .usageLimit: "The account hit its session or weekly limit."
        case .unknown: "The runner couldn't tell what ended it."
        case .other: "It ended for a reason this version of the app doesn't know."
        }
    }

    var icon: String {
        switch self {
        case .exited: "checkmark"
        case .killed: "xmark"
        case .signaled: "bolt.fill"
        case .outOfMemory: "memorychip"
        case .machineSlept: "moon.zzz.fill"
        case .tmuxLost: "rectangle.on.rectangle.slash"
        case .runnerUpdated: "arrow.triangle.2.circlepath"
        case .authExpired: "key.fill"
        case .usageLimit: "gauge.with.dots.needle.100percent"
        case .unknown, .other: "questionmark"
        }
    }

    var color: Color {
        switch self {
        case .exited: Theme.State.merged
        case .killed, .runnerUpdated: Theme.State.drafting
        case .machineSlept, .usageLimit, .authExpired: Theme.State.awaitingApproval
        case .signaled, .outOfMemory, .tmuxLost, .unknown, .other: Theme.State.cancelled
        }
    }
}

func agentTitle(_ name: String) -> String {
    switch name {
    case "claude": "Claude Code"
    case "codex": "Codex"
    case "shell": "Shell"
    default: name.capitalized
    }
}

func shortPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// "now", "4m", "2h", "3d" from a millisecond timestamp.
func relative(_ ms: UInt64) -> String {
    let seconds = max(0, Date().timeIntervalSince1970 - Double(ms) / 1000)
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86_400))d"
    }
}

func bytes(_ count: UInt64) -> String {
    let gb = Double(count) / 1_073_741_824
    return gb >= 100 ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
}

/// A member's GitHub avatar, with their initials until it loads (or when there isn't one).
struct MemberAvatar: View {
    let member: Wire.Member
    var size: CGFloat = 20

    var body: some View {
        let initials = (member.name ?? member.login).split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        ZStack {
            Circle().fill(Theme.accent.opacity(0.85))
            Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            if let avatar = member.avatarUrl, let url = URL(string: avatar) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// A dot per live session, coloured by what its agent is doing.
struct LivePips: View {
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    var size: CGFloat = 6
    /// A teammate's machine: only the slots it lends the team, filled by their work on it.
    var sharedOnly = false

    /// The slots a machine lends the team: its team slots, or every slot the owner isn't using when it
    /// lends idle ones too.
    static func sharedCount(_ machine: Wire.Machine, tasks: [Wire.Task]) -> Int {
        guard let settings = machine.settings else { return 0 }
        let team = Int(settings.teamSlots)
        guard settings.lendIdle else { return team }
        let capacity = Int(machine.capacity ?? settings.capacity ?? settings.teamSlots)
        let own = machine.sessions.count - teamSessions(machine, tasks: tasks).count
        return max(team, capacity - own)
    }

    /// Sessions running teammates' work: those whose task isn't the owner's. When none of the sessions'
    /// tasks can be found, every session counts.
    static func teamSessions(_ machine: Wire.Machine, tasks: [Wire.Task]) -> [Wire.LiveSession] {
        let owners = machine.sessions.map { live in live.session.taskId.flatMap { id in tasks.first { $0.id == id } }?.owner }
        guard owners.contains(where: { $0 != nil }) else { return machine.sessions }
        return zip(machine.sessions, owners).filter { $0.1 != machine.owner }.map(\.0)
    }

    var body: some View {
        if sharedOnly { shared } else { all }
    }

    private var shared: some View {
        let count = Self.sharedCount(machine, tasks: client.tasks)
        let used = Array(Self.teamSessions(machine, tasks: client.tasks).prefix(count))
        return HStack(spacing: size * 0.5) {
            ForEach(0..<count, id: \.self) { slot in
                if slot < used.count {
                    Circle().fill(machine.online ? (used[slot].activity?.state ?? .idle).color : Theme.textFaint).frame(width: size, height: size)
                } else {
                    Circle().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1).frame(width: size, height: size)
                }
            }
        }
    }

    private var all: some View {
        HStack(spacing: size * 0.5) {
            if machine.sessions.isEmpty {
                Circle().strokeBorder(Theme.textFaint, lineWidth: 1).frame(width: size, height: size)
            }
            ForEach(machine.sessions.prefix(6), id: \.session.id) { live in
                Circle().fill(machine.online ? (live.activity?.state ?? .idle).color : Theme.textFaint).frame(width: size, height: size)
            }
        }
    }
}
