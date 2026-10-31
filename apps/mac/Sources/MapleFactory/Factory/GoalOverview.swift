import SwiftUI

/// A goal sorted by what you should do with it: what's waiting on you across the top, what's up next
/// (drafts and the queue, in order and draggable) beside what's moving, and what landed lately below.
struct GoalOverview: View {
    @Environment(AppState.self) private var state
    let goal: Goal
    let tasks: [FactoryTask]

    /// Which sections are folded to their header, remembered across launches.
    @AppStorage("overviewCollapsed") private var collapsedRaw = OverviewCollapse.defaultRaw
    /// A draft dragged over Drafts' empty space, to go to the bottom; a task over Queue's, to go to the back.
    @SwiftUI.State private var draftsTargeted = false
    @SwiftUI.State private var queueTargeted = false

    var body: some View {
        let sections = GoalOverviewSections(tasks: tasks, today: FactoryData.todayOffset, pendingMerge: state.pendingMerge)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                needsYou(sections.needsYou)
                if sections.isQuiet && sections.recentlyLanded.isEmpty {
                    Text("No tasks in this goal")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    // Side by side when there's room; Up next above In motion when there isn't.
                    if state.contentWidth < 820 {
                        VStack(alignment: .leading, spacing: 24) { upNext(sections); inMotion(sections.inMotion) }
                    } else {
                        HStack(alignment: .top, spacing: 20) {
                            upNext(sections).frame(maxWidth: .infinity, alignment: .topLeading)
                            inMotion(sections.inMotion).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    recentlyLanded(sections.recentlyLanded)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        // Drafts and the queue animate when a person drops a row (withAnimation there), not on each live update.
        .animation(.snappy, value: sections.needsYou.map(\.id))
    }

    private var collapse: OverviewCollapse { OverviewCollapse(raw: collapsedRaw) }

    private func isOpen(_ section: OverviewSection) -> Bool { !collapse.isCollapsed(section) }

    private func toggle(_ section: OverviewSection) {
        withAnimation(.snappy) { collapsedRaw = collapse.toggling(section).raw }
    }

    // MARK: Needs you

    @ViewBuilder
    private func needsYou(_ waiting: [GoalOverviewSections.Waiting]) -> some View {
        if waiting.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.State.merged)
                Text("Nothing waiting on you")
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.columnBG))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header(icon: "exclamationmark.circle.fill", title: "Needs you", count: waiting.count, color: Theme.State.awaitingApproval,
                       section: .needsYou)
                if isOpen(.needsYou) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(waiting) { NeedsYouCard(waiting: $0) }
                    }
                }
            }
        }
    }

    // MARK: Up next

    private func upNext(_ sections: GoalOverviewSections) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "arrow.right.circle", title: "Up next", count: sections.drafts.count + sections.queued.count + sections.planning.count,
                   color: Theme.State.building, section: .upNext)
            if isOpen(.upNext) { upNextLanes(sections) }
        }
    }

    @ViewBuilder
    private func upNextLanes(_ sections: GoalOverviewSections) -> some View {
        lane(icon: "list.number", title: "Queue", count: sections.queued.count, color: Theme.State.building, section: .queue,
             targeted: queueTargeted) {
            ForEach(Array(sections.queued.enumerated()), id: \.element.id) { index, task in
                OverviewRow(task: task, position: index + 1, drop: .queueAhead)
            }
            if sections.queued.isEmpty { placeholder("Drag a draft here to queue it") }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, state.tasks.contains(where: { $0.id == id }) else { return false }
            withAnimation(.snappy) { state.moveToBottom(id) }
            return true
        } isTargeted: { queueTargeted = $0 }

        lane(icon: TaskState.drafting.icon, title: "Drafts", count: sections.drafts.count, color: TaskState.drafting.color, section: .drafts,
             targeted: draftsTargeted) {
            ForEach(sections.drafts) { task in
                OverviewRow(task: task, drop: .draftAhead)
            }
            if sections.drafts.isEmpty { placeholder("No drafts") }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, sections.drafts.contains(where: { $0.id == id }) else { return false }
            withAnimation(.snappy) { state.rankDraft(id, before: nil) }
            return true
        } isTargeted: { draftsTargeted = $0 }

        if !sections.planning.isEmpty {
            lane(icon: TaskState.planning.icon, title: "Planning", count: sections.planning.count, color: TaskState.planning.color,
                 section: .planning, targeted: false) {
                ForEach(sections.planning) { OverviewRow(task: $0) }
            }
        }
    }

    // MARK: In motion

    private func inMotion(_ moving: [FactoryTask]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "bolt.fill", title: "In motion", count: moving.count, color: Theme.State.reviewing, section: .inMotion)
            if isOpen(.inMotion) {
                lane(targeted: false) {
                    ForEach(moving) { OverviewRow(task: $0, showsProgress: true) }
                    if moving.isEmpty { placeholder("Nothing building or in review") }
                }
            }
        }
    }

    // MARK: Recently landed

    @ViewBuilder
    private func recentlyLanded(_ landed: [FactoryTask]) -> some View {
        if !landed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    toggle(.landed)
                } label: {
                    HStack(spacing: 8) {
                        chevron(open: isOpen(.landed))
                        Image(systemName: TaskState.merged.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TaskState.merged.color)
                        Text("Recently landed · \(landed.count)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isOpen(.landed) {
                    lane(targeted: false) {
                        ForEach(landed) { OverviewRow(task: $0) }
                    }
                }
            }
        }
    }

    // MARK: Parts

    private func chevron(open: Bool) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 10)
    }

    /// A section's title and count; with a section, a toggle that folds it to this line.
    @ViewBuilder
    private func header(icon: String, title: String, count: Int, color: Color, section: OverviewSection? = nil) -> some View {
        if let section {
            Button { toggle(section) } label: {
                headerLabel(icon: icon, title: title, count: count, color: color, chevronOpen: isOpen(section))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            headerLabel(icon: icon, title: title, count: count, color: color, chevronOpen: nil)
        }
    }

    private func headerLabel(icon: String, title: String, count: Int, color: Color, chevronOpen: Bool?) -> some View {
        HStack(spacing: 7) {
            if let chevronOpen { chevron(open: chevronOpen) }
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("\(count)")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
            Spacer()
        }
    }

    /// A box of rows, under a small title when it has one. With a section, the title folds the lane to
    /// itself; a collapsed lane still takes drops, outlined around its title.
    private func lane<Rows: View>(icon: String? = nil, title: String? = nil, count: Int = 0, color: Color = Theme.textMuted,
                                  section: OverviewSection? = nil, targeted: Bool, @ViewBuilder rows: () -> Rows) -> some View {
        let open = section.map(isOpen) ?? true
        return VStack(alignment: .leading, spacing: 6) {
            if let title {
                let titleRow = HStack(spacing: 6) {
                    if let section { chevron(open: isOpen(section)) }
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text("\(count)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                    if section != nil { Spacer() }
                }
                .padding(.horizontal, 4)
                if let section {
                    Button { toggle(section) } label: {
                        titleRow
                            .padding(.vertical, open ? 0 : 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.State.building.opacity(targeted && !open ? 0.6 : 0), lineWidth: 1.5)
                    }
                } else {
                    titleRow
                }
            }
            if open {
                // Lazy within the page's scroll view: a long queue lays out only the rows in view.
                LazyVStack(spacing: 0) { rows() }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.columnBG))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.State.building.opacity(targeted ? 0.6 : 0), lineWidth: 1.5)
                    }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
    }
}

