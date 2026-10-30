import SwiftUI

/// How much factory work a machine takes: its slots, how many teammates may use, and pausing.
struct MachineSettingsSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let machine: Wire.Machine
    /// In Settings rather than a sheet: no title or Cancel, and Save stays put.
    var embedded = false

    @State private var automatic: Bool
    @State private var capacity: Int
    @State private var teamSlots: Int
    @State private var lendIdle: Bool
    @State private var loadCap: Double
    @State private var paused: Bool
    @State private var sessionCap: Double?
    @State private var weeklyCap: Double?
    /// Caps per agent account, for the agents that report usage here.
    @State private var agentCaps: [String: Wire.AgentCap]
    @State private var teamOnly: Bool
    @State private var pauseFor: PauseLength = .untilResumed
    @State private var handOff = true

    enum PauseLength: String, CaseIterable {
        case hour = "1 hour", tonight = "Until tomorrow", untilResumed = "Until I resume"

        var until: UInt64? {
            let now = Date()
            switch self {
            case .hour: return UInt64(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
            case .tonight:
                let morning = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 8), matchingPolicy: .nextTime) ?? now
                return UInt64(morning.timeIntervalSince1970 * 1000)
            case .untilResumed: return nil
            }
        }
    }

    @State private var saved = false

    init(machine: Wire.Machine, embedded: Bool = false) {
        self.machine = machine
        self.embedded = embedded
        let s = machine.settings
        _automatic = State(initialValue: s?.capacity == nil)
        _capacity = State(initialValue: Int(s?.capacity ?? machine.capacity ?? 2))
        _teamSlots = State(initialValue: Int(s?.teamSlots ?? 0))
        _lendIdle = State(initialValue: s?.lendIdle ?? false)
        _loadCap = State(initialValue: s?.loadCap ?? 0.85)
        _paused = State(initialValue: s?.paused ?? false)
        _sessionCap = State(initialValue: s?.sessionCap)
        _weeklyCap = State(initialValue: s?.weeklyCap)
        // Accounts without their own caps yet start from the machine-wide ones.
        var caps = Dictionary(uniqueKeysWithValues: (s?.agentCaps ?? []).map { ($0.agent, $0) })
        for usage in machine.usage where caps[usage.agent] == nil {
            caps[usage.agent] = Wire.AgentCap(agent: usage.agent, session: s?.sessionCap, weekly: s?.weeklyCap)
        }
        _agentCaps = State(initialValue: caps)
        _teamOnly = State(initialValue: s?.capsTeamOnly ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 22 : 20) {
            if !embedded {
            VStack(alignment: .leading, spacing: 6) {
                Text("Factory work on \(machine.name)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Planner, builder and reviewer sessions run here for your tasks first, and for teammates' shareable tasks in team slots.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }

            group("Slots") {
                Toggle("Work it out from the machine's cores", isOn: $automatic)
                    .toggleStyle(.switch).controlSize(.small)
                if !automatic {
                    Stepper(value: $capacity, in: 0...16) { row("Sessions at once", "\(capacity)") }
                } else {
                    row("Sessions at once", "\(machine.capacity ?? 1) (from \(machine.health?.cores ?? 0) cores)")
                }
                Stepper(value: $teamSlots, in: 0...max(0, automatic ? Int(machine.capacity ?? 1) : capacity)) {
                    row("Team slots", teamSlots == 0 ? "None: only your tasks" : "\(teamSlots)")
                }
                Toggle("Lend every idle slot to the team", isOn: $lendIdle)
                    .toggleStyle(.switch).controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    row("Don't start teammates' work above", "\(Int(loadCap * 100))% CPU")
                    if let load {
                        UsageBar(value: load, color: load >= loadCap ? Theme.State.awaitingApproval : Theme.State.building, pace: loadCap)
                    }
                    Slider(value: $loadCap, in: 0.3...1, step: 0.05)
                    if let load {
                        Text("Load right now: \(Int(load * 100))%\(load >= loadCap ? " · not taking teammates' work" : "")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(load >= loadCap ? Theme.State.awaitingApproval : Theme.textMuted)
                    }
                }
            }

            group("Plan limits") {
                if machine.usage.isEmpty {
                    cap("Stop at this much of the 5-hour session", $sessionCap)
                    cap("Stop at this much of the week", $weeklyCap)
                    Text("Applies to every agent account signed in here. Per-account limits show up once an agent reports its usage.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(machine.usage, id: \.agent) { usage in accountLimits(usage) }
                }
                HStack(spacing: 10) {
                    Text("Limits apply to").foregroundStyle(Theme.textMuted)
                    Picker("", selection: $teamOnly) {
                        Text("All work").tag(false)
                        Text("Teammates' work").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(teamOnly
                     ? "Your own tasks keep running past the limits; only teammates' work stops."
                     : "Your own tasks and teammates' both stop at the limits. Running sessions finish their current step.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            summary

            group("Pause") {
                Toggle("Pause factory work here", isOn: $paused)
                    .toggleStyle(.switch).controlSize(.small)
                if paused && !(machine.settings?.paused ?? false) {
                    Picker("", selection: $pauseFor) {
                        ForEach(PauseLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if !teammates.isEmpty {
                        Toggle("Hand off \(teammates.count == 1 ? "\(teammates[0].owner.firstName)'s task" : "\(teammates.count) teammates' tasks") (\(teammates.map(\.id).joined(separator: ", ")))",
                               isOn: $handOff)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12.5))
                    }
                }
                Text(paused && !teammates.isEmpty && handOff && !(machine.settings?.paused ?? false)
                     ? "Their work so far is pushed and they carry on on another machine. Your own sessions finish here; nothing new starts while it's paused."
                     : "Running sessions finish what they're doing; nothing new starts here while it's paused.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }

            HStack(spacing: 8) {
                if saved {
                    Label("Saved", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if !embedded { button("Cancel", primary: false) { dismiss() } }
                button("Save", primary: true, action: save)
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 520)
    }

    /// Teammates' tasks running here, in team slots.
    private var teammates: [FactoryTask] {
        client.factoryTasks.filter { $0.worker?.machine == machine.id && $0.worker?.role != "reviewer" && $0.owner.github != machine.owner }
    }

    private func save() {
        let wasPaused = machine.settings?.paused ?? false
        let settings = Wire.MachineSettings(
            capacity: automatic ? nil : UInt32(capacity),
            teamSlots: UInt32(teamSlots),
            lendIdle: lendIdle,
            loadCap: loadCap,
            paused: paused,
            pausedUntil: paused ? (wasPaused ? machine.settings?.pausedUntil : pauseFor.until) : nil,
            sessionCap: sessionCap,
            weeklyCap: weeklyCap,
            agentCaps: machine.usage.isEmpty ? machine.settings?.agentCaps : machine.usage.compactMap { agentCaps[$0.agent] },
            capsTeamOnly: teamOnly
        )
        let pausing = paused && !wasPaused
        client.send(.machineSettings(.init(machine: machine.id, settings: settings, handOff: pausing && handOff && !teammates.isEmpty)))
        if embedded { withAnimation { saved = true } } else { dismiss() }
    }

    /// CPU load per core, from the machine's last health report.
    private var load: Double? {
        machine.health.map { min(1, $0.load1 / Double(max(1, $0.cores))) }
    }

    /// One agent account's caps, each against what it has used so far.
    private func accountLimits(_ usage: Wire.AgentUsage) -> some View {
        let caps = Binding(get: { agentCaps[usage.agent] ?? Wire.AgentCap(agent: usage.agent) }, set: { agentCaps[usage.agent] = $0 })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AgentIcon(agent: usage.agent, size: 14).foregroundStyle(Theme.text)
                Text(agentTitle(usage.agent)).font(.system(size: 13, weight: .semibold))
                if let plan = usage.plan {
                    Text(plan).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Theme.fill))
                }
                if let name = usage.account?.name { Text(name).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                Spacer()
            }
            if let w = usage.windows.first(where: { $0.label == "5h" }) {
                capRow("5-hour session", reading: w, cap: Binding(get: { caps.wrappedValue.session }, set: { caps.wrappedValue.session = $0 }))
            }
            if let w = usage.windows.first(where: { $0.label == "7d" && $0.name == nil }) {
                capRow("Week", reading: w, cap: Binding(get: { caps.wrappedValue.weekly }, set: { caps.wrappedValue.weekly = $0 }))
            }
        }
    }

    private func capRow(_ label: String, reading: Wire.UsageReading, cap: Binding<Double?>) -> some View {
        let window = LiveAdapter.window(reading)
        let value = cap.wrappedValue ?? 0.8
        let over = cap.wrappedValue != nil && window.used >= value
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { cap.wrappedValue != nil }, set: { cap.wrappedValue = $0 ? 0.8 : nil }))
                    .toggleStyle(.checkbox).labelsHidden()
                Text(label)
                Spacer()
                Text(cap.wrappedValue == nil ? "No limit" : "Stop at \(Int(value * 100))%")
                    .foregroundStyle(cap.wrappedValue == nil ? Theme.textFaint : over ? Theme.State.awaitingApproval : Theme.text)
                    .monospacedDigit()
            }
            UsageBar(value: window.used, color: over ? Theme.State.awaitingApproval : Theme.accent, pace: cap.wrappedValue)
            if cap.wrappedValue != nil {
                Slider(value: Binding(get: { value }, set: { cap.wrappedValue = $0 }), in: 0.3...1, step: 0.05)
            }
            Text(over
                 ? "Already at \(Int(window.used * 100))%, so no new work starts here until it resets \(window.resetsAt)."
                 : "Now \(Int(window.used * 100))% · resets \(window.resetsAt)\(cap.wrappedValue == nil ? "" : " · leaves \(100 - Int(value * 100))% for you")")
                .font(.system(size: 11.5))
                .foregroundStyle(over ? Theme.State.awaitingApproval : Theme.textMuted)
        }
    }

    /// When this machine stops taking new work, in a sentence per account.
    private var summary: some View {
        let lines: [String] = machine.usage.compactMap { usage in
            guard let caps = agentCaps[usage.agent] else { return nil }
            var parts: [String] = []
            if let cap = caps.session, let w = usage.windows.first(where: { $0.label == "5h" }) {
                parts.append("the 5-hour session reaches \(Int(cap * 100))% (now \(Int(w.usedPercent.rounded()))%)")
            }
            if let cap = caps.weekly, let w = usage.windows.first(where: { $0.label == "7d" && $0.name == nil }) {
                parts.append("the week reaches \(Int(cap * 100))% (now \(Int(w.usedPercent.rounded()))%)")
            }
            return parts.isEmpty ? nil : "\(agentTitle(usage.agent)): when \(parts.joined(separator: " or "))"
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text(lines.isEmpty
                     ? "No limits: the factory can use all of your plan on \(machine.name)."
                     : "\(machine.name) stops taking new \(teamOnly ? "team " : "")work")
                    .font(.system(size: 12.5, weight: .medium))
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fillSubtle))
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        if embedded {
            // In Settings, one of its sections.
            SettingsSection(title) {
                SettingsBlock(spacing: 12) { content() }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text)
        } else {
            sheetGroup(title, content: content)
        }
    }

    private func sheetGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke)))
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text)
    }

    private func cap(_ label: String, _ value: Binding<Double?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? 0.8 : nil })) {
                row(label, value.wrappedValue.map { "\(Int($0 * 100))%" } ?? "No cap")
            }
            .toggleStyle(.switch).controlSize(.small)
            if let current = value.wrappedValue {
                Slider(value: Binding(get: { current }, set: { value.wrappedValue = $0 }), in: 0.3...1, step: 0.05)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Theme.textMuted).monospacedDigit()
        }
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
        Text(title)
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? .white : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.accent : Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : Theme.stroke)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
