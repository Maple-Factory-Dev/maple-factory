import SwiftUI

/// Which machine the setup sheet is showing.
enum MachineSheet: Identifiable, Hashable {
    case new
    case edit(String)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id
        }
    }
}

extension FactoryData {
    /// What the app detects about the Mac it's running on, for a first-time setup.
    static let thisMac = Machine(
        id: "mbp-16", kind: .laptop, model: "MacBook Pro 16″ · M4 Max · 48 GB", owner: me, status: .online,
        capacity: 3, teamSlots: 1, lendIdle: false, sessions: [],
        limits: [
            UsageLimit(accountID: "claude-andrea", session: 0.8, weekly: 0.8),
            UsageLimit(accountID: "codex-andrea", session: nil, weekly: 0.8),
        ]
    )
}

/// Setting up (or editing) a machine: how many sessions it runs, how many the team gets,
/// and how much of each account's plan the factory may use before it stops taking new work.
struct MachineSetupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let sheet: MachineSheet
    @State private var machine: Machine

    init(sheet: MachineSheet, machine: Machine) {
        self.sheet = sheet
        _machine = State(initialValue: machine)
    }

    private var isNew: Bool { sheet == .new }
    /// Accounts signed in on this machine. A new Mac reports what's installed; existing ones keep theirs.
    private var accounts: [UsageAccount] {
        machine.limits.compactMap { limit in FactoryData.usageAccounts.first { $0.id == limit.accountID } }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    slots
                    limits
                    summary
                }
                .padding(28)
            }
            footer
        }
        .frame(width: 600, height: 720)
        .background(Theme.editorBG)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: machine.kind.icon)
                .font(.system(size: 24))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "Set up this Mac" : "Edit \(machine.id)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    TextField("Machine name", text: $machine.id)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .disabled(!isNew)
                        .fixedSize()
                    Text("· \(machine.model)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private var slots: some View {
        section("Slots", detail: "How many agent sessions this machine runs at once.") {
            VStack(spacing: 14) {
                stepperRow("Sessions at once",
                           detail: isNew ? "Suggested 3 for 48 GB of memory" : "\(machine.sessions.count) running now",
                           value: machine.capacity, range: max(1, machine.sessions.count)...8) { machine.capacity = $0; machine.teamSlots = min(machine.teamSlots, $0) }
                stepperRow("Shared with the team",
                           detail: "\(machine.capacity - machine.teamSlots) stay just for you",
                           value: machine.teamSlots, range: 0...machine.capacity) { machine.teamSlots = $0 }
                toggleRow("Lend idle slots", detail: "Shareable team work can borrow free personal slots. Pauses on battery.",
                          isOn: $machine.lendIdle)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pause team work under heavy load").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            Text("Above this CPU and memory load, teammates' tasks won't start here. Yours still can.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text("\(Int(machine.loadCap * 100))%")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                    UsageBar(value: machine.load, color: machine.highLoad ? Theme.State.awaitingApproval : Theme.State.building, pace: machine.loadCap)
                    Slider(value: Binding(get: { machine.loadCap }, set: { machine.loadCap = ($0 * 20).rounded() / 20 }), in: 0.5...1)
                        .controlSize(.small)
                        .tint(Theme.accent)
                    Text(isNew ? "Load right now: \(Int(machine.load * 100))%" : "Load right now: \(Int(machine.load * 100))%\(machine.highLoad ? " · not taking team work" : "")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(machine.highLoad ? Theme.State.awaitingApproval : Theme.textMuted)
                }
            }
        }
    }

    private var limits: some View {
        section("Usage limits",
                detail: "Stop starting new sessions here once an account reaches these levels, so you keep some of your plan for your own work. Running sessions finish their current step.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach($machine.limits) { $limit in
                    if let account = FactoryData.usageAccounts.first(where: { $0.id == limit.accountID }) {
                        AccountLimitEditor(account: account, limit: $limit)
                    }
                }

                HStack(spacing: 10) {
                    Text("Limits apply to")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                    Picker("", selection: $machine.limitScope) {
                        ForEach(UsageLimit.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(machine.limitScope == .all
                     ? "Your own tasks and teammates' both stop at the limit."
                     : "Your own tasks keep running past the limit; only teammates' work stops.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private var summary: some View {
        let lines: [String] = accounts.compactMap { account in
            guard let limit = machine.limits.first(where: { $0.accountID == account.id }) else { return nil }
            var parts: [String] = []
            if let cap = limit.session, let window = account.sessionWindow {
                parts.append("the 5-hour session reaches \(Int(cap * 100))% (now \(Int(window.used * 100))%)")
            }
            if let cap = limit.weekly, let window = account.weekWindow {
                parts.append("the week reaches \(Int(cap * 100))% (now \(Int(window.used * 100))%)")
            }
            return parts.isEmpty ? nil : "\(account.product.name): when \(parts.joined(separator: " or "))"
        }

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text(lines.isEmpty ? "No limits: the factory can use all of your plan on this machine." : "\(machine.id) stops taking new work")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fillSubtle))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Text("Cancel")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .keyboardShortcut(.cancelAction)
            Text(isNew ? "Add machine" : "Save")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .contentShape(Rectangle())
                .onTapGesture {
                    state.saveMachine(machine)
                    dismiss()
                }
        }
        .padding(.horizontal, 28)
        .frame(height: 60)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.cardBG)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
                )
        }
    }

    private func stepperRow(_ title: String, detail: String, value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 0) {
                stepButton("minus", enabled: value > range.lowerBound) { set(value - 1) }
                Text("\(value)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(width: 28)
                stepButton("plus", enabled: value < range.upperBound) { set(value + 1) }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.accent)
        }
    }
}

/// Session and weekly caps for one account. The session row only appears when the plan has a 5-hour window.
private struct AccountLimitEditor: View {
    let account: UsageAccount
    @Binding var limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProductMark(product: account.product).scaleEffect(0.8).frame(width: 20, height: 20)
                Text(account.product.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(account.plan)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Theme.fill))
                Text(account.accountName ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }
            if let window = account.sessionWindow {
                capRow("5-hour session", window: window, cap: $limit.session)
            }
            if let window = account.weekWindow {
                capRow("Week", window: window, cap: $limit.weekly)
            }
        }
        .padding(.bottom, 4)
    }

    private func capRow(_ title: String, window: UsageWindow, cap: Binding<Double?>) -> some View {
        let enabled = cap.wrappedValue != nil
        let value = cap.wrappedValue ?? 0.8
        let over = enabled && window.used >= value

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { enabled }, set: { cap.wrappedValue = $0 ? 0.8 : nil }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                if enabled {
                    Text("Stop at \(Int(value * 100))%")
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(over ? Theme.State.awaitingApproval : Theme.text)
                } else {
                    Text("No limit").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
            }
            if enabled {
                UsageBar(value: window.used, color: over ? Theme.State.awaitingApproval : ProductMark.claude, pace: value)
                Slider(value: Binding(get: { value }, set: { cap.wrappedValue = ($0 * 20).rounded() / 20 }), in: 0.3...1)
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text(over
                     ? "Already at \(Int(window.used * 100))%, so this machine won't take new work until \(window.resetsAt)."
                     : "Now \(Int(window.used * 100))% · resets \(window.resetsAt) · leaves \(100 - Int(value * 100))% for you")
                    .font(.system(size: 11.5))
                    .foregroundStyle(over ? Theme.State.awaitingApproval : Theme.textMuted)
            }
        }
        .padding(.leading, 28)
    }
}
