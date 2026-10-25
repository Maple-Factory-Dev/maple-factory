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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                    Slider(value: $loadCap, in: 0.3...1, step: 0.05)
                }
            }

            group("Plan limits") {
                cap("Stop at this much of the 5-hour session", $sessionCap)
                cap("Stop at this much of the week", $weeklyCap)
                Text("Applies to every agent account signed in here. Running sessions finish; new factory work waits or goes elsewhere.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            weeklyCap: weeklyCap
        )
        let pausing = paused && !wasPaused
        client.send(.machineSettings(.init(machine: machine.id, settings: settings, handOff: pausing && handOff && !teammates.isEmpty)))
        if embedded { withAnimation { saved = true } } else { dismiss() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
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
        Text(title)
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? .white : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.accent : Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : Theme.stroke)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
