import MapleKit
import SwiftUI

struct GoalAllTasksRoute: Hashable { let goal: String }

/// Every task in a goal, stage by stage, with Backlog, the finished stages and Load older: what the
/// goal page listed before its Overview (MF-324), one tap away so no task is out of reach.
struct GoalAllTasksView: View {
    @Environment(FactoryStore.self) private var store
    let id: String

    private static let stages: [Wire.TaskState] = [.awaitingApproval, .planning, .building, .reviewing, .drafting, .backlog, .merged, .closed, .cancelled]

    @State private var editMode: EditMode = .inactive

    var body: some View {
        let tasks = store.feed.tasks(in: id)
        List {
            ForEach(Self.stages, id: \.self) { stage in
                let staged = tasks.filter { $0.state == stage }
                if stage == .drafting {
                    DraftsSection(drafts: staged.sorted(by: Wire.Task.draftOrder), editMode: $editMode) { count in
                        StageHeader(stage: .drafting, count: count)
                    }
                } else if !staged.isEmpty {
                    Section {
                        ForEach(staged) { task in
                            NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                                .swipeActions(edge: .trailing) {
                                    if stage == .backlog, !editMode.isEditing { PlanSwipe(task: task) }
                                }
                        }
                    } header: {
                        StageHeader(stage: stage, count: staged.count)
                    }
                }
            }
            if store.feed.hasOlder(goal: id) { loadOlderSection }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("All tasks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        // `-loadOlder YES` presses Load older once, for screenshots.
        .task { if UserDefaults.standard.bool(forKey: "loadOlder") { store.loadOlder(goal: id) } }
    }

    /// Under the finished stages: the snapshot sends tasks finished in the last 14 days; this brings 50 older ones.
    private var loadOlderSection: some View {
        let loading = store.feed.loadingOlder.contains(id)
        let left = store.feed.older[id]?.finished ?? 0
        return Section {
            Button { store.loadOlder(goal: id) } label: {
                HStack {
                    Label("Load older", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    if loading { ProgressView() } else { Text("\(left) more").foregroundStyle(.secondary) }
                }
            }
            .disabled(loading)
            .accessibilityIdentifier("load-older")
        } footer: {
            Text("Finished tasks older than 14 days load when you ask.")
        }
    }
}

struct StageHeader: View {
    let stage: Wire.TaskState
    let count: Int

    var body: some View {
        Label("\(stage.title) · \(count)", systemImage: stage.icon).foregroundStyle(Theme.state(stage))
    }
}

/// A folding section's chevron: right when folded, down when open.
struct FoldChevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(open ? 90 : 0))
            .foregroundStyle(.secondary)
    }
}

/// Swipe a task to planning.
struct PlanSwipe: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task

    var body: some View {
        Button { store.plan(task.id) } label: { Label("Plan", systemImage: Wire.TaskState.planning.icon) }
            .tint(Theme.state(.planning))
    }
}

/// A goal's drafts in their order: swipe one to planning or the backlog, or Edit to drag them.
struct DraftsSection<Header: View>: View {
    @Environment(FactoryStore.self) private var store
    let drafts: [Wire.Task]
    @Binding var editMode: EditMode
    var editID = "drafts-edit"
    /// Set on the goal Overview to fold the section from its header (MF-340); All tasks leaves it nil.
    var open: Binding<Bool>? = nil
    @ViewBuilder let header: (Int) -> Header

    private var editing: Bool { editMode.isEditing }
    private var isOpen: Bool { open?.wrappedValue ?? true }

    var body: some View {
        if !drafts.isEmpty {
            Section {
                if isOpen { rows }
            } header: {
                HStack {
                    if let open {
                        Button {
                            withAnimation {
                                open.wrappedValue.toggle()
                                if !open.wrappedValue { editMode = .inactive }
                            }
                        } label: {
                            HStack {
                                header(drafts.count)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("section-drafts")
                        .accessibilityValue(isOpen ? "expanded" : "collapsed")
                    } else {
                        header(drafts.count)
                        Spacer()
                    }
                    if drafts.count > 1, isOpen {
                        Button(editing ? "Done" : "Edit") {
                            withAnimation { editMode = editing ? .inactive : .active }
                        }
                        .font(.subheadline.weight(editing ? .semibold : .regular))
                        .textCase(nil)
                        .accessibilityIdentifier(editID)
                    }
                    if open != nil { FoldChevron(open: isOpen) }
                }
            }
            .onChange(of: drafts.count > 1) { _, several in if !several { editMode = .inactive } }
        }
    }

    private var rows: some View {
        ForEach(drafts) { task in
            NavigationLink(value: TaskRoute(id: task.id)) { TaskRow(task: task) }
                .swipeActions(edge: .trailing) {
                    if !editing {
                        Button { store.sendToBacklog(task.id) } label: { Label("Backlog", systemImage: Wire.TaskState.backlog.icon) }
                            .tint(Theme.state(.backlog))
                        PlanSwipe(task: task)
                    }
                }
        }
        .onMove { from, to in move(from: from, to: to) }
    }

    /// Ranks the dragged draft ahead of the one that now follows it ("top" when it lands first).
    private func move(from: IndexSet, to: Int) {
        guard let index = from.first else { return }
        var order = drafts
        order.move(fromOffsets: from, toOffset: to)
        let id = drafts[index].id
        guard let at = order.firstIndex(where: { $0.id == id }), order.map(\.id) != drafts.map(\.id) else { return }
        store.rankDraft(id, before: at == 0 ? "top" : order.indices.contains(at + 1) ? order[at + 1].id : nil)
    }
}