/// A task waiting on you: what it's waiting for, and the button that takes you to it.
private struct NeedsYouCard: View {
    @Environment(AppState.self) private var state
    let waiting: GoalOverviewSections.Waiting

    private var task: FactoryTask { waiting.task }

    private var color: Color {
        switch waiting.reason {
        case .hand: task.hand?.reason.color ?? Theme.State.cancelled
        case .question: Theme.State.planning
        case .approval: Theme.State.awaitingApproval
        case .review: Theme.State.reviewing
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: waiting.reason.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(task.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Text(task.state.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(task.updated)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
                AvatarPair(owner: task.owner, agent: task.agent)
            }
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(waiting.why)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PrimaryButton(title: waiting.reason.action, icon: waiting.reason.icon, color: color) {
                if state.taskOpening == .fullView { state.openFocus(task.id) } else { state.openTask(task.id) }
            }
            .frame(maxWidth: 180)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.cardBG)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(color).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(state.openedTask == task.id ? color : Theme.stroke, lineWidth: state.openedTask == task.id ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .taskClicks(task.id)
    }
}

/// One task in a lane: a numbered queue row, a draggable draft, or a moving task with its progress.
/// Right-click has the task's actions, the queue's and drafts' Move to top and bottom among them.
private struct OverviewRow: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var position: Int? = nil
    /// What a row dropped on this one does: goes ahead of it, the board's rules.
    var drop: Drop? = nil
    var showsProgress = false

    enum Drop {
        case draftAhead, queueAhead
    }

    @SwiftUI.State private var confirmCancel = false
    @SwiftUI.State private var rename = false
    @SwiftUI.State private var scheduling = false
    @SwiftUI.State private var targeted = false
    @SwiftUI.State private var hovering = false

    var body: some View {
        let row = content
            .taskClicks(task.id)
            .contextMenu {
                TaskActionButtons(task: task, confirmCancel: $confirmCancel, rename: $rename, schedule: { scheduling = true })
            }
            .taskPresentations(task: task, confirmCancel: $confirmCancel, rename: $rename, scheduling: $scheduling)
            .overlay(alignment: .top) {
                if targeted {
                    Capsule().fill(Theme.State.building).frame(height: 3).offset(y: -2)
                }
            }
        if let drop {
            row
                .draggable(task.id) { content.frame(width: 360).background(Theme.cardBG) }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    switch drop {
                    case .draftAhead:
                        let dropped = state.task(id)
                        guard dropped.id == id, dropped.state == .drafting, !dropped.queued, dropped.goal == task.goal else { return false }
                        if id != task.id { withAnimation(.snappy) { state.rankDraft(id, before: task.id) } }
                    case .queueAhead:
                        if id != task.id { withAnimation(.snappy) { state.queue(id, before: task.id) } }
                    }
                    return true
                } isTargeted: { targeted = $0 }
        } else {
            row
        }
    }

