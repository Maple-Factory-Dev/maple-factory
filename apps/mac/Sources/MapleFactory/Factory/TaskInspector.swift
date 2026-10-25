import SwiftUI

struct TaskInspector: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @State private var mode: ComposerMode
    @FocusState private var composerFocused: Bool

    init(task: FactoryTask) {
        self.task = task
        _mode = State(initialValue: task.isSteerable ? .steer : .comment)
    }

    private var requests: [ChangeRequest] { appState.changeRequests(for: task) }
    private var comments: [Comment] { task.comments + appState.postedComments[task.id, default: []] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(task.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                if let viewer = task.viewers.first {
                    ViewerPill(viewer: viewer).padding(.leading, 4)
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.openFocus(task.id) }
                    .help("Open full view (⌘↩)")
                Image(systemName: "ellipsis").padding(.leading, 4)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 18)
            .frame(height: 46)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(task.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        TaskOwnership(task: task)
                    }
                    SinceLastViewedBanner(task: task, compact: true)
                    PipelineStepper(state: task.state)
                    if task.liveLog != nil, task.state == .planning || task.state == .building { LiveStrip(task: task) }
                    if let question = task.question, task.hand == nil { QuestionBlock(task: task, question: question) }
                    if let hand = task.hand { InspectorHandCallout(task: task, hand: hand) }
                    if let review = task.autoReview, let round = review.current {
                        TaskSection(title: "Automated review") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Round \(round.number) of \(review.maxRounds)")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    VerdictPill(verdict: round.verdict)
                                }
                                RoundTrack(review: review)
                                Text(review.summary)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(4)
                            }
                        }
                    }
                    if !task.brief.isEmpty {
                        TaskSection(title: "Brief") {
                            Text(task.brief)
                                .font(Theme.uiFont)
                                .foregroundStyle(Theme.text.opacity(0.88))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !task.plan.isEmpty { PlanSection(task: task) }
                    if !task.doneWhen.isEmpty { DoneWhenSection(task: task) }
                    if let risk = appState.risk(for: task) { RiskBox(task: task, risk: risk) }
                    if let pr = task.pr { PullRequestCard(task: task, pr: pr) }
                    if task.state == .awaitingApproval { ApprovalBlock(task: task, onRequestChanges: requestChanges) }
                    if task.state == .reviewing { ReviewActions(task: task, onRequestChanges: requestChanges) }
                    if !requests.isEmpty {
                        TaskSection(title: "Changes requested") { ChangeRequestList(task: task, requests: requests) }
                    }
                    if !comments.isEmpty { TaskSection(title: "Discussion") { DiscussionList(comments: comments) } }
                    if !task.activity.isEmpty { TaskSection(title: "Activity") { ActivityFeed(items: task.activity) } }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
            .defaultScrollAnchor(.top)
            .onDisappear {
                // Moving to another task counts as having seen this one; opening it full-screen doesn't.
                if appState.focusedTask != task.id { appState.markSeen(task.id) }
            }

            TaskComposer(task: task, mode: $mode, focused: $composerFocused)
                .padding(16)
        }
    }

    private func requestChanges() {
        mode = .steer
        composerFocused = true
    }
}

/// The six pipeline stages as a connected track, with everything up to the current state filled in.
struct PipelineStepper: View {
    let state: TaskState

    var body: some View {
        let current = TaskState.pipeline.firstIndex(of: state)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(TaskState.pipeline.enumerated()), id: \.offset) { index, stage in
                    let reached = current.map { index <= $0 } ?? false
                    let isCurrent = index == current

                    ZStack {
                        Circle()
                            .fill(reached ? stage.color : Theme.fill)
                            .frame(width: isCurrent ? 22 : 16, height: isCurrent ? 22 : 16)
                        Image(systemName: stage.icon)
                            .font(.system(size: isCurrent ? 10 : 7.5, weight: .bold))
                            .foregroundStyle(reached ? Theme.onAccent : Theme.textFaint)
                    }
                    .overlay {
                        if isCurrent {
                            Circle().stroke(stage.color.opacity(0.3), lineWidth: 4).frame(width: 28, height: 28)
                        }
                    }
                    .help(stage.title)

                    if index < TaskState.pipeline.count - 1 {
                        Rectangle()
                            .fill(current.map { index < $0 } ?? false ? stage.color.opacity(0.6) : Theme.fillSelected)
                            .frame(height: 2)
                    }
                }
            }
            .frame(height: 30)

            if state == .cancelled {
                Text("Cancelled — stopped before merge")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.State.cancelled)
            } else if let current {
                Text("Stage \(current + 1) of \(TaskState.pipeline.count) · \(state.title)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}
