import MapleKit
import SwiftUI

/// A small chip naming a task's effort, on task rows, so related tasks stand out (the Mac's EffortChip).
struct EffortChip: View {
    let effort: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 9.5, weight: .semibold))
            Text(effort).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.accent.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Effort \(effort)")
    }
}

/// Every task in the same effort, so seeing one shows the rest: state, id and title, with the
/// current task highlighted and the others a tap away (the Mac's EffortSection).
struct EffortCard: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let effort: String

    var body: some View {
        let siblings = store.tasks(inEffort: effort, goal: task.goal)
        let counted = siblings.filter { $0.state != .cancelled && $0.state != .closed }
        let merged = counted.filter { $0.state == .merged }.count
        Card("Effort", icon: "square.stack.3d.up",
             accessory: AnyView(Text("\(merged) of \(counted.count) merged").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("effort.count"))) {
            Text(effort).font(.subheadline.weight(.semibold)).accessibilityIdentifier("effort.name")
            VStack(spacing: 2) {
                ForEach(siblings, id: \.id) { sibling in
                    if sibling.id == task.id {
                        EffortRow(task: sibling, current: true)
                            .accessibilityIdentifier("effort.current-\(sibling.id)")
                    } else {
                        NavigationLink(value: TaskRoute(id: sibling.id)) { EffortRow(task: sibling, current: false) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("effort.sibling-\(sibling.id)")
                    }
                }
            }
            .padding(.horizontal, -8)
        }
    }
}

private struct EffortRow: View {
    let task: Wire.Task
    let current: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.state(task.state)).frame(width: 8, height: 8)
            Text(task.id).font(.caption.monospaced().weight(.medium)).foregroundStyle(current ? .primary : .secondary)
            Text(task.title)
                .font(.callout.weight(current ? .semibold : .regular))
                .strikethrough(task.state == .cancelled, color: .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !current { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? Theme.accent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.state.rawValue)
    }
}

/// Picks the task's effort: one of its goal's, a new one named here, or None.
struct EffortSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: Wire.Task
    @State private var draft = ""

    private var efforts: [String] { store.feed.goal(task.goal).map { store.efforts(in: $0) } ?? [] }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            if !efforts.isEmpty {
                Section("Efforts in this goal") {
                    ForEach(efforts, id: \.self) { name in
                        Button { pick(name) } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                if name == task.effort { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityIdentifier("effort-\(name)")
                    }
                }
            }
            Section {
                TextField("New effort…", text: $draft)
                    .submitLabel(.done)
                    .onSubmit { if !trimmed.isEmpty { pick(trimmed) } }
                    .accessibilityIdentifier("effort-new")
                if !trimmed.isEmpty {
                    Button("Add to \(trimmed)") { pick(trimmed) }.accessibilityIdentifier("effort-create")
                }
            } footer: {
                Text("Tasks in the same effort show each other on their Overview.")
            }
            if task.effort != nil {
                Section {
                    Button("None", role: .destructive) { pick(nil) }.accessibilityIdentifier("effort-none")
                }
            }
        }
        .navigationTitle("Effort for \(task.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func pick(_ name: String?) {
        store.setEffort(task.id, name)
        dismiss()
    }
}
