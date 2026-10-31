import SwiftUI

/// A task's Effort detail: a menu of its goal's efforts, "New effort…" (named in place) and "None".
struct EffortPicker: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        if state.namingEffort == task.id {
            TextField("Effort name", text: $state.effortDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.5)))
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit {
                    state.namingEffort = nil
                    state.setEffort(task.id, state.effortDraft)
                }
                .onExitCommand { state.namingEffort = nil }
        } else {
            Menu {
                let efforts = state.efforts(in: task.goal)
                ForEach(efforts, id: \.self) { name in
                    Button {
                        state.setEffort(task.id, name)
                    } label: {
                        if name == task.effort { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
                if !efforts.isEmpty { Divider() }
                Button("New effort…") {
                    state.effortDraft = ""
                    state.namingEffort = task.id
                }
                if task.effort != nil {
                    Button("None") { state.setEffort(task.id, nil) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(task.effort ?? "None")
                        .foregroundStyle(task.effort == nil ? Theme.textMuted : Theme.text)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The bigger effort it's part of, shared with other tasks in \(task.goal)")
        }
    }
}

/// Every task in the same effort, so seeing one shows the rest: state, id and title, with the
/// current task highlighted and the others a click away.
struct EffortSection: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let effort: String

    var body: some View {
        let siblings = state.tasks(inEffort: effort, goal: task.goal)
        let counted = siblings.filter { $0.state != .cancelled && $0.state != .closed }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Effort")
                Spacer()
                Text("\(counted.filter { $0.state == .merged }.count) of \(counted.count) merged")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            Text(effort)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(siblings, id: \.id) { sibling in
                    EffortRow(task: sibling, current: sibling.id == task.id)
                }
            }
            .padding(.horizontal, -6)
        }
    }
}

private struct EffortRow: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let current: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(task.state.color).frame(width: 7, height: 7)
            Text(task.id)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(current ? Theme.text : Theme.textMuted)
            Text(task.title)
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(Theme.text)
                .strikethrough(task.state == .cancelled, color: Theme.textFaint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.accent.opacity(0.12) : hovering ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 && !current }
        .onTapGesture { if !current { state.openFocus(task.id) } }
        .help("\(task.id) · \(task.state.title)")
    }
}

/// A small chip naming a task's effort, on board cards, so related tasks stand out.
struct EffortChip: View {
    let effort: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 8.5, weight: .semibold))
            Text(effort).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(Theme.accent.opacity(0.1)))
        .help("Part of the \(effort) effort")
    }
}