    private var content: some View {
        let selected = state.openedTask == task.id
        return HStack(spacing: 10) {
            if drop != nil {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .opacity(hovering ? 1 : 0.4)
            }
            if let position {
                Text("\(position)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.State.building)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.State.building.opacity(0.14)))
            } else if !showsProgress {
                Image(systemName: task.state.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(task.state.color)
                    .frame(width: 18)
            }
            Text(task.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textFaint)
                .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if showsProgress {
                    HStack(spacing: 8) {
                        Label(task.state.title, systemImage: task.state.icon)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(task.state.color)
                            .fixedSize()
                        // Unless its detail line already says which step it's on.
                        if let steps = GoalOverviewSections.steps(task), !task.detail.localizedCaseInsensitiveContains("step ") {
                            Text("Step \(min(steps.done + 1, steps.total)) of \(steps.total)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize()
                        }
                        TaskProgressFooter(task: task, compact: true)
                    }
                } else if task.queued {
                    Text("Next: \(task.nextStep)\(task.detail.isEmpty ? "" : " · \(task.detail)")")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if task.scheduled, let at = task.startAt { ScheduleBadge(at: at) }
            if let effort = task.effort, !showsProgress { EffortChip(effort: effort) }
            AvatarPair(owner: task.owner, agent: task.agent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.fillSelected : hovering ? Theme.fillSubtle : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
