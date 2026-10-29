import SwiftUI

struct GoalView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let name: String

    /// Read from the live goals as the view draws, so a rename, new lead or due date shows at once.
    private var goal: Goal { FactoryData.goal(named: name) }

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
                if let team = goal.team {
                    Text("·")
                    Text("@\(team)").foregroundStyle(Theme.text)
                }
                if !goal.lead.name.isEmpty {
                    Text("·")
                    Text("Lead")
                    AgentAvatar(agent: goal.lead, size: 16)
                    Text(goal.lead.id == FactoryData.me.id ? "You" : goal.lead.firstName)
                        .foregroundStyle(Theme.text)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)

            HStack(alignment: .center) {
                Text(goal.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                FollowButton(following: state.isFollowing(goal)) { state.setFollowing(goal, !state.isFollowing(goal)) }
                    .padding(.trailing, 6)
                RiskPolicyButton()
                    .padding(.trailing, 10)
                if state.isLive, let live = client.goal(named: goal.name) {
                    Menu {
                        Button("Edit Goal…") { state.goalSheet = .edit(live.id) }
                        Divider()
                        Button(goal.archived ? "Unarchive" : "Archive Goal…") { state.archive(goal, !goal.archived) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.trailing, 8)
                }
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

    /// Whether columns are cut off past the trailing edge, so the board fades there.
    @State private var moreTrailing = false

    var body: some View {
        // In a narrow window the columns overflow: a scrollbar shows and the cut-off edge fades.
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskState.allCases) { taskState in
                    column(taskState)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.width - geometry.visibleRect.maxX > 1
        } action: { _, more in
            withAnimation(.easeOut(duration: 0.15)) { moreTrailing = more }
        }
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(moreTrailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 24)
            }
        }
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
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            // A column hugs its cards until they outgrow the window, then scrolls on its own.
            ViewThatFits(in: .vertical) {
                cards(columnTasks)
                ScrollView { cards(columnTasks).padding(.trailing, 6) }.scrollIndicators(.automatic)
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

    private func cards(_ columnTasks: [FactoryTask]) -> some View {
        VStack(spacing: 8) {
            ForEach(columnTasks) { task in
                TaskCard(task: task, selected: task.id == state.openedTask)
                    .taskClicks(task.id)
            }
        }
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
                if let repo = task.repo {
                    // The repo's short name: goals that span repos say which one each card is in.
                    Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(Theme.fill))
                        .help(repo)
                }
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
                Text(task.detail).lineLimit(1).truncationMode(.tail)
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

/// A click opens the task per the "When you click a task" setting. Double-click opens the full view
/// only in the panel mode; in the full-view mode it would hold back every single click.
private struct TaskClicks: ViewModifier {
    let id: String
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        if state.taskOpening == .panel {
            content
                .onTapGesture(count: 2) { state.openFocus(id) }
                .onTapGesture { state.toggleTask(id) }
        } else {
            content.onTapGesture { state.toggleTask(id) }
        }
    }
}

extension View {
    func taskClicks(_ id: String) -> some View {
        modifier(TaskClicks(id: id))
    }
}
