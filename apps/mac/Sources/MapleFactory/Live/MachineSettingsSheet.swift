import SwiftUI

/// How much factory work a machine takes: its slots, how many teammates may use, and pausing.
struct MachineSettingsSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let machine: Wire.Machine

    @State private var automatic: Bool
    @State private var capacity: Int
    @State private var teamSlots: Int
    @State private var lendIdle: Bool
    @State private var loadCap: Double
    @State private var paused: Bool
    @State private var pauseFor: PauseLength = .untilResumed

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

    init(machine: Wire.Machine) {
        self.machine = machine
        let s = machine.settings
        _automatic = State(initialValue: s?.capacity == nil)
        _capacity = State(initialValue: Int(s?.capacity ?? machine.capacity ?? 2))
        _teamSlots = State(initialValue: Int(s?.teamSlots ?? 0))
        _lendIdle = State(initialValue: s?.lendIdle ?? false)
        _loadCap = State(initialValue: s?.loadCap ?? 0.85)
        _paused = State(initialValue: s?.paused ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Factory work on \(machine.name)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Planner, builder and reviewer sessions run here for your tasks first, and for teammates' shareable tasks in team slots.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
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

            group("Pause") {
                Toggle("Pause factory work here", isOn: $paused)
                    .toggleStyle(.switch).controlSize(.small)
                if paused && !(machine.settings?.paused ?? false) {
                    Picker("", selection: $pauseFor) {
                        ForEach(PauseLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("Running sessions finish what they're doing; nothing new starts here while it's paused.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }

            HStack(spacing: 8) {
                Spacer()
                button("Cancel", primary: false) { dismiss() }
                button("Save", primary: true, action: save)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() {
        let wasPaused = machine.settings?.paused ?? false
        let settings = Wire.MachineSettings(
            capacity: automatic ? nil : UInt32(capacity),
            teamSlots: UInt32(teamSlots),
            lendIdle: lendIdle,
            loadCap: loadCap,
            paused: paused,
            pausedUntil: paused ? (wasPaused ? machine.settings?.pausedUntil : pauseFor.until) : nil
        )
        client.send(.machineSettings(.init(machine: machine.id, settings: settings)))
        dismiss()
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
