import SwiftUI

struct GoalView: View {
    @Environment(AppState.self) private var state
    let goal: Goal

    private var tasks: [FactoryTask] { state.tasks(for: goal) }

    private var contributors: [Person] {
        FactoryData.people.filter { person in tasks.contains { $0.owner.id == person.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 20)

            switch state.layout {
            case .board: BoardColumns(tasks: tasks)
            case .list: TaskListView(tasks: tasks)
            case .timeline: GoalTimeline(goal: goal, tasks: tasks)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "scope").foregroundStyle(goal.color)
                Text("Goal")
                Text("·")
                Text("Due \(FactoryData.dueLabel(goal))")
                Text("·")
                Text("Lead")
                AgentAvatar(agent: goal.lead, size: 16)
                Text(goal.lead.id == FactoryData.me.id ? "You" : goal.lead.firstName)
                    .foregroundStyle(Theme.text)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)

            HStack(alignment: .center) {
                Text(goal.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                RiskPolicyButton()
                    .padding(.trailing, 10)
                Facepile(people: contributors, size: 24)
                if state.contentWidth > 900 {
                    Text("\(contributors.count) people · \(Set(tasks.compactMap(\.agent?.id)).count) agents")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, 6)
                }
            }

            Text(goal.summary)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textMuted)
                .lineSpacing(3)
                .frame(maxWidth: 620, alignment: .leading)

            FlowBar(tasks: tasks)
                .padding(.top, 8)
        }
    }
}

/// A single bar showing how a goal's tasks are spread across the pipeline.
struct FlowBar: View {
    let tasks: [FactoryTask]

    private var populated: [(state: TaskState, count: Int)] {
        TaskState.allCases.map { s in (s, tasks.filter { $0.state == s }.count) }.filter { $0.count > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let usable = proxy.size.width - CGFloat(populated.count - 1) * 3
                HStack(spacing: 3) {
                    ForEach(populated, id: \.state) { entry in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(entry.state.color.opacity(entry.state == .cancelled ? 0.45 : 1))
                            .frame(width: usable * CGFloat(entry.count) / CGFloat(tasks.count))
                    }
                }
            }
            .frame(height: 6)
            .frame(maxWidth: 620)

            HStack(spacing: 14) {
                ForEach(populated, id: \.state) { entry in
                    HStack(spacing: 5) {
                        Circle().fill(entry.state.color).frame(width: 6, height: 6)
                        Text("\(entry.count)").foregroundStyle(Theme.text).monospacedDigit()
                        Text(entry.state.title)
                    }
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textMuted)
        }
    }
}

// MARK: - Board

struct BoardColumns: View {
    @Environment(AppState.self) private var state
    let tasks: [FactoryTask]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskState.allCases) { taskState in
                    column(taskState)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }

    private func column(_ taskState: TaskState) -> some View {
        let columnTasks = tasks.filter { $0.state == taskState }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: taskState.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(taskState.color)
                Text(taskState.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("\(columnTasks.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            ForEach(columnTasks) { task in
                TaskCard(task: task, selected: task.id == state.selectedTask)
                    .onTapGesture(count: 2) { state.openFocus(task.id) }
                    .onTapGesture { state.selectedTask = task.id }
            }

            if columnTasks.isEmpty {
                Text("Nothing here")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
            }
        }
        .padding(8)
        .frame(width: 240, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.columnBG))
        .opacity(taskState == .cancelled ? 0.7 : 1)
    }
}

struct TaskCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                let unseen = state.unseenChanges(for: task).count
                if unseen > 0 {
                    Circle()
                        .fill(Theme.State.building)
                        .frame(width: 6, height: 6)
                        .help("\(unseen) changes since you last looked")
                }
                Text(task.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                if let risk = state.risk(for: task), risk.level > .low {
                    RiskBadge(level: risk.level, compact: true)
                }
                if task.hand != nil { NeedsHandBadge() } else if task.needsYou { NeedsYouBadge() }
                Spacer()
                AvatarPair(owner: task.owner, agent: task.agent)
            }

            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(task.state == .cancelled ? Theme.textMuted : Theme.text)
                .strikethrough(task.state == .cancelled, color: Theme.textFaint)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            TaskProgressFooter(task: task)

            if !task.doneWhen.isEmpty, task.state == .building || task.state == .reviewing {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10.5))
                        .foregroundStyle(task.proven == task.doneWhen.count ? Theme.State.merged : Theme.textMuted)
                    Text("\(task.proven)/\(task.doneWhen.count) proven")
                    Spacer()
                    ProofMeter(criteria: task.doneWhen)
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            }

            let queued = state.queuedChanges(for: task)
            if queued > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5, weight: .semibold))
                    Text(queued == 1 ? "1 change queued" : "\(queued) changes queued")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.State.awaitingApproval)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.cardBG)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(borderColor, lineWidth: selected || viewer != nil ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if let viewer {
                PresenceTag(person: viewer).offset(x: 6, y: -9)
            }
        }
        .contentShape(Rectangle())
    }

    private var viewer: Person? { task.viewers.first }

    private var borderColor: Color {
        if let viewer { return viewer.color }
        return selected ? task.state.color : Theme.stroke
    }
}

/// The state-specific line under a task: progress, checks and diff, a spinner, or plain detail text.
struct TaskProgressFooter: View {
    let task: FactoryTask
    var compact = false

    var body: some View {
        if let progress = task.progress {
            if compact {
                HStack(spacing: 8) {
                    bar(progress).frame(width: 60)
                    detail
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    bar(progress)
                    detail
                }
            }
        } else if let diff = task.diff {
            HStack(spacing: 8) {
                Image(systemName: task.checksFailing ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(task.checksFailing ? Theme.State.cancelled : Theme.State.merged)
                Text(task.detail).lineLimit(1).fixedSize()
                if !compact { Spacer() }
                Text("+\(diff.added)").foregroundStyle(Theme.State.merged).fixedSize()
                Text("−\(diff.removed)").foregroundStyle(Theme.State.cancelled).fixedSize()
            }
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
        } else if task.state == .planning, task.question == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                detail
            }
        } else if task.question != nil {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.State.planning)
                detail
            }
        } else {
            detail
        }
    }

    private var detail: some View {
        Text(task.detail)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
    }

    private func bar(_ progress: Double) -> some View {
        Capsule()
            .fill(Theme.fillSelected)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(task.state.color).frame(width: proxy.size.width * progress)
                }
            }
    }
}
