import SwiftUI
import MapleKit

/// How much factory work a machine takes: its slots, how many teammates may use, and pausing.
/// The iPhone's take on the Mac's MachineSettingsSheet; plan limits are carried through unchanged.
struct MachineSettingsSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machine: Wire.Machine

    @State private var automatic: Bool
    @State private var capacity: Int
    @State private var teamSlots: Int
    @State private var lendIdle: Bool
    @State private var loadCap: Double
    @State private var paused: Bool
    @State private var pauseScope: PauseScope
    @State private var pauseFor: PauseLength = .untilResumed
    @State private var handOff = true

    enum PauseScope: String, CaseIterable {
        case newWork = "New work", everything = "Everything"
    }

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
        _pauseScope = State(initialValue: s?.paused == true && s?.pauseNew != true ? .everything : .newWork)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Work it out from the cores", isOn: $automatic)
                        .accessibilityIdentifier("settings-automatic")
                    if automatic {
                        LabeledContent("Sessions at once", value: "\(machine.capacity ?? 1) (from \(machine.health?.cores ?? 0) cores)")
                    } else {
                        Stepper(value: $capacity, in: 0...16) {
                            LabeledContent("Sessions at once", value: "\(capacity)")
                        }
                        .accessibilityIdentifier("settings-capacity")
                    }
                    Stepper(value: $teamSlots, in: 0...maxTeamSlots) {
                        LabeledContent("Team slots", value: teamSlots == 0 ? "None" : "\(teamSlots)")
                    }
                    .accessibilityIdentifier("settings-team-slots")
                    Toggle("Lend every idle slot to the team", isOn: $lendIdle)
                        .accessibilityIdentifier("settings-lend-idle")
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Don't start teammates' work above", value: "\(Int(loadCap * 100))% CPU")
                        Slider(value: $loadCap, in: 0.3...1, step: 0.05)
                            .accessibilityIdentifier("settings-load-cap")
                        if let load {
                            Text("Load right now: \(Int(load * 100))%\(load >= loadCap ? " · not taking teammates' work" : "")")
                                .font(.caption)
                                .foregroundStyle(load >= loadCap ? Theme.warning : .secondary)
                        }
                    }
                } header: {
                    Text("Slots")
                } footer: {
                    Text("Your tasks run here first; teammates' shareable tasks use the team slots.")
                }

                Section {
                    Toggle("Pause factory work here", isOn: $paused)
                        .accessibilityIdentifier("settings-paused")
                    if paused {
                        Picker("Hold back", selection: $pauseScope) {
                            ForEach(PauseScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("settings-pause-scope")
                    }
                    if paused && !wasPaused {
                        Picker("For", selection: $pauseFor) {
                            ForEach(PauseLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .accessibilityIdentifier("settings-pause-length")
                        if !teammates.isEmpty && pauseScope == .everything {
                            Toggle("Hand off \(teammates.count == 1 ? "1 teammate's task" : "\(teammates.count) teammates' tasks") (\(teammates.map(\.id).joined(separator: ", ")))",
                                   isOn: $handOff)
                                .accessibilityIdentifier("settings-hand-off")
                        }
                    }
                } header: {
                    Text("Pause")
                } footer: {
                    Text(pauseHelp)
                }
            }
            .navigationTitle(machine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("settings-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("settings-save")
                }
            }
        }
    }

    private var maxTeamSlots: Int { max(0, automatic ? Int(machine.capacity ?? 1) : capacity) }
    private var wasPaused: Bool { machine.settings?.paused ?? false }
    private var wasFullyPaused: Bool { wasPaused && machine.settings?.pauseNew != true }

    private var pauseHelp: String {
        if !paused { return "Pause holds back factory work here until you resume it." }
        if pauseScope == .newWork {
            return "No new tasks start here. Tasks already on this machine keep going until they're done."
        }
        if !teammates.isEmpty && handOff && !wasFullyPaused {
            return "Their work so far is pushed and they carry on elsewhere. Your own sessions finish what they're doing."
        }
        return "Running sessions finish what they're doing; nothing starts here while it's paused."
    }

    /// Teammates' tasks running here, in team slots.
    private var teammates: [Wire.Task] {
        store.feed.tasks.filter { $0.worker?.machine == machine.id && $0.worker?.role != .reviewer && $0.owner != machine.owner }
    }

    /// CPU load per core, from the machine's last health report.
    private var load: Double? {
        machine.health.map { min(1, $0.load1 / Double(max(1, $0.cores))) }
    }

    private func save() {
        let s = machine.settings
        let settings = Wire.MachineSettings(
            capacity: automatic ? nil : UInt32(capacity),
            teamSlots: UInt32(min(teamSlots, maxTeamSlots)),
            lendIdle: lendIdle,
            loadCap: loadCap,
            paused: paused,
            pausedUntil: paused ? (wasPaused ? s?.pausedUntil : pauseFor.until) : nil,
            pauseNew: paused && pauseScope == .newWork ? true : nil,
            sessionCap: s?.sessionCap,
            weeklyCap: s?.weeklyCap,
            agentCaps: s?.agentCaps,
            capsTeamOnly: s?.capsTeamOnly
        )
        // Only a full pause hands teammates' tasks off; under a new-work pause they finish here.
        let pausing = paused && pauseScope == .everything && !wasFullyPaused
        store.saveMachineSettings(machine, settings: settings, handOff: pausing && handOff && !teammates.isEmpty)
        dismiss()
    }
}
