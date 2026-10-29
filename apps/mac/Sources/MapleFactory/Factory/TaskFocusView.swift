import SwiftUI

/// A task opened as a full page: a document-width main column for the brief, plan, proofs and
/// conversation, with a right rail for the decision at hand and the task's details.
struct TaskFocusView: View {
    @Environment(AppState.self) private var appState
    @Environment(FactoryClient.self) private var client
    let task: FactoryTask
    @State private var mode: ComposerMode
    @State private var tab: Tab = .overview
    @FocusState private var composerFocused: Bool

    enum Tab { case overview, diff, session }

    private let mainWidth: CGFloat = 720
    private let railWidth: CGFloat = 300

    init(task: FactoryTask) {
        self.task = task
        _mode = State(initialValue: task.isSteerable ? .steer : .comment)
        // `-tab diff` opens straight onto the diff, handy for screenshots and demos.
        let start: Tab = switch AppDefaults.string(forKey: "tab") {
        case "diff": .diff
        case "session": .session
        default: .overview
        }
        _tab = State(initialValue: start)
    }

    private var requests: [ChangeRequest] { appState.changeRequests(for: task) }
    private var comments: [Comment] { task.comments + appState.postedComments[task.id, default: []] }
    private var goal: Goal { FactoryData.goal(named: task.goal) }
    private var diffFiles: [DiffFile] { appState.isLive ? client.diffs[task.id]?.files ?? [] : FactoryData.diff(for: task.id) }
    private var risk: RiskAssessment? { appState.risk(for: task) }

    private var hasSession: Bool { appState.isLive ? task.worker != nil : appState.session(for: task.id) != nil }

    var body: some View {
        Group {
            if tab == .session, hasSession { sessionLayout } else { documentLayout }
        }
        .task(id: task.diffKey) {
            if let key = task.diffKey { await client.loadDiff(task: task.id, key: key) }
        }
        .onAppear {
            if appState.pendingTab == "session", hasSession { tab = .session }
            appState.pendingTab = nil
        }
    }

