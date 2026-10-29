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
    private var openRequests: [ChangeRequest] { requests.filter { $0.status != .applied } }
    private var comments: [Comment] { task.comments + appState.postedComments[task.id, default: []] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(task.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                if let risk = appState.risk(for: task) { RiskBadge(level: risk.level) }
                if let viewer = task.viewers.first {
                    ViewerPill(viewer: viewer).padding(.leading, 4)
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openFull)
                    .help("Open full view (⌘↩)")
                Button(action: appState.closeTaskPanel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // While typing, Esc leaves the composer (keeping the draft) instead of closing the panel.
                .keyboardShortcut(composerFocused ? nil : .cancelAction)
                .help("Close (Esc)")
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 18)
            .frame(height: 46)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(task.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        TaskOwnership(task: task)
                    }
                    SinceLastViewedBanner(task: task, compact: true)
                    PipelineStepper(state: task.state)
                    // What needs attention now comes first; the rest is a line each, opening the full view.
                    if task.liveLog != nil, task.state == .planning || task.state == .building { LiveStrip(task: task) }
                    if let question = task.question, task.hand == nil { QuestionBlock(task: task, question: question) }
                    if let hand = task.hand { InspectorHandCallout(task: task, hand: hand) }
                    if task.state == .awaitingApproval { ApprovalBlock(task: task, onRequestChanges: requestChanges) }
                    if task.state == .reviewing { ReviewActions(task: task, onRequestChanges: requestChanges) }
                    // Only what's still waiting; applied requests are history, kept in the full view.
                    if !openRequests.isEmpty {
                        TaskSection(title: "Changes requested") { ChangeRequestList(task: task, requests: openRequests) }
                    }
                    if !task.brief.isEmpty {
                        TaskSection(title: "Brief") { BriefPeek(brief: task.brief, openFull: openFull) }
                    }
                    if hasSummaries {
                        PeekGroup {
                            if !task.plan.isEmpty { PeekRow(icon: "list.number", title: planTitle, detail: planDetail, action: openFull) }
                            if !task.doneWhen.isEmpty {
                                PeekRow(icon: "checkmark.seal", title: "Done when", detail: doneWhenDetail, action: openFull) {
                                    if collectingProof { ProofMeter(criteria: task.doneWhen) }
                                }
                            }
                            if let review = task.autoReview, let round = review.current {
                                PeekRow(icon: "eye", title: "Review", detail: "round \(round.number) of \(review.maxRounds)", action: openFull) {
                                    VerdictPill(verdict: round.verdict)
                                }
                            }
                            if let pr = task.pr { PullRequestRow(pr: pr, openFull: openFull) }
                        }
                    }
                    if !comments.isEmpty { DiscussionPeek(comments: comments, openFull: openFull) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
            .defaultScrollAnchor(.top)
            .onDisappear {
                // Moving to another task counts as having seen this one; opening it full-screen doesn't.
                if appState.focusedTask != task.id { appState.markSeen(task.id) }
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                Text("Open full view")
                Spacer()
                Text("⌘↩").foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: openFull)

            TaskComposer(task: task, mode: $mode, focused: $composerFocused)
                .padding(16)
        }
    }

    private var hasSummaries: Bool {
        !task.plan.isEmpty || !task.doneWhen.isEmpty || task.autoReview?.current != nil || task.pr != nil
    }

    private var collectingProof: Bool { [.building, .reviewing, .merged].contains(task.state) }

    private var planTitle: String {
        switch task.state {
        case .planning: "Draft plan"
        case .building: "Progress"
        default: "Plan"
        }
    }

    private var planDetail: String {
        let steps = task.plan.count == 1 ? "1 step" : "\(task.plan.count) steps"
        guard task.state == .building else { return steps }
        return "\(task.plan.filter { $0.progress == .done }.count) of \(steps)"
    }

    private var doneWhenDetail: String {
        if collectingProof { return "\(task.proven) of \(task.doneWhen.count) proven" }
        return task.doneWhen.count == 1 ? "1 check" : "\(task.doneWhen.count) checks"
    }

    private func openFull() { appState.openFocus(task.id) }

    private func requestChanges() {
        mode = .steer
        composerFocused = true
    }
}

/// The six pipeline stages as a connected track, with everything up to the current state filled in.
/// The brief, rendered, but only its top: a long one fades out under a "Show all" that opens the full view.
private struct BriefPeek: View {
    let brief: String
    let openFull: () -> Void
    @State private var height: CGFloat = 0

    private static let cap: CGFloat = 180
    private var overflows: Bool { height > Self.cap + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownPreview(source: brief, baseSize: 12.5, thumbnails: true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
                .frame(maxHeight: Self.cap, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: overflows ? 0.7 : 1), .init(color: .black.opacity(overflows ? 0 : 1), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            if overflows {
                Text("Show all")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openFull)
                    .help("Open full view (⌘↩)")
            }
        }
    }
}

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
