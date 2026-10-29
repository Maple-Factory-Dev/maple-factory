import SwiftUI

/// Tasks grouped by state as dense rows; `showGoal` adds a goal column for cross-goal lists like My tasks.
struct TaskListView: View {
    @Environment(AppState.self) private var state
    let tasks: [FactoryTask]
    var showGoal = false
    @SwiftUI.State private var collapsed: Set<TaskState> = []
    /// The task whose row's context menu asked to cancel it.
    @SwiftUI.State private var cancelling: FactoryTask?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(TaskState.allCases) { taskState in
                    let group = tasks.filter { $0.state == taskState }
                    if !group.isEmpty {
                        Section {
                            if !collapsed.contains(taskState) {
                                ForEach(group) { task in row(task) }
                            }
                        } header: {
                            sectionHeader(taskState, count: group.count)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .cancelTaskConfirmation(task: cancelling ?? FactoryTask.none, isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }))
    }

    private func sectionHeader(_ taskState: TaskState, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: collapsed.contains(taskState) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 10)
            Image(systemName: taskState.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(taskState.color)
            Text(taskState.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("\(count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 34)
        .background(Theme.columnBG)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(taskState) { collapsed.remove(taskState) } else { collapsed.insert(taskState) }
        }
    }

    private var compact: Bool { state.contentWidth < 860 }

    private func row(_ task: FactoryTask) -> some View {
        let selected = state.selectedTask == task.id

        return HStack(spacing: 12) {
            Text(task.id)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 66, alignment: .leading)

            Text(task.title)
                .font(Theme.uiFont)
                .foregroundStyle(task.state == .cancelled ? Theme.textMuted : Theme.text)
                .strikethrough(task.state == .cancelled, color: Theme.textFaint)
                .lineLimit(1)

            if task.hand != nil { NeedsHandBadge() } else if task.needsYou { NeedsYouBadge() }

            Spacer(minLength: 16)

            if showGoal, !compact {
                Text(task.goal)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 140, alignment: .leading)
            }

            TaskProgressFooter(task: task, compact: true)
                .frame(width: compact ? 150 : 190, alignment: .leading)

            HStack(spacing: 6) {
                AvatarPair(owner: task.owner, agent: task.agent)
                if !compact {
                    Text(task.owner.id == FactoryData.me.id ? "You" : task.owner.firstName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                    if let viewer = task.viewers.first {
                        PresenceTag(person: viewer)
                    }
                }
            }
            .frame(width: compact ? 40 : 150, alignment: .leading)

            Text(task.updated)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .frame(height: 40)
        .background(selected ? Theme.fillSelected : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(task.state.color).frame(width: 2) }
        }
        .overlay(alignment: .bottom) { Hairline().padding(.leading, 24) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.openFocus(task.id) }
        .onTapGesture { state.selectedTask = task.id }
        .contextMenu {
            TaskActionButtons(task: task, confirmCancel: Binding(get: { cancelling?.id == task.id }, set: { cancelling = $0 ? task : nil }))
        }
    }
}

struct MyTasksView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("My tasks")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Everything you own across every goal, whichever agent is doing the work.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 20)

            TaskListView(tasks: state.tasks.filter { $0.owner.id == FactoryData.me.id }, showGoal: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