    /// The live session gets the whole page: slim header, tabs, then the terminal down to the bottom.
    private var sessionLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(task.id)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                Text(task.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                StateBadge(state: task.state)
                Spacer()
            }
            tabBar
            Group {
                if appState.isLive, let worker = task.worker {
                    TaskLiveTerminal(task: task, worker: worker)
                } else if appState.isLive {
                    ContentUnavailableView {
                        Label("No session running", systemImage: "terminal")
                    } description: {
                        Text(task.state == .merged || task.state == .cancelled
                             ? "\(task.id) is \(task.state.title.lowercased()); its sessions' history is under Machines."
                             : "A planner, builder or reviewer session shows here while one works on \(task.id).")
                    }
                    .foregroundStyle(Theme.textMuted)
                } else {
                    SessionTerminal(task: task)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, compact ? 24 : 40)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: mainWidth + railWidth + 120)
        .frame(maxWidth: .infinity)
        .onDisappear { appState.markSeen(task.id) }
    }

    private var documentLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
              ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 30) {
                    header
                    StageTrack(task: task)

                    VStack(alignment: .leading, spacing: 24) {
                        tabBar
                        if compact {
                            // Narrow window: the decision goes first, then the story, then the details.
                            VStack(alignment: .leading, spacing: 28) {
                                decisionCards
                                switch tab {
                                case .overview, .session: mainColumn
                                case .diff: DiffView(task: task, files: diffFiles)
                                }
                                infoCards
                            }
                            .frame(maxWidth: mainWidth, alignment: .leading)
                        } else {
                            HStack(alignment: .top, spacing: 40) {
                                switch tab {
                                case .overview, .session: mainColumn.frame(maxWidth: mainWidth, alignment: .leading)
                                case .diff: DiffView(task: task, files: diffFiles).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                rail.frame(width: railWidth)
                            }
                        }
                    }
                }
                .padding(.horizontal, compact ? 24 : 40)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: mainWidth + railWidth + 120, alignment: .leading)
                .frame(maxWidth: .infinity)
                // `-scroll doneWhen` opens at the Done when checks, for attesting in demo videos.
                .task {
                    guard AppDefaults.string(forKey: "scroll") == "doneWhen" else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("doneWhen", anchor: .top)
                }
              }
            }
            // `-scroll bottom` opens at the timeline, handy for screenshots.
            .defaultScrollAnchor(AppDefaults.string(forKey: "scroll") == "bottom" ? .bottom : .top)
            .onDisappear { appState.markSeen(task.id) }

            HStack(alignment: .bottom, spacing: 40) {
                TaskComposer(task: task, mode: $mode, focused: $composerFocused)
                    .frame(maxWidth: mainWidth)
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
                if !compact { Color.clear.frame(width: railWidth, height: 1) }
            }
            .padding(.horizontal, compact ? 24 : 40)
            .padding(.bottom, 18)
            .padding(.top, 8)
            .frame(maxWidth: mainWidth + railWidth + 120)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(task.id)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                if task.hand != nil { NeedsHandBadge() } else if task.needsYou { NeedsYouBadge() }
                if let viewer = task.viewers.first { ViewerPill(viewer: viewer) }
                if let risk { RiskBadge(level: risk.level) }
                Spacer()
                if !appState.isLive || task.gitBranch != nil {
                    headerButton("Open branch", icon: "arrow.triangle.branch")
                        .onTapGesture { appState.openBranch(task.id) }
                }
                headerButton("Copy link", icon: "link")
                    .onTapGesture { appState.copyLink(task.id) }
                TaskActionsMenu(task: task) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }

            Text(task.title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                TaskOwnership(task: task, avatarSize: 20)
                Text("·").foregroundStyle(Theme.textFaint)
                HStack(spacing: 5) {
                    Circle().fill(goal.color).frame(width: 7, height: 7)
                    Text(goal.name)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                Text("·").foregroundStyle(Theme.textFaint)
                Text(task.updated == "now" ? "Updated just now" : "Updated \(task.updated) ago")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func headerButton(_ title: String, icon: String) -> some View {
        headerLabel(title, icon: icon).contentShape(Rectangle())
    }

    private func headerLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(title)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.fill)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
        )
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 22) {
            tabButton("Overview", tab: .overview) { EmptyView() }
            tabButton("Diff", tab: .diff, enabled: !diffFiles.isEmpty) {
                if diffFiles.isEmpty {
                    Text("No changes yet").foregroundStyle(Theme.textFaint)
                } else {
                    HStack(spacing: 4) {
                        Text("\(diffFiles.count) \(diffFiles.count == 1 ? "file" : "files")\(task.state == .building ? " so far" : "")").foregroundStyle(Theme.textMuted)
                        Text("+\(diffFiles.map(\.added).reduce(0, +))").foregroundStyle(Theme.State.merged)
                        Text("−\(diffFiles.map(\.removed).reduce(0, +))").foregroundStyle(Theme.State.cancelled)
                    }
                    .monospacedDigit()
                }
            }
            tabButton("Session", tab: .session, enabled: hasSession) {
                if appState.isLive, let worker = task.worker, waiting != nil {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.State.awaitingApproval).frame(width: 6, height: 6)
                        Text("\(worker.role) waiting for you").foregroundStyle(Theme.State.awaitingApproval)
                    }
                } else if appState.isLive, let worker = task.worker {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.State.merged).frame(width: 6, height: 6)
                        Text("\(worker.role) live on \(client.machineName(worker.machine))").foregroundStyle(Theme.textMuted)
                    }
                } else if let placement = appState.session(for: task.id) {
                    HStack(spacing: 4) {
                        Circle().fill(placement.machine.status.isOffline ? Theme.State.cancelled : Theme.State.merged).frame(width: 6, height: 6)
                        Text(placement.machine.status.isOffline ? "offline" : "live on \(placement.machine.id)")
                            .foregroundStyle(Theme.textMuted)
                    }
                } else {
                    Text("Not running").foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func tabButton<Badge: View>(_ title: String, tab target: Tab, enabled: Bool = true, @ViewBuilder badge: () -> Badge) -> some View {
        let active = tab == target

        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.text : enabled ? Theme.textMuted : Theme.textFaint)
            badge().font(.system(size: 11.5))
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            if active { Rectangle().fill(Theme.text).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { withAnimation(.snappy(duration: 0.2)) { tab = target } } }
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 32) {
            SinceLastViewedBanner(task: task)
            if let found = appState.stranded(task.id) {
                StrandedTaskBanner(machine: found.machine, session: found.session)
            }
            let liveStranded = appState.liveStranded(task.id)
            if let live = liveStranded {
                LiveStrandedBanner(task: task, name: live.name, why: live.why, lastSeen: live.lastSeen)
            }
            if task.liveLog != nil, liveStranded == nil, task.state == .planning || task.state == .building { LiveStrip(task: task) }
            if let question = task.question, task.hand == nil { QuestionBlock(task: task, question: question) }
            if let hand = task.hand { HandRaiseCard(task: task, hand: hand, showsTask: false) }
            if let review = task.autoReview, !(task.state == .cancelled && review.rounds.isEmpty) { AutoReviewSection(task: task, review: review) }

            if !task.brief.isEmpty, task.spec == nil {
                TaskSection(title: "Brief") {
                    MarkdownPreview(source: task.brief, baseSize: 14)
                }
            }

            if let spec = task.spec, !spec.isEmpty {
                TaskSection(title: "Spec") {
                    MarkdownPreview(source: spec, baseSize: 14)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.cardBG)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                        )
                }
            }

            if !task.mockups.isEmpty { MockupsSection(task: task) }
            if !task.plan.isEmpty { PlanSection(task: task) }
            if !task.doneWhen.isEmpty { DoneWhenSection(task: task).id("doneWhen") }

            TaskTimeline(task: task, comments: comments, requests: requests)
        }
    }

    // MARK: Rail

    /// Below this the rail drops under the main column.
    private var compact: Bool { appState.contentWidth < 1100 }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 24) {
            decisionCards
            infoCards
        }
    }

    /// The worker's session, when it's stopped waiting for someone (live only).
    private var waiting: Wire.Activity? {
        guard appState.isLive, let activity = client.workerActivity(for: task.worker), activity.state == .waiting else { return nil }
        return activity
    }

    @ViewBuilder private var decisionCards: some View {
            // A raised hand (the folder-trust prompt) says it already; otherwise the prompt goes first.
            if let waiting, let worker = task.worker, waiting.permission != nil || task.hand == nil {
                PermissionPromptCard(task: task, role: worker.role, prompt: waiting.permission, message: waiting.message) {
                    withAnimation(.snappy(duration: 0.2)) { tab = .session }
                }
                .id(waiting.at)
            }
            if task.state == .awaitingApproval {
                railCard { ApprovalBlock(task: task, onRequestChanges: requestChanges) }
            }
            if task.state == .reviewing {
                railCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionLabel(title: "Ready to merge?")
                            Spacer()
                            ProofMeter(criteria: task.doneWhen)
                        }
                        ReviewActions(task: task, onRequestChanges: requestChanges)
                    }
                }
            }

            if let pr = task.pr { railCard { PullRequestCard(task: task, pr: pr) } }
    }

    @ViewBuilder private var infoCards: some View {
            if !task.tickets.isEmpty || task.intakeID != nil { railCard { LinkedCard(task: task) } }
            if let risk { railCard { RiskBox(task: task, risk: risk) } }

            railCard { details }

            if !touchedFiles.isEmpty {
                TaskSection(title: "Files in plan") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(touchedFiles, id: \.self) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 10.5))
                                Text(file).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
    }

    private var touchedFiles: [String] {
        var seen = Set<String>()
        return task.plan.map(\.file).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(title: "Details")
            detailRow("Goal") {
                HStack(spacing: 5) {
                    Circle().fill(goal.color).frame(width: 7, height: 7)
                    Text(goal.name)
                }
            }
            if let repo = task.repo {
                detailRow("Repo") { Text(repo).font(.system(size: 12, design: .monospaced)) }
            }
            if !task.after.isEmpty {
                detailRow("Builds on") {
                    HStack(spacing: 6) {
                        ForEach(task.after, id: \.self) { id in
                            Text(id)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(appState.task(id).state == .merged ? Theme.State.merged : Theme.accent)
                                .onTapGesture { appState.openFocus(id) }
                                .help(appState.task(id).state == .merged ? "\(id) is merged" : "It builds once \(id) merges")
                        }
                    }
                }
            }
            if !task.followUps.isEmpty {
                detailRow("Other repos") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(task.followUps, id: \.title) { part in
                            HStack(spacing: 6) {
                                Text(part.repo).font(.system(size: 11.5, design: .monospaced))
                                if let id = part.task {
                                    Text(id)
                                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Theme.accent)
                                        .onTapGesture { appState.openFocus(id) }
                                } else {
                                    Text("once approved").foregroundStyle(Theme.textFaint)
                                }
                            }
                            .help(part.title)
                        }
                    }
                }
            }
            detailRow("Owner") {
                HStack(spacing: 6) {
                    AgentAvatar(agent: task.owner, size: 18)
                    Text(task.owner.id == FactoryData.me.id ? "You" : task.owner.firstName)
                }
            }
            if let agent = task.agent {
                detailRow("Agent") {
                    HStack(spacing: 6) {
                        AgentAvatar(agent: agent, size: 18)
                        Text(agent.name)
                    }
                }
            }
            if appState.isLive {
                if let worker = task.worker {
                    detailRow("Runs on") {
                        Text(client.machineName(worker.machine)).font(.system(size: 12, design: .monospaced))
                    }
                } else if let waiting = task.liveLog, task.state != .merged, task.state != .cancelled {
                    detailRow("Runs on") { Text(waiting).foregroundStyle(Theme.State.awaitingApproval).lineLimit(2) }
                }
            } else if let found = appState.session(for: task.id) {
                detailRow("Runs on") {
                    HStack(spacing: 6) {
                        Image(systemName: found.machine.kind.icon).font(.system(size: 11))
                        Text(found.machine.id).font(.system(size: 12, design: .monospaced))
                        Text(found.session.kind == .personal ? "personal" : found.session.kind == .lent ? "lent" : "team")
                            .foregroundStyle(Theme.textMuted)
                        if found.machine.status.isOffline {
                            Image(systemName: "wifi.slash").font(.system(size: 10)).foregroundStyle(Theme.State.cancelled)
                        }
                    }
                }
            } else if appState.queuedIDs.contains(task.id) {
                detailRow("Runs on") { Text("Queued for a slot").foregroundStyle(Theme.State.awaitingApproval) }
            }
            detailRow("Slots") { ShareableChip(task: task) }
            detailRow("Schedule") {
                Text("\(dateLabel(task.span.lowerBound)) → \(dateLabel(task.span.upperBound))")
            }
            if !task.plan.isEmpty {
                detailRow("Plan") {
                    Text(task.state == .planning
                         ? "Drafting…"
                         : "v\(task.planVersion) · \(task.plan.count) step\(task.plan.count == 1 ? "" : "s")")
                }
            }
            if !task.doneWhen.isEmpty {
                detailRow("Proofs") { Text("\(task.proven) of \(task.doneWhen.count) proven") }
            }
            if let diff = task.diff {
                detailRow("Diff") {
                    HStack(spacing: 6) {
                        Text("+\(diff.added)").foregroundStyle(Theme.State.merged)
                        Text("−\(diff.removed)").foregroundStyle(Theme.State.cancelled)
                    }
                    .monospacedDigit()
                }
            }
            detailRow("Branch") {
                Text(task.gitBranch ?? "\(task.id.lowercased())-\(slug)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var slug: String {
        task.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "-")
    }

    private func dateLabel(_ offset: Int) -> String {
        FactoryData.date(offset).formatted(.dateTime.month(.abbreviated).day())
    }

    private func detailRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 70, alignment: .leading)
            value()
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
    }

    private func railCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            )
    }

    private func requestChanges() {
        mode = .steer
        composerFocused = true
    }
}

