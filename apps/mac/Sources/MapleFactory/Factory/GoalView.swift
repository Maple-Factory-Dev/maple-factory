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
                if let due = FactoryData.dueLabel(goal) {
                    Text("·")
                    Text(FactoryData.isOverdue(goal) ? "Due \(due) · overdue" : "Due \(due)")
                        .foregroundStyle(FactoryData.isOverdue(goal) ? Theme.State.cancelled : Theme.textMuted)
                }
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

            // Whole items wrap to a second row when the states don't fit, so no title is squeezed
            // and broken mid-word (MF-40).
            FlowLayout(spacing: 14, lineSpacing: 6) {
                ForEach(populated, id: \.state) { entry in
                    HStack(spacing: 5) {
                        Circle().fill(entry.state.color).frame(width: 6, height: 6)
                        Text("\(entry.count)").foregroundStyle(Theme.text).monospacedDigit()
                        Text(entry.state.title).lineLimit(1)
                    }
                    .fixedSize()
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
    /// A card dragged over the Queued column's empty space, to go to the back.
    @State private var queueTargeted = false

    var body: some View {
        // In a narrow window the columns overflow: a scrollbar shows and the cut-off edge fades.
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                column(.drafting)
                queueColumn
                ForEach(TaskState.allCases.filter { $0 != .drafting }) { taskState in
                    column(taskState)
                    if taskState == .reviewing { pendingColumn }
                }
            }
            .animation(.snappy, value: populatedStates)
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

    /// An empty column shrinks to a slim rail, so the columns with cards get the room.
    static func isRail(count: Int) -> Bool { count == 0 }

    /// The states with cards in their own column; the board animates when this changes.
    private var populatedStates: Set<String> {
        Set(tasks.filter { !$0.queued }.map { state.pendingMerge($0) ? "pendingMerge" : $0.state.title })
    }

    /// Queued tasks wait in Queued until a session picks them up, not in their state's column;
    /// ready reviewing tasks that a person merges wait in Pending merge.
    @ViewBuilder
    private func column(_ taskState: TaskState) -> some View {
        let columnTasks = tasks.filter { $0.state == taskState && !$0.queued && !state.pendingMerge($0) }

        Group {
            if Self.isRail(count: columnTasks.count) {
                EmptyColumnRail(icon: taskState.icon, title: taskState.title, color: taskState.color, hint: taskState.emptyHint)
            } else {
                shell(icon: taskState.icon, title: taskState.title, color: taskState.color, tasks: columnTasks) {
                    ForEach(columnTasks) { task in
                        BoardCard(task: task, draggable: task.state == .drafting)
                    }
                }
            }
        }
        .transition(.opacity)
        .opacity(taskState == .cancelled ? 0.7 : 1)
    }

    /// Reviewed, proven and green, and waiting for a person: auto-merge is off for its risk level or the factory.
    @ViewBuilder
    private var pendingColumn: some View {
        let pending = tasks.filter { !$0.queued && state.pendingMerge($0) }
        let icon = "arrow.triangle.pull", title = "Pending merge", color = Theme.State.pendingMerge

        Group {
            if Self.isRail(count: pending.count) {
                EmptyColumnRail(icon: icon, title: title, color: color,
                                hint: "Tasks land here once they're proven, reviewed and green, and a person merges them.")
            } else {
                shell(icon: icon, title: title, color: color, tasks: pending) {
                    ForEach(pending) { task in
                        BoardCard(task: task, mergeButton: true)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    /// Every task waiting for a session, front of the queue first. Drag a card onto another to put
    /// it ahead of that one, or below the cards to send it to the back; a draft dragged in joins.
    private var queueColumn: some View {
        let queued = tasks.filter(\.queued).sorted { $0.queueRank < $1.queueRank }
        return shell(icon: "list.number", title: "Queued", color: Theme.textMuted, tasks: queued) {
            ForEach(Array(queued.enumerated()), id: \.element.id) { index, task in
                BoardCard(task: task, position: index + 1, draggable: true) { dropped in
                    guard dropped != task.id else { return }
                    state.queue(dropped, before: task.id)
                }
            }
            // An empty queue keeps a roomy box to drop a draft into.
            if queued.isEmpty {
                Text("Drag a draft here to queue it")
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
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.State.building.opacity(queueTargeted ? 0.6 : 0), lineWidth: 1.5)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, state.tasks.contains(where: { $0.id == id }) else { return false }
            state.moveToBottom(id)
            return true
        } isTargeted: { queueTargeted = $0 }
    }

    private func shell<Cards: View>(icon: String, title: String, color: Color, tasks columnTasks: [FactoryTask], @ViewBuilder cards: () -> Cards) -> some View {
        let content = cards()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
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
                VStack(spacing: 8) { content }
                ScrollView { VStack(spacing: 8) { content }.padding(.trailing, 6) }.scrollIndicators(.automatic)
            }
        }
        .padding(8)
        .frame(width: 240, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.columnBG))
    }
}

/// A card on the board, with its actions on right-click (the queue's, Retry, Cancel…, Rename… and the rest).
private struct BoardCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var position: Int? = nil
    var draggable = false
    /// Pending merge's cards: Merge right on the card.
    var mergeButton = false
    /// A card dropped on this one, to go ahead of it.
    var onDrop: ((String) -> Void)? = nil
    @State private var confirmCancel = false
    @State private var rename = false
    @State private var scheduling = false
    @State private var targeted = false

    var body: some View {
        let card = TaskCard(task: task, selected: task.id == state.openedTask, position: position, mergeButton: mergeButton)
            .taskClicks(task.id)
            .contextMenu {
                TaskActionButtons(task: task, confirmCancel: $confirmCancel, rename: $rename, schedule: { scheduling = true })
            }
            .cancelTaskConfirmation(task: task, isPresented: $confirmCancel)
            .renameTask(task: task, isPresented: $rename)
            .popover(isPresented: Binding(get: { scheduling || state.schedulingTask == task.id },
                                          set: { if !$0 { scheduling = false; state.schedulingTask = nil } }),
                     arrowEdge: .trailing) { SchedulePopover(task: task) }
            // Where a dropped card lands: a line above this one.
            .overlay(alignment: .top) {
                if targeted {
                    Capsule().fill(Theme.State.building).frame(height: 3).offset(y: -6)
                }
            }
        if draggable {
            if let onDrop {
                card
                    .draggable(task.id) { TaskCard(task: task, selected: false, position: position).frame(width: 224) }
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first else { return false }
                        onDrop(id)
                        return true
                    } isTargeted: { targeted = $0 }
            } else {
                card.draggable(task.id) { TaskCard(task: task, selected: false).frame(width: 224) }
            }
        } else {
            card
        }
    }
}

/// Holds a task until a time: quick picks fill the date picker, which can also be set by hand.
struct SchedulePopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let task: FactoryTask
    @State private var at: Date

    init(task: FactoryTask) {
        self.task = task
        _at = State(initialValue: task.startAt ?? SchedulePopover.picks[0].date())
    }

    /// Tonight 12 AM, In 1 hour, Tomorrow 9 AM.
    static let picks: [(label: String, date: () -> Date)] = [
        ("Tonight 12 AM", { Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)) }),
        ("In 1 hour", { Date().addingTimeInterval(3600) }),
        ("Tomorrow 9 AM", {
            let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start \(task.id) after…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            HStack(spacing: 6) {
                ForEach(Self.picks, id: \.label) { pick in
                    let date = pick.date()
                    let on = abs(date.timeIntervalSince(at)) < 60
                    Text(pick.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(on ? .white : Theme.text)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.State.building : Theme.fill))
                        .contentShape(Rectangle())
                        .onTapGesture { at = date }
                }
            }
            DatePicker("Starts", selection: $at, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            Text("It keeps its place in the queue and starts at the first free slot after this.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if task.startAt != nil {
                    Button("Clear") {
                        state.unschedule(task.id)
                        dismiss()
                    }
                }
                Button("Schedule") {
                    state.schedule(task.id, at: at)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// "Starts 12:00 AM" on a scheduled task; the day too when it isn't within a day.
struct ScheduleBadge: View {
    let at: Date

    var body: some View {
        let soon = at.timeIntervalSinceNow < 86400
        HStack(spacing: 3) {
            Image(systemName: "clock").font(.system(size: 9.5, weight: .semibold))
            Text("Starts \(soon ? at.formatted(date: .omitted, time: .shortened) : at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.State.awaitingApproval)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Theme.State.awaitingApproval.opacity(0.14)))
        .help(at.formatted(date: .complete, time: .shortened))
    }
}

/// An empty column, kept as a quiet slot so the pipeline still reads left to right.
private struct EmptyColumnRail: View {
    let icon: String
    let title: String
    let color: Color
    let hint: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text("0")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
            // The title runs down the rail; it's laid out flat and turned, so it isn't clipped.
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .fixedSize()
                .modifier(Upright())
        }
        .padding(.vertical, 12)
        // At least as tall as a short column; a long title makes the rail taller instead of spilling.
        .frame(width: 44, alignment: .top)
        .frame(minHeight: 168, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.columnBG.opacity(0.5))
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(hint)
    }
}

/// Turns its content a quarter turn and lays it out at the turned size, so a vertical title
/// takes up exactly as much height as it's long.
private struct Upright: ViewModifier {
    func body(content: Content) -> some View {
        Turned { content.rotationEffect(.degrees(90)) }
    }

    private struct Turned: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
            return CGSize(width: size.height, height: size.width)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        }
    }
}

struct TaskCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let selected: Bool
    /// Its place in the Queued column.
    var position: Int? = nil
    /// A Merge button under it, for Pending merge.
    var mergeButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let position {
                    Text("#\(position)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.State.building)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.State.building.opacity(0.14)))
                }
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

            if let effort = task.effort { EffortChip(effort: effort) }

            if task.queued {
                QueuedFooter(task: task)
            } else {
                TaskProgressFooter(task: task)
            }

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

            if mergeButton {
                PrimaryButton(title: "Merge", icon: "arrow.triangle.merge", busy: state.isInFlight(task.id, .merge),
                              busyTitle: "Merging…") {
                    state.merge(task.id)
                }
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

/// What a queued task runs next, its schedule, and why it's waiting.
struct QueuedFooter: View {
    let task: FactoryTask

    var body: some View {
        FlowLayout(spacing: 6) {
            Text("Next: \(task.nextStep)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(Theme.fill))
            if task.scheduled, let at = task.startAt {
                ScheduleBadge(at: at)
            } else if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
            }
        }
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