/// A wide version of the pipeline stepper, with each stage labelled and the current one called out.
struct StageTrack: View {
    let task: FactoryTask

    var body: some View {
        let current = TaskState.pipeline.firstIndex(of: task.state)

        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(TaskState.pipeline.enumerated()), id: \.offset) { index, stage in
                let reached = current.map { index <= $0 } ?? false
                let isCurrent = index == current

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(reached ? stage.color : Theme.fillSelected)
                            .frame(height: isCurrent ? 4 : 3)
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 6) {
                        Image(systemName: stage.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(reached ? stage.color : Theme.textFaint)
                        Text(stage.title)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Theme.text : reached ? Theme.textMuted : Theme.textFaint)
                            .lineLimit(1)
                    }
                    if isCurrent {
                        Text(currentNote)
                            .font(.system(size: 11))
                            .foregroundStyle(stage.color)
                            .lineLimit(1)
                    } else if task.state == .cancelled && stage == .merged {
                        Text("Cancelled before merge")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.State.cancelled)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, index < TaskState.pipeline.count - 1 ? 6 : 0)
            }
        }
    }

    private var currentNote: String {
        switch task.state {
        case .planning: task.question == nil ? "Agent is drafting" : "Blocked on a question"
        case .awaitingApproval: "\(task.approvals.count) of \(task.approvalsNeeded) approvals"
        case .building: task.plan.isEmpty ? "In progress" : "Step \((task.activeStep ?? 0) + 1) of \(task.plan.count)"
        case .reviewing:
            if let round = task.autoReview?.current {
                "Review round \(round.number) of \(task.autoReview?.maxRounds ?? 5)"
            } else {
                "\(task.proven) of \(task.doneWhen.count) proofs"
            }
        default: "Now"
        }
    }
}
