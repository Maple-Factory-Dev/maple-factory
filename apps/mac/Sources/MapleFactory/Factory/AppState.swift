import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let text: String
    let color: Color

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Everything a merge depends on, in one place so buttons, copy and auto-merge agree.
struct MergeGate {
    let proofsReady: Bool
    let failedProofs: Int
    let unproven: Int
    let checksReady: Bool
    let failedChecks: Int
    let reviewsNeeded: Int
    let reviewsReady: Bool
    let autoMerge: Bool
    /// The factory's own reviewer has passed the latest round; the server refuses approvals and merges until then.
    let autoReviewReady: Bool
    let autoReviewDetail: String?
    /// The round still under way, if the reviewer is working on one now.
    let autoReviewRound: Int?

    var canMerge: Bool { proofsReady && checksReady && reviewsReady && autoReviewReady }
}

@MainActor @Observable
final class AppState {
    // MARK: Navigation

    var destination: Destination = .goal("Auth overhaul") {
        didSet {
            focusedTask = nil
            isComposing = false
        }
    }
    var layout: GoalLayout = .board {
        didSet { focusedTask = nil }
    }
    /// A task opened full-screen in place of the board/list/timeline.
    var focusedTask: String? = nil
    /// The task whose ⋯ menu shows its cancel confirmation, when a demo script opened it (`cancelask:<id>`).
    var confirmingCancel: String? = nil
    /// The task whose board card shows its Schedule… popover, when a demo script opened it (`scheduleask:<id>`).
    var schedulingTask: String? = nil
    /// The task panel opens when a task is clicked, or when it was left open with the toolbar toggle.
    var showInspector = AppState.panelLeftOpen
    /// Whether the panel was left open in a full-width window. Its own key: the old "taskPanel" was
    /// written on every toggle while the panel opened by default, so it's true for most people.
    private static let panelKey = "taskPanelOpen"
    private static var panelLeftOpen: Bool {
        UserDefaults.standard.removeObject(forKey: "taskPanel")
        return UserDefaults.standard.bool(forKey: panelKey)
    }
    /// The task the panel shows. Following the goal on screen never opens the panel; `openTask` does.
    var selectedTask = "ATL-147"
    /// The task showing in the panel, which is what a card or row highlights; nil while it's closed.
    var openedTask: String? { showInspector ? selectedTask : nil }

    /// A card or row was clicked: show it in the task panel.
    func openTask(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) {
            selectedTask = id
            showInspector = true
        }
    }

    /// Clicking the task already open in the panel closes the panel; any other task opens.
    func toggleTask(_ id: String) {
        if showInspector, selectedTask == id {
            closeTaskPanel()
        } else {
            openTask(id)
        }
    }

    /// ×, Esc or clicking the open card again; in a full-width window the close sticks across launches.
    func closeTaskPanel() {
        withAnimation(.snappy(duration: 0.25)) { showInspector = false }
        if !isCompact { UserDefaults.standard.set(false, forKey: AppState.panelKey) }
    }

    /// The toolbar toggle and the menu item: the one choice that sticks across launches
    /// (in a full-width window; a narrow one hides and floats the panel on its own).
    func toggleTaskPanel() {
        withAnimation(.snappy(duration: 0.25)) { showInspector.toggle() }
        if !isCompact { UserDefaults.standard.set(showInspector, forKey: AppState.panelKey) }
    }

    // MARK: Machines

    var machines = FactoryData.seedMachines
    /// Requests from outside: the factory's when signed in.
    var intake: [IntakeRequest] {
        get { isLive ? client?.intake ?? [] : mockIntake }
        set { if !isLive { mockIntake = newValue } }
    }
    private var mockIntake = FactoryData.seedIntake
    var selectedIntake: String? = FactoryData.seedIntake.first?.id
    /// Who has the keyboard in each live session, and lines typed during this run.
    var sessionDrivers: [String: SessionDriver] = [:]
    var sessionLines: [String: [TermLine]] = [:]
    /// Tab to open the next focused task on, e.g. straight into its live session.
    var pendingTab: String? = nil

    func openSession(_ taskID: String) {
        pendingTab = "session"
        destination = .goal(task(taskID).goal)
        openFocus(taskID)
    }
    /// The machine being set up or edited in the sheet; "new" for this Mac.
    var machineSheet: MachineSheet? = nil
    /// The goal being made or edited in the sheet (a live goal's id for .edit).
    var goalSheet: MachineSheet? = nil
    var queue = FactoryData.seedQueue

    /// A queued task got a slot: it starts building like a freshly approved plan.
    func startQueued(_ id: String) {
        update(id) { task in
            let resuming = (task.progress ?? 0) > 0.05
            task.detail = resuming ? "Resumed from checkpoint" : "Starting"
            task.progress = max(task.progress ?? 0, 0.04)
            task.liveLog = resuming ? "Pulled the last checkpoint, picking up where it left off" : "Setting up a worktree for \(task.id.lowercased())"
            task.updated = "now"
            task.activity.insert(ActivityItem(who: task.agent?.name ?? "Agent", text: "Got a slot and started building", when: "now"), at: 0)
        }
    }

    // MARK: Onboarding

    /// `-onboarding YES` starts at the connect-to-a-factory flow instead of the workspace.
    /// `-onboardingFromWorkspace YES` opens it as if the factory name had been clicked, with a way back.
    var showOnboarding = UserDefaults.standard.bool(forKey: "onboarding") || UserDefaults.standard.bool(forKey: "onboardingAuto")
        || UserDefaults.standard.bool(forKey: "onboardingFromWorkspace")
    /// Opened from the workspace, so there's a factory to go back to. Launch-time onboarding has none.
    var onboardingCanCancel = UserDefaults.standard.bool(forKey: "onboardingFromWorkspace")

    func startOnboarding() {
        onboardingCanCancel = true
        withAnimation(.easeInOut(duration: 0.35)) { showOnboarding = true }
    }

    /// Back to the workspace without connecting: the current factory stays as it was.
    func cancelOnboarding() {
        withAnimation(.easeInOut(duration: 0.35)) { showOnboarding = false }
    }

    /// `workspace`: the factory just joined, or the demo's when there's none.
    func finishOnboarding(workspace: String = "Studio Workspace") {
        withAnimation(.easeInOut(duration: 0.45)) { showOnboarding = false }
        showToast("Welcome to \(workspace)", icon: "hand.wave.fill")
    }

    // MARK: Layout

    var windowWidth: CGFloat = 1600
    /// Icon rail instead of the full sidebar. Narrow windows force it on; the full sidebar then floats over the content.
    var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
    /// What the user picked at full width, restored when the window widens again.
    private var sidebarPreference = UserDefaults.standard.bool(forKey: "sidebarCollapsed")

    /// Around half a laptop screen: the inspector floats and the sidebar becomes a rail.
    var isCompact: Bool { windowWidth < 1180 }
    var sidebarFloating: Bool { isCompact && !sidebarCollapsed }
    var sidebarSpace: CGFloat { sidebarCollapsed || isCompact ? 68 : 250 }
    var inspectorInline: Bool {
        showInspector && !isCompact && !isLoadingFactory && focusedTask == nil && !isComposing
            && ![.scratchpad, .usage, .needsHand, .machines, .intake].contains(destination)
    }
    /// Width left for the main content once the sidebar and an inline inspector take theirs.
    var contentWidth: CGFloat { windowWidth - sidebarSpace - (inspectorInline ? 380 : 0) }

    func windowResized(to width: CGFloat) {
        let wasCompact = isCompact
        windowWidth = width
        guard isCompact != wasCompact else { return }
        withAnimation(.snappy(duration: 0.25)) {
            if isCompact {
                sidebarCollapsed = true
                showInspector = false
            } else {
                sidebarCollapsed = sidebarPreference
                showInspector = UserDefaults.standard.bool(forKey: AppState.panelKey)
            }
        }
    }

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.25)) { sidebarCollapsed.toggle() }
        if !isCompact {
            sidebarPreference = sidebarCollapsed
            UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed")
        }
    }

    // MARK: Live data

    /// The connected factory. Signed in, tasks and goals are its, and actions go to it; otherwise
    /// everything here is the design mockup's.
    var client: FactoryClient?
    var isLive: Bool { client?.isSignedIn == true }
    /// Signed in, but the factory's first snapshot hasn't landed: show the loader, not the mock's goal.
    var isLoadingFactory: Bool { Self.isLoading(signedIn: client?.isSignedIn == true, hasSnapshot: client?.hasSnapshot == true) }

    nonisolated static func isLoading(signedIn: Bool, hasSnapshot: Bool) -> Bool { signedIn && !hasSnapshot }

    /// Where to land once the workspace's goals are known, or nil to stay put: a goal that isn't the
    /// workspace's (the mock's starting one) gives way to the focused task's goal, else the first, else the inbox.
    nonisolated static func destinationAfterSnapshot(_ current: Destination, goals: [String], focusedGoal: String?) -> Destination? {
        guard case .goal(let name) = current, !goals.contains(name) else { return nil }
        if let focusedGoal, goals.contains(focusedGoal) { return .goal(focusedGoal) }
        return goals.first.map(Destination.goal) ?? .inbox
    }

    var tasks: [FactoryTask] {
        get { isLive ? client?.factoryTasks ?? [] : mockTasks }
        set { if !isLive { mockTasks = newValue } }
    }

    private var mockTasks: [FactoryTask] = (FactoryData.seedTasks + FactoryData.queuedTasks).map { seed in
        var task = seed
        task.autoReview = FactoryData.seedReviews[task.id]
        task.hand = FactoryData.seedHands[task.id]
        task.shareable = FactoryData.seedShareable.contains(task.id)
        task.tickets = FactoryData.seedTicketLinks[task.id] ?? []
        task.mockups = FactoryData.seedMockups[task.id] ?? []
        if task.id == "ATL-160" {
            task.intakeID = "req-sso"
            task.comments.append(Comment(author: FactoryData.dana,
                                         text: "All three prospects expect auto-provisioning (JIT). An invite step would be a dealbreaker for Acme.",
                                         when: "4m", via: "Slack #maple-requests"))
        }
        if task.hand != nil { task.needsYou = true }
        // The mockup's queue: what's waiting for a slot, in the order it was approved.
        if let at = FactoryData.queuedTasks.firstIndex(where: { $0.id == task.id }), task.detail.hasPrefix("Queued") {
            task.queued = true
            task.queueRank = Double(at)
        }
        return task
    }
    /// Change requests and comments sent from this session.
    var steering: [String: [ChangeRequest]] = [:]
    var postedComments: [String: [Comment]] = [:]
    /// The risk policy and goals' accepted risk: the factory's when signed in (edits go to it).
    var policy: RiskPolicy {
        get { isLive ? client?.riskPolicy ?? RiskPolicy() : mockPolicy }
        set {
            if let client, isLive { client.save(policy: newValue) } else { mockPolicy = newValue }
            sweepForAutoMerge()
        }
    }
    var acceptances: [String: RiskAcceptance] {
        get { isLive ? client?.riskAcceptances ?? [:] : mockAcceptances }
        set {
            if let client, isLive {
                let old = acceptances
                for goal in Set(old.keys).union(newValue.keys) where old[goal]?.autoMergeUpTo != newValue[goal]?.autoMergeUpTo {
                    client.acceptRisk(goal: goal, upTo: newValue[goal]?.autoMergeUpTo, note: newValue[goal]?.note)
                }
            } else {
                mockAcceptances = newValue
            }
            sweepForAutoMerge()
        }
    }
    private var mockPolicy = RiskPolicy()
    private var mockAcceptances: [String: RiskAcceptance] = FactoryData.seedAcceptances
    /// Over-budget tasks someone chose to keep as a single PR.
    var keptWhole: Set<String> = []
    /// Tasks the factory has picked up for auto-merge and is about to land.
    var autoMerging: Set<String> = []
    var dismissedMentions: Set<String> = []
    var toast: Toast?

    // MARK: Composer & scratchpad

    var isComposing = false
    var draft = ComposeDraft()
    /// Your Scratchpad: the factory's copy when signed in.
    var notes: [Note] {
        get { isLive ? client?.notes ?? [] : mockNotes }
        set { if let client, isLive { client.update(notes: newValue) } else { mockNotes = newValue } }
    }
    private var mockNotes: [Note] = FactoryData.seedNotes

    // MARK: Following goals

    /// The mockup's follows, by goal name; the live ones are the server's.
    private var mockFollows: [String: Bool] = [:]

    /// Read through the client (whose follows and tasks views observe), so unfollowing redraws at once.
    func isFollowing(_ goal: Goal) -> Bool {
        guard isLive else { return mockFollows[goal.name] ?? goal.following }
        guard let client, let live = client.goal(named: goal.name) else { return goal.following }
        return client.isFollowing(live)
    }

    /// The sidebar's goals: the ones you follow, plus the one you're looking at.
    var sidebarGoals: [Goal] {
        let shown = FactoryData.activeGoals.filter { isFollowing($0) || destination == .goal($0.name) }
        guard let client, isLive else { return GoalOrder.apply(shown, order: mockGoalOrder, key: \.name) }
        return GoalOrder.apply(shown, order: client.goalOrder) { client.goal(named: $0.name)?.id }
    }

    /// The mockup's personal goal order, by name; the live one is saved per factory by the client.
    private var mockGoalOrder: [String]? = nil

    /// Moves a sidebar goal and saves the whole sidebar's order as yours.
    func moveGoal(_ goal: Goal, _ move: GoalOrder.Move) {
        let names = GoalOrder.move(goal.name, to: move, in: sidebarGoals.map(\.name))
        guard let client, isLive else { mockGoalOrder = GoalOrder.saving(names, over: mockGoalOrder); return }
        client.goalOrder = GoalOrder.saving(names.compactMap { client.goal(named: $0)?.id }, over: client.goalOrder)
    }

    func canMoveGoal(_ goal: Goal, _ move: GoalOrder.Move) -> Bool {
        GoalOrder.canMove(goal.name, move, in: sidebarGoals.map(\.name))
    }

    // MARK: Archiving goals

    /// A goal being archived that still has unfinished tasks, while the app asks what to do with them.
    var archiving: String? = nil

    func unfinishedTasks(in goal: String) -> [FactoryTask] {
        tasks.filter { $0.goal == goal && $0.state != .merged && $0.state != .cancelled }
    }

    /// Archives (or brings back) a goal; with unfinished tasks it asks first.
    func archive(_ goal: Goal, _ archived: Bool) {
        guard let client, isLive, let live = client.goal(named: goal.name) else { return }
        if archived, !unfinishedTasks(in: goal.name).isEmpty { archiving = goal.name; return }
        client.send(.goalArchive(.init(id: live.id, archived: archived)))
        if archived, destination == .goal(goal.name) { destination = .allGoals }
    }

    func finishArchiving(_ unfinished: Wire.UnfinishedTasks) {
        guard let name = archiving, let client, let live = client.goal(named: name) else { return }
        archiving = nil
        client.send(.goalArchive(.init(id: live.id, archived: true, unfinished: unfinished)))
        if destination == .goal(name) { destination = .allGoals }
    }

    func setFollowing(_ goal: Goal, _ following: Bool) {
        if let client, isLive { client.follow(goal: goal.name, following) } else { mockFollows[goal.name] = following }
    }
    var selectedNote: UUID? = FactoryData.seedNotes.first?.id
    /// The note the delete confirmation is asking about.
    var deletingNote: UUID? = nil

    // MARK: Seen state

    /// How many activity items you'd seen on each task when you last looked (newest-first list).
    var seenActivityCount: [String: Int] = [:]

    // MARK: Queries

    func task(_ id: String) -> FactoryTask {
        tasks.first { $0.id == id } ?? tasks.first ?? FactoryTask.none
    }

    func tasks(for goal: Goal) -> [FactoryTask] {
        tasks.filter { $0.goal == goal.name }
    }

    func stats(for goal: Goal) -> (merged: Int, total: Int) {
        let live = tasks(for: goal).filter { $0.state != .cancelled }
        return (live.filter { $0.state == .merged }.count, live.count)
    }

    func risk(for task: FactoryTask) -> RiskAssessment? {
        policy.assess(task, acceptance: acceptances[task.goal])
    }

    func mergeGate(for task: FactoryTask) -> MergeGate {
        let risk = risk(for: task)
        let failedProofs = task.doneWhen.filter { $0.status == .failed }.count
        let unproven = task.doneWhen.filter { $0.status != .proven }.count
        let required = task.pr?.checks.filter(\.required) ?? []
        let reviewsNeeded = risk?.reviews ?? 1
        let round = task.autoReview?.current
        let autoReviewDetail: String? = task.autoReview.map { _ in
            switch round?.verdict {
            case .inProgress?: "Round \(round!.number) in progress"
            case .changesRequested?: "Changes requested"
            case .escalated?: "Escalated"
            case .passed?: "Passed"
            case nil: "Waiting for the reviewer"
            }
        }

        return MergeGate(
            proofsReady: unproven == 0,
            failedProofs: failedProofs,
            unproven: unproven,
            checksReady: required.allSatisfy { $0.status == .passed },
            failedChecks: required.filter { $0.status == .failed }.count,
            reviewsNeeded: reviewsNeeded,
            reviewsReady: task.reviews.count >= reviewsNeeded,
            autoMerge: risk?.autoMerge ?? false,
            autoReviewReady: task.autoReview == nil || round?.verdict == .passed,
            autoReviewDetail: autoReviewDetail,
            autoReviewRound: round?.verdict == .inProgress ? round?.number : nil
        )
    }

    /// Derived from live task state, so acting on a task clears its inbox item on its own.
    // MARK: Goal scope

    /// Inbox, Needs a hand and Activity show the goals you follow unless you ask for all of them.
    enum GoalScope: String { case following, all }

    var goalScope: GoalScope = GoalScope(rawValue: UserDefaults.standard.string(forKey: "goalScope") ?? "") ?? .following {
        didSet { UserDefaults.standard.set(goalScope.rawValue, forKey: "goalScope") }
    }

    private var followedGoalNames: Set<String> { Set(FactoryData.goals.filter(isFollowing).map(\.name)) }

    /// A task the current scope shows: any of yours, else one in a goal you follow.
    func inScope(_ task: FactoryTask) -> Bool {
        goalScope == .all || task.owner.id == FactoryData.me.id || followedGoalNames.contains(task.goal)
    }

    /// The scoped inbox; mentions of you always come through.
    var inbox: [InboxItem] {
        let all = allInbox
        guard goalScope == .following else { return all }
        let followed = followedGoalNames
        return all.filter { item in
            guard item.kind != .mention else { return true }
            let task = task(item.taskID)
            return task.owner.id == FactoryData.me.id || followed.contains(task.goal)
        }
    }

    /// Everything waiting on anyone, in every goal.
    var allInbox: [InboxItem] {
        if isLive { return liveInbox }
        return FactoryData.seedInbox.filter { item in
            let task = task(item.taskID)
            switch item.kind {
            case .mention: return !dismissedMentions.contains(item.id)
            case .approval: return task.state == .awaitingApproval && !task.approvals.contains { $0.id == FactoryData.me.id }
            case .question: return task.question != nil && task.state == .planning
            case .failing: return task.state != .merged && (task.pr?.checks.contains { $0.status == .failed } ?? false)
            case .review: return task.state == .reviewing && !task.reviews.contains { $0.id == FactoryData.me.id }
            }
        }
    }

    /// What needs people, from the factory's tasks: plans to approve, agents' questions, changes to
    /// review, failing checks and @mentions of you.
    private var liveInbox: [InboxItem] {
        let me = FactoryData.me
        var items: [InboxItem] = []
        for task in tasks {
            let mine = task.owner.id == me.id
            if task.state == .awaitingApproval && !task.approvals.contains(where: { $0.id == me.id }) {
                items.append(InboxItem(kind: .approval, taskID: task.id, assignee: me, message: "Plan v\(task.planVersion) is ready for your approval", when: task.updated))
            }
            if let question = task.question {
                items.append(InboxItem(kind: .question, taskID: task.id, assignee: task.owner, message: question, when: task.updated))
            }
            if task.state == .reviewing, task.autoReview?.current?.verdict == .passed, !task.reviews.contains(where: { $0.id == me.id }) {
                items.append(InboxItem(kind: .review, taskID: task.id, assignee: mine ? me : task.owner, message: "Passed automatic review; ready for yours", when: task.updated))
            }
            if task.state != .merged, task.pr?.checks.contains(where: { $0.status == .failed }) ?? false {
                items.append(InboxItem(kind: .failing, taskID: task.id, assignee: task.owner, message: "Checks are failing", when: task.updated))
            }
            if let handle = me.github {
                for comment in task.comments where comment.text.contains("@\(handle)") && comment.author.id != me.id {
                    let item = InboxItem(kind: .mention, taskID: task.id, assignee: me, message: "\(comment.author.firstName): \(comment.text)", when: comment.when)
                    if !dismissedMentions.contains(item.id) { items.append(item) }
                }
            }
        }
        return items
    }

    /// Tasks whose agent has stopped and asked for a human, longest-waiting first.
    var allHandRaises: [FactoryTask] { tasks.filter { $0.hand != nil } }
    /// Scoped like the inbox; a hand raised to you always shows.
    var handRaises: [FactoryTask] {
        allHandRaises.filter { inScope($0) || $0.hand?.assignee.id == FactoryData.me.id }
    }
    var myHandRaises: [FactoryTask] { handRaises.filter { $0.hand?.assignee.id == FactoryData.me.id } }

    var myInbox: [InboxItem] { inbox.filter { $0.assignee.id == FactoryData.me.id } }

    func inbox(_ kind: InboxItem.Kind, mine: Bool = false) -> [InboxItem] {
        (mine ? myInbox : inbox).filter { $0.kind == kind }
    }

    func changeRequests(for task: FactoryTask) -> [ChangeRequest] {
        task.changeRequests + steering[task.id, default: []]
    }

    func queuedChanges(for task: FactoryTask) -> Int {
        changeRequests(for: task).filter { $0.status != .applied }.count
    }

    // MARK: Changes since last viewed

    /// Activity from other people and agents since you last opened the task.
    func unseenChanges(for task: FactoryTask) -> [ActivityItem] {
        let others = { (item: ActivityItem) in item.who != FactoryData.me.name }
        if let seen = seenActivityCount[task.id] {
            return Array(task.activity.prefix(max(task.activity.count - seen, 0))).filter(others)
        }
        guard let ago = FactoryData.seedLastViewed[task.id] else { return [] }
        return task.activity.filter { minutesAgo($0.when) < ago }.filter(others)
    }

    func lastViewedLabel(for task: FactoryTask) -> String? {
        if seenActivityCount[task.id] != nil { return "earlier this session" }
        return FactoryData.seedLastViewed[task.id].map { "\($0)m ago" }
    }

    func markSeen(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) {
            seenActivityCount[id] = task(id).activity.count
        }
    }

    func minutesAgo(_ label: String) -> Int {
        let digits = Int(label.prefix { $0.isNumber }) ?? 0
        if label.hasSuffix("h") { return digits * 60 }
        if label.hasSuffix("d") { return digits * 1440 }
        return digits
    }

    // MARK: Composer actions

    func startCompose(goal: String? = nil, title: String = "", body: String = "", fromNote: UUID? = nil) {
        let currentGoal: String = {
            if case let .goal(name) = destination, FactoryData.activeGoals.contains(where: { $0.name == name }) { return name }
            return (FactoryData.activeGoals.first(where: isFollowing) ?? FactoryData.activeGoals.first)?.name ?? ""
        }()
        var chosen = false
        if goal != nil { chosen = true } else if case .goal = destination { chosen = true }
        // A Draft with AI left running (or finished, not yet in the composer) carries on: a plain
        // New Task comes back to it as it was left. A composer opened for something else (a request,
        // a note, a goal) isn't that draft's, so it's stopped rather than left to fill this one in.
        let resuming = aiDraftPending && goal == nil && title.isEmpty && body.isEmpty && fromNote == nil
        if !resuming {
            if aiDraftPending, let draft = aiDraft, draft.state == .choosing || draft.state == .reading {
                showToast("Stopped the Draft with AI that was running", icon: "sparkles", color: Theme.State.planning)
            }
            cancelAIDraft()
            draft = ComposeDraft(title: title, body: body, goal: goal ?? currentGoal, agent: nil, fromNote: fromNote, goalChosen: chosen)
        }
        withAnimation(.snappy(duration: 0.3)) {
            focusedTask = nil
            isComposing = true
        }
    }

    /// Closes the composer. A Draft with AI that's running keeps going, to come back to; one that
    /// failed while open has been seen, so it isn't brought back.
    func cancelCompose() {
        if aiDraft?.state == .failed { aiDraftID = nil }
        withAnimation(.snappy(duration: 0.3)) { isComposing = false }
    }

    // MARK: Draft with AI

    /// The composer's Draft with AI run, if one was started.
    var aiDraftID: String? = nil
    /// The draft whose result is already in the composer.
    private var appliedAIDraft: String? = nil
    /// A goal Draft with AI suggested, for the goal sheet to start from.
    var goalPrefill: Wire.NewGoalIdea? = nil

    /// Whether the Draft with AI card shows what the agent has said and done.
    var watchingAIDraft = false

    var aiDraft: Wire.Draft? { aiDraftID.flatMap { client?.drafts[$0] } }

    /// A Draft with AI the composer should come back to: still running, or done with its result
    /// (or its question, or why it failed) not yet in the composer.
    var aiDraftPending: Bool {
        guard let id = aiDraftID else { return false }
        guard let draft = aiDraft else { return true }
        return draft.state != .ready || appliedAIDraft != id
    }

    /// Has an agent read the code (or pick a goal first) and fill in the title, brief and Done when.
    func draftWithAI() {
        guard let client, isLive else { return }
        let idea = [draft.title, draft.body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !idea.isEmpty else {
            showToast("Write a line or two about what you want first", icon: "sparkles", color: Theme.State.planning)
            return
        }
        cancelAIDraft()
        let id = UUID().uuidString.lowercased()
        aiDraftID = id
        let goal = draft.goalChosen ? client.goal(named: draft.goal)?.id : nil
        client.send(.draftStart(.init(id: id, idea: idea, goal: goal, agent: draft.agent)))
    }

    func cancelAIDraft() {
        if let id = aiDraftID, let draft = aiDraft, draft.state == .choosing || draft.state == .reading {
            client?.send(.draftCancel(.init(id: id)))
        }
        aiDraftID = nil
    }

    /// Carries on with a goal: one it suggested making (once made), or another the person picked.
    func continueAIDraft(goal name: String) {
        guard let client, let id = aiDraftID, let goal = client.goal(named: name) else { return }
        draft.goal = name
        draft.goalChosen = true
        appliedAIDraft = nil
        client.send(.draftGoal(.init(id: id, goal: goal.id)))
    }

    /// Puts what the draft knows into the composer: its goal as soon as it has one, the rest once ready.
    func applyAIDraft() {
        guard let draft = aiDraft, let client else { return }
        if let id = draft.goal, let goal = client.goals.first(where: { $0.id == id }) {
            self.draft.goal = goal.name
        }
        guard draft.state == .ready, appliedAIDraft != draft.id, let title = draft.title, let brief = draft.brief else { return }
        appliedAIDraft = draft.id
        self.draft.goalChosen = true
        self.draft.title = title
        let checks = draft.doneWhen.map { "- [ ] \($0)" }.joined(separator: "\n")
        self.draft.body = checks.isEmpty ? brief : "\(brief)\n\n## Done when\n\(checks)"
    }

    /// The agent that would pick up a new task: the chosen one, or whoever has the least in flight.
    func assignee(for draft: ComposeDraft) -> Agent {
        if isLive { return LiveAdapter.role("planner") }
        if let name = draft.agent, let agent = FactoryData.agents.first(where: { $0.name == name }) { return agent }
        return FactoryData.agents.min { load($0) < load($1) } ?? FactoryData.agents[0]
    }

    func load(_ agent: Agent) -> Int {
        tasks.filter { $0.agent?.id == agent.id && [.planning, .building].contains($0.state) }.count
    }

    /// Turns the composer's brief into a task, either parked as a draft or handed straight to a planner.
    func submitDraft(sendToPlanning: Bool) {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            showToast("Give the task a title first", icon: "exclamationmark.circle", color: Theme.State.awaitingApproval)
            return
        }
        if let client, isLive {
            guard let goal = client.goal(named: draft.goal) else {
                showToast("Pick a goal first", icon: "exclamationmark.circle", color: Theme.State.awaitingApproval)
                return
            }
            let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            client.send(.taskCreate(.init(goal: goal.id, title: title, brief: body.isEmpty ? title : body, shareable: draft.shareable,
                                          plan: sendToPlanning, tickets: draft.tickets.map(\.wire), agent: draft.agent, intake: draft.intakeID,
                                          repo: draft.repo.flatMap { goal.repos.contains($0) ? $0 : nil })))
            // The task's sent: a draft still running (or failed, or waiting on a goal) is done with.
            cancelAIDraft()
            withAnimation(.snappy(duration: 0.3)) {
                isComposing = false
                destination = .goal(draft.goal)
            }
            showToast(sendToPlanning ? "Sent to planning" : "Saved as a draft",
                      icon: sendToPlanning ? "list.bullet.indent" : "pencil.line",
                      color: sendToPlanning ? Theme.State.planning : Theme.State.drafting)
            return
        }
        let reading = BriefReading(draft.body)
        let agent = assignee(for: draft)
        let prefix = tasks.first { $0.goal == draft.goal }?.id ?? "NEW-1"
        let id = nextTaskID(like: prefix)
        let me = FactoryData.me

        var task = FactoryTask(
            id: id, goal: draft.goal, title: title,
            state: sendToPlanning ? .planning : .drafting,
            agent: sendToPlanning ? agent : nil, owner: me,
            detail: sendToPlanning ? "Reading the brief…" : "Edited just now",
            span: FactoryData.todayOffset...(FactoryData.todayOffset + 6), updated: "now"
        )
        task.brief = reading.summary
        task.spec = draft.body
        task.shareable = draft.shareable
        task.tickets = draft.tickets
        task.intakeID = draft.intakeID
        task.doneWhen = reading.doneWhen
        task.areas = reading.areas
        if sendToPlanning {
            task.plan = [PlanStep(text: "Drafting the plan…", file: "", progress: .active)]
            task.liveLog = "Reading the brief and exploring the codebase"
            task.footprint = (3, 150, true)
        }
        task.activity = [ActivityItem(
            who: me.name,
            text: sendToPlanning ? "Created and handed to \(agent.name) for planning" : "Created a draft",
            when: "now"
        )]

        tasks.append(task)
        seenActivityCount[id] = task.activity.count
        if let noteID = draft.fromNote, let index = notes.firstIndex(where: { $0.id == noteID }) {
            notes[index].taskID = id
        }
        if let intakeID = draft.intakeID {
            acceptIntake(intakeID, as: id, agent: sendToPlanning ? agent.name : nil)
        }

        withAnimation(.snappy(duration: 0.3)) {
            isComposing = false
            destination = .goal(draft.goal)
        }
        openFocus(id)
        showToast(
            sendToPlanning ? "\(id) created · \(agent.name) is drafting a plan" : "\(id) saved as a draft",
            icon: sendToPlanning ? "list.bullet.indent" : "pencil.line",
            color: sendToPlanning ? Theme.State.planning : Theme.State.drafting
        )
    }

    /// Parks the composer's contents in the scratchpad instead of making a task.
    func saveDraftAsNote() {
        let note = Note(
            id: UUID(),
            title: draft.title.isEmpty ? "Untitled note" : draft.title,
            body: draft.body,
            updated: "now"
        )
        notes.insert(note, at: 0)
        selectedNote = note.id
        withAnimation(.snappy(duration: 0.3)) {
            isComposing = false
            destination = .scratchpad
        }
        showToast("Saved to scratchpad", icon: "note.text", color: Theme.State.drafting)
    }

    func newNote() {
        let note = Note(id: UUID(), title: "", body: "", updated: "now")
        notes.insert(note, at: 0)
        selectedNote = note.id
    }

    /// Removes a note for good and selects its neighbour: the next one, or the previous one if it was last.
    func deleteNote(_ id: UUID) {
        deletingNote = nil
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var remaining = notes
        remaining.remove(at: index)
        if selectedNote == id { selectedNote = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id }
        notes = remaining
        showToast("Note deleted", icon: "trash")
    }

    // MARK: Navigation actions

    func openFocus(_ id: String) {
        withAnimation(.snappy(duration: 0.3)) {
            selectedTask = id
            focusedTask = id
        }
    }

    /// The selection follows the goal on screen: when it belongs elsewhere (or is gone), it moves to the
    /// goal's first unfinished task. This only picks what the panel would show; it never opens the panel.
    func keepSelectionInGoal() {
        if destination == .inbox {
            if !myInbox.contains(where: { $0.taskID == selectedTask }), let first = myInbox.first { selectedTask = first.taskID }
            return
        }
        if destination == .myTasks {
            let mine = tasks.filter { $0.owner.id == FactoryData.me.id && $0.state != .merged && $0.state != .cancelled }
            if !mine.contains(where: { $0.id == selectedTask }), let first = mine.first { selectedTask = first.id }
            return
        }
        guard case .goal(let name) = destination else { return }
        let goalTasks = tasks.filter { $0.goal == name }
        guard !goalTasks.contains(where: { $0.id == selectedTask }) else { return }
        if let pick = goalTasks.first(where: { $0.state != .merged && $0.state != .cancelled }) ?? goalTasks.first {
            selectedTask = pick.id
        }
    }

    func closeFocus() {
        withAnimation(.snappy(duration: 0.3)) { focusedTask = nil }
    }

    /// A link to the task that opens it in the app (through the factory's server when live).
    func link(to id: String) -> String {
        if isLive, let server = client?.server { return server.appending(path: "t/\(id)").absoluteString }
        return "maplefactory://task/\(id)"
    }

    func copyLink(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link(to: id), forType: .string)
        showToast("Copied a link to \(id)", icon: "link")
    }

    /// The task's branch on GitHub; for a goal that names a folder, the command to check it out.
    func openBranch(_ id: String) {
        let task = task(id)
        guard isLive, let client, let branch = task.gitBranch else {
            showToast("Opened \(id)'s branch on GitHub", icon: "arrow.triangle.branch")
            return
        }
        if let repo = client.goal(named: task.goal)?.repo, let url = URL(string: "https://github.com/\(repo)/tree/\(branch)") {
            NSWorkspace.shared.open(url)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("git switch \(branch)", forType: .string)
        showToast("Copied git switch \(branch): it's on \(task.pushed == nil ? task.machine ?? "its machine" : "origin")", icon: "arrow.triangle.branch")
    }

    func showToast(_ text: String, icon: String, color: Color = Theme.accent) {
        let toast = Toast(icon: icon, text: text, color: color)
        withAnimation(.snappy(duration: 0.25)) { self.toast = toast }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            if self.toast == toast {
                withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
            }
        }
    }

    // MARK: Task actions

    /// A change request for the task's planner or builder.
    func steer(_ id: String, text: String, interruptNow: Bool) {
        if let client, isLive {
            client.send(.taskSteer(.init(id: id, text: text)))
            return
        }
        let task = task(id)
        let timing = interruptNow && task.state == .building ? "Interrupting after the current edit" : task.steerTiming
        steering[id, default: []].append(ChangeRequest(author: FactoryData.me, text: text, status: interruptNow ? .applying : .queued, timing: timing))
    }

    func comment(_ id: String, text: String) {
        if let client, isLive {
            client.send(.taskComment(.init(id: id, text: text)))
            return
        }
        postedComments[id, default: []].append(Comment(author: FactoryData.me, text: text, when: "now"))
    }

    /// Answers the agent's open question.
    func answer(_ id: String, text: String) {
        if let client, isLive {
            client.send(.taskAnswer(.init(id: id, text: text)))
            return
        }
        answerInSession(id, option: text)
    }

    /// The agents the connected factory's machines can run: what their health reports, Claude Code first.
    var liveAgents: [String] {
        let installed = Set((client?.machines ?? []).flatMap { $0.health?.agents.map(\.name) ?? [] })
        return ["claude", "codex"].filter { installed.contains($0) || $0 == "claude" } + installed.subtracting(["claude", "codex"]).sorted()
    }

    func cancel(_ id: String) {
        if let client, isLive {
            client.send(.taskCancel(.init(id: id)))
            return
        }
        update(id) { task in
            task.state = .cancelled
            if task.pr?.state == .open || task.pr?.state == .draft { task.pr?.state = .closed }
            if task.autoReview?.current?.verdict == .inProgress { task.autoReview?.rounds.removeLast() }
        }
    }

    func retry(_ id: String) {
        if let client, isLive {
            client.send(.taskRetry(.init(id: id)))
            return
        }
        // Back to the stage it was in, as the factory does.
        update(id) { task in
            guard task.state == .cancelled || task.state == .reviewing else { return }
            if task.state == .cancelled {
                if task.pr != nil {
                    task.state = .reviewing
                    if task.pr?.state == .closed { task.pr?.state = .open }
                } else {
                    task.state = task.plan.isEmpty ? .planning
                        : task.approvals.count >= task.approvalsNeeded ? .building
                        : .awaitingApproval
                }
            }
            // In review: a new automated-review round on what's pushed.
            if task.state == .reviewing, var review = task.autoReview {
                if review.current?.verdict == .inProgress { review.rounds.removeLast() }
                review.maxRounds = max(review.maxRounds, review.rounds.count + 1)
                review.rounds.append(ReviewRound(number: review.rounds.count + 1, verdict: .inProgress, found: 0, when: "now"))
                task.autoReview = review
                task.reviews = []
            }
        }
    }

    /// Sends a draft to planning.
    func plan(_ id: String) {
        if let client, isLive {
            client.send(.taskPlan(.init(id: id)))
            return
        }
        update(id) { $0.state = .planning }
    }

    // MARK: Queue

    /// Moves a task ahead of `before` in the queue ("top": the front), or to the back. A draft joins the queue.
    func queue(_ id: String, before: String?) {
        let rank = rank(for: id, before: before)
        if let client, isLive {
            // Reordered here at once, as the factory will: no wait for its echo after a drop.
            withAnimation(.snappy(duration: 0.2)) { client.expect(id) { $0.queueRank = rank } }
            client.send(.taskQueue(.init(id: id, before: before)))
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            update(id) { task in
                task.queueRank = rank
                joinQueue(&task)
            }
        }
    }

    /// The rank that puts `id` ahead of `before` ("top": the front; none: the back), as the factory works it out.
    private func rank(for id: String, before: String?) -> Double {
        let line = queueOrder.filter { $0.id != id }
        let target = before == "top" ? line.first : line.first { $0.id == before }
        if let target, let at = line.firstIndex(where: { $0.id == target.id }) {
            return at > 0 ? (line[at - 1].queueRank + target.queueRank) / 2 : target.queueRank - 1000
        }
        return (line.map(\.queueRank).max() ?? 0) + 1
    }

    func moveToTop(_ id: String) { queue(id, before: "top") }
    func moveToBottom(_ id: String) { queue(id, before: nil) }

    /// Holds a task until `at`, keeping its place; a draft joins the queue.
    func schedule(_ id: String, at: Date) {
        if let client, isLive {
            client.send(.taskQueue(.init(id: id, startAt: UInt64(at.timeIntervalSince1970 * 1000))))
            return
        }
        update(id) { task in
            task.startAt = at
            joinQueue(&task)
        }
    }

    /// Clears its schedule and puts it at the front.
    func startNow(_ id: String) {
        if let client, isLive {
            let rank = rank(for: id, before: "top")
            withAnimation(.snappy(duration: 0.2)) {
                client.expect(id) { task in
                    task.queueRank = rank
                    task.startAt = nil
                }
            }
            client.send(.taskQueue(.init(id: id, before: "top", clearSchedule: true)))
            return
        }
        let first = queueOrder.first { $0.id != id }
        update(id) { task in
            task.startAt = nil
            if let first { task.queueRank = first.queueRank - 1 }
            joinQueue(&task)
        }
    }

    /// Takes its schedule off, keeping its place.
    func unschedule(_ id: String) {
        if let client, isLive {
            client.send(.taskQueue(.init(id: id, clearSchedule: true)))
            return
        }
        update(id) { task in
            task.startAt = nil
            joinQueue(&task)
        }
    }

    /// The mockup's queue: a draft goes to planning.
    private func joinQueue(_ task: inout FactoryTask) {
        if task.state == .drafting { task.state = .planning }
        task.queued = true
        task.detail = task.scheduled ? "Scheduled" : "Waiting for a free slot"
    }

    /// Every queued task, front first.
    var queueOrder: [FactoryTask] {
        tasks.filter(\.queued).sorted { $0.queueRank < $1.queueRank }
    }

    func update(_ id: String, _ mutate: (inout FactoryTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    // MARK: Actions in flight

    /// An approval or merge sent to the factory that the task doesn't show yet.
    struct InFlight {
        enum Kind { case approvePlan, approveChanges, merge }
        let kind: Kind
        let startedAt: Date
    }

    /// By task: what was sent and when, so its button can show it's working.
    var inFlight: [String: InFlight] = [:]
    private static let inFlightTimeout: Duration = .seconds(30)

    /// True from sending `kind` until the task shows its result, the server refuses something, or
    /// the timeout passes.
    func isInFlight(_ id: String, _ kind: InFlight.Kind) -> Bool {
        guard let entry = inFlight[id], entry.kind == kind,
              Date().timeIntervalSince(entry.startedAt) < 30 else { return false }
        return !landed(kind, on: task(id))
    }

    /// Whether the task already shows what `kind` asked for.
    private func landed(_ kind: InFlight.Kind, on task: FactoryTask) -> Bool {
        let me = FactoryData.me.id
        switch kind {
        case .approvePlan: return task.approvals.contains { $0.id == me } || task.state != .awaitingApproval
        case .approveChanges: return task.reviews.contains { $0.id == me }
        case .merge: return task.state == .merged || task.pr?.state == .merged
        }
    }

    /// Records `kind` as sent for the task; false when it's already in flight, so a second click sends nothing.
    private func beginInFlight(_ id: String, _ kind: InFlight.Kind) -> Bool {
        guard !isInFlight(id, kind) else { return false }
        let startedAt = Date()
        withAnimation(.snappy(duration: 0.2)) { inFlight[id] = InFlight(kind: kind, startedAt: startedAt) }
        Task { @MainActor in
            try? await Task.sleep(for: Self.inFlightTimeout)
            guard let entry = self.inFlight[id], entry.startedAt == startedAt else { return }
            let stillWaiting = !self.landed(kind, on: self.task(id))
            withAnimation(.snappy(duration: 0.2)) { self.inFlight[id] = nil }
            if stillWaiting {
                self.showToast("Still waiting on the factory for \(id)…", icon: "hourglass", color: Theme.State.awaitingApproval)
            }
        }
        return true
    }

    private func endInFlight(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) { inFlight[id] = nil }
    }

    /// The server refused something: every button that was waiting comes back, with its reason.
    func serverRefused(_ message: String) {
        withAnimation(.snappy(duration: 0.2)) { inFlight.removeAll() }
        showToast(message, icon: "exclamationmark.triangle.fill", color: Theme.State.cancelled)
    }

    /// Demo scripts only: holds a mock action in flight for a moment, so its busy state can be seen.
    private func afterDemoDelay(_ id: String, _ kind: InFlight.Kind, _ apply: @escaping () -> Void) -> Bool {
        guard UserDefaults.standard.string(forKey: "actions") != nil else { return false }
        guard beginInFlight(id, kind) else { return true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            self.endInFlight(id)
            apply()
        }
        return true
    }

    func approvePlan(_ id: String) {
        if let client, isLive {
            guard beginInFlight(id, .approvePlan) else { return }
            client.send(.taskApprovePlan(.init(id: id)))
            return
        }
        if afterDemoDelay(id, .approvePlan, { self.approvePlanInMockup(id) }) { return }
        approvePlanInMockup(id)
    }

    private func approvePlanInMockup(_ id: String) {
        let me = FactoryData.me
        let needed = risk(for: task(id))?.approvals ?? task(id).approvalsNeeded
        // Read before `update`, which holds exclusive access to `tasks` while it mutates.
        let prNumber = nextPRNumber()
        var started = false

        withAnimation(.snappy(duration: 0.3)) {
            update(id) { task in
                guard !task.approvals.contains(where: { $0.id == me.id }) else { return }
                task.approvals.append(me)
                task.activity.insert(ActivityItem(who: me.name, text: "Approved plan v\(task.planVersion)", when: "now"), at: 0)
                if task.approvals.count >= needed {
                    startBuilding(&task, prNumber: prNumber)
                    started = true
                }
            }
        }

        let task = task(id)
        if started {
            showToast("Plan approved · \(task.agent?.name ?? "Agent") started building \(id)", icon: "hammer.fill", color: Theme.State.building)
        } else {
            showToast("You approved \(id) · \(task.approvals.count) of \(needed)", icon: "checkmark.circle.fill")
        }
    }

    /// What answering a raised hand sends. Retry with no session running is a real retry, so the server
    /// repairs the task's state; a task's agent is set from its stage even when nothing runs, so check the worker.
    static func handAnswer(_ task: FactoryTask, option: String?, note: String) -> Wire.ClientMessage {
        if option == "Cancel it" { return .taskCancel(.init(id: task.id)) }
        if option == "Retry" && task.worker == nil { return .taskRetry(.init(id: task.id)) }
        return .taskResolveHand(.init(id: task.id, option: option, note: note))
    }

    /// Answers a raised hand: the agent takes the chosen option (plus any note) and gets moving again.
    func resolveHand(_ id: String, option: HandRaise.Option?, note: String) {
        if let client, isLive {
            client.send(Self.handAnswer(task(id), option: option?.title, note: note))
            return
        }
        guard let hand = task(id).hand else { return }
        let me = FactoryData.me
        let answer = option?.title ?? note
        let wasEscalated = hand.reason == .reviewLoop || hand.reason == .proofBurden

        withAnimation(.snappy(duration: 0.35)) {
            update(id) { task in
                let agent = task.agent?.name ?? "Agent"
                task.hand = nil
                task.needsYou = false
                task.updated = "now"
                task.activity.insert(ActivityItem(who: me.name, text: "Answered: \(answer)", when: "now"), at: 0)
                if !note.isEmpty, option != nil {
                    task.comments.append(Comment(author: me, text: note, when: "now"))
                }
                if task.state == .planning {
                    task.question = nil
                    task.detail = "Drafting plan"
                    task.liveLog = "Planning with your answer: \(answer)"
                } else {
                    task.state = .building
                    task.detail = "Applying your call"
                    task.progress = 0.1
                    task.liveLog = "Applying: \(answer)"
                    if wasEscalated, var review = task.autoReview {
                        review.maxRounds = review.rounds.count + 3
                        task.autoReview = review
                    }
                }
                task.activity.insert(ActivityItem(who: agent, text: "Picked it back up", when: "now"), at: 0)
            }
        }
        showToast("\(task(id).agent?.name ?? "Agent") is back on \(id)", icon: "hand.thumbsup.fill", color: Theme.State.building)
    }

    private func startBuilding(_ task: inout FactoryTask, prNumber: Int) {
        task.state = .building
        task.needsYou = false
        for index in task.plan.indices {
            task.plan[index].progress = index == 0 ? .active : .pending
            task.plan[index].change = nil
        }
        task.detail = "Step 1 of \(max(task.plan.count, 1))"
        task.progress = 0.04
        task.liveLog = "Starting: \(task.plan.first?.text ?? "setting up the branch")"
        task.updated = "now"
        task.pr = PullRequest(number: prNumber, state: .draft, checks: CICheck.queued())
        task.activity.insert(ActivityItem(who: task.agent?.name ?? "Agent", text: "Opened a draft PR and started step 1", when: "now"), at: 0)
    }

    func approveChanges(_ id: String) {
        // Covers the inbox and URL paths too: the server would only refuse it.
        guard mergeGate(for: task(id)).autoReviewReady else {
            showToast("Wait for the automatic review to pass first", icon: "hourglass", color: Theme.textMuted)
            return
        }
        if let client, isLive {
            guard beginInFlight(id, .approveChanges) else { return }
            client.send(.taskApproveChanges(.init(id: id)))
            return
        }
        if afterDemoDelay(id, .approveChanges, { self.approveChangesInMockup(id) }) { return }
        approveChangesInMockup(id)
    }

    private func approveChangesInMockup(_ id: String) {
        let me = FactoryData.me
        withAnimation(.snappy(duration: 0.3)) {
            update(id) { task in
                guard !task.reviews.contains(where: { $0.id == me.id }) else { return }
                task.reviews.append(me)
                task.activity.insert(ActivityItem(who: me.name, text: "Approved the changes", when: "now"), at: 0)
            }
        }
        let gate = mergeGate(for: task(id))
        showToast("You approved the changes on \(id) · \(task(id).reviews.count) of \(gate.reviewsNeeded) reviews",
                  icon: "checkmark.circle.fill")

        // Stand-in for real multiplayer: when a second review is needed, Chris follows up.
        if !gate.reviewsReady {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let chris = FactoryData.chris
                guard self.task(id).state == .reviewing,
                      !self.task(id).reviews.contains(where: { $0.id == chris.id }),
                      !self.mergeGate(for: self.task(id)).reviewsReady else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    self.update(id) { task in
                        task.reviews.append(chris)
                        task.activity.insert(ActivityItem(who: chris.firstName, text: "Approved the changes", when: "now"), at: 0)
                    }
                }
                self.showToast("Chris approved the changes on \(id)", icon: "person.fill.checkmark", color: chris.color)
                self.sweepForAutoMerge()
            }
        }
        sweepForAutoMerge()
    }

    func merge(_ id: String, byFactory: Bool = false) {
        if let client, isLive {
            if !byFactory, beginInFlight(id, .merge) { client.send(.taskMerge(.init(id: id))) }
            return
        }
        if !byFactory, afterDemoDelay(id, .merge, { self.mergeInMockup(id, byFactory: false) }) { return }
        mergeInMockup(id, byFactory: byFactory)
    }

    private func mergeInMockup(_ id: String, byFactory: Bool) {
        let number = task(id).pr?.number
        withAnimation(.snappy(duration: 0.35)) {
            update(id) { task in
                task.state = .merged
                task.needsYou = false
                task.liveLog = nil
                task.progress = nil
                task.pr?.state = .merged
                task.detail = number.map { "#\($0) · just now" } ?? "Merged just now"
                task.updated = "now"
                task.activity.insert(ActivityItem(
                    who: byFactory ? "Factory" : FactoryData.me.name,
                    text: "Merged #\(number ?? 0) into main\(byFactory ? " (auto-merge)" : "")",
                    when: "now"
                ), at: 0)
            }
            autoMerging.remove(id)
        }
        showToast(byFactory ? "Factory auto-merged \(id) (#\(number ?? 0))" : "Merged \(id) into main",
                  icon: byFactory ? "bolt.fill" : "arrow.triangle.merge", color: Theme.State.merged)
    }

    func rerunFailedChecks(_ id: String) {
        if let client, isLive {
            client.send(.taskRerunChecks(.init(id: id)))
            showToast("Running \(id)'s failed checks again", icon: "arrow.clockwise")
            return
        }
        withAnimation(.snappy(duration: 0.25)) {
            update(id) { task in
                guard var pr = task.pr else { return }
                for index in pr.checks.indices where pr.checks[index].status == .failed {
                    pr.checks[index].status = .running
                    pr.checks[index].duration = ""
                }
                task.pr = pr
                task.activity.insert(ActivityItem(who: FactoryData.me.name, text: "Re-ran failed checks", when: "now"), at: 0)
            }
        }
        showToast("Re-running failed checks on #\(task(id).pr?.number ?? 0)", icon: "arrow.clockwise", color: Theme.State.building)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.snappy(duration: 0.3)) {
                self.update(id) { task in
                    guard var pr = task.pr else { return }
                    for index in pr.checks.indices where pr.checks[index].status == .running {
                        pr.checks[index].status = .passed
                        pr.checks[index].duration = "2:\(10 + index * 7)"
                    }
                    task.pr = pr
                    task.checksFailing = false
                    if task.state == .reviewing { task.detail = "All checks passed" }
                }
            }
            self.showToast("Checks passed on #\(self.task(id).pr?.number ?? 0)", icon: "checkmark.seal.fill", color: Theme.State.merged)
            self.sweepForAutoMerge()
        }
    }

    /// Splits an over-budget task into `parts`: the original keeps everything up to its current step,
    /// and the remaining steps become new tasks queued for planning.
    func split(_ id: String, into parts: Int) {
        if let client, isLive {
            client.send(.taskSplit(.init(id: id, parts: UInt32(parts))))
            showToast("Splitting \(id) into \(parts) tasks; the new ones go to planning", icon: "square.split.2x1")
            return
        }
        let original = task(id)
        let steps = original.plan
        guard parts > 1, steps.count >= parts else { return }

        let firstEnd = max(original.activeStep ?? (steps.count / parts - 1), 0)
        let rest = Array(steps[(firstEnd + 1)...])
        let perPart = Int((Double(rest.count) / Double(parts - 1)).rounded(.up))
        let chunks = stride(from: 0, to: rest.count, by: max(perPart, 1)).map { Array(rest[$0..<min($0 + perPart, rest.count)]) }

        let footprint = original.footprint
        let shareFiles = footprint.map { Int((Double($0.files) / Double(parts)).rounded(.up)) } ?? 0
        let shareLines = footprint.map { $0.lines / parts } ?? 0

        var created: [String] = []
        var insertAt = (tasks.firstIndex { $0.id == id } ?? tasks.count - 1) + 1
        for chunk in chunks {
            let newID = nextTaskID(like: id)
            var task = FactoryTask(
                id: newID, goal: original.goal,
                title: chunk.count > 1 ? "\(chunk[0].text) (+\(chunk.count - 1) more)" : chunk[0].text,
                state: .planning, agent: original.agent, owner: original.owner,
                detail: "Split from \(id) · queued",
                span: original.span.upperBound...(original.span.upperBound + 4), updated: "now"
            )
            task.brief = "Split from \(id) to stay inside the PR budget. \(original.brief)"
            task.plan = chunk.map { step in
                var step = step
                step.progress = nil
                step.change = nil
                return step
            }
            task.doneWhen = [
                DoneCriterion(text: "Type-checks cleanly", proof: .terminal),
                DoneCriterion(text: "Existing auth tests still pass", proof: .tests),
            ]
            task.footprint = (shareFiles, shareLines, true)
            task.areas = original.areas
            task.splitFrom = id
            task.activity = [ActivityItem(who: FactoryData.me.name, text: "Created by splitting \(id)", when: "now")]
            tasks.insert(task, at: insertAt)
            insertAt += 1
            created.append(newID)
        }

        withAnimation(.snappy(duration: 0.3)) {
            update(id) { task in
                task.plan = Array(steps[...firstEnd])
                task.footprint = footprint.map { (shareFiles, shareLines, $0.estimated) }
                let done = task.plan.filter { $0.progress == .done }.count
                task.detail = "Step \(min(done + 1, task.plan.count)) of \(task.plan.count)"
                task.progress = Double(done) / Double(max(task.plan.count, 1))
                task.activity.insert(ActivityItem(
                    who: FactoryData.me.name,
                    text: "Split into \(parts) tasks: \(([id] + created).joined(separator: ", "))",
                    when: "now"
                ), at: 0)
            }
        }
        showToast("Split \(id) into \(parts) tasks · \(created.joined(separator: ", ")) queued for planning",
                  icon: "scissors", color: Theme.State.awaitingApproval)
    }

    func keepWhole(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) { _ = keptWhole.insert(id) }
    }

    /// Finds reviewing tasks that now meet every gate and are allowed to auto-merge, and lands them.
    func sweepForAutoMerge() {
        guard !isLive else { return }
        for task in tasks where task.state == .reviewing && !autoMerging.contains(task.id) {
            let gate = mergeGate(for: task)
            guard gate.canMerge, gate.autoMerge else { continue }
            let id = task.id
            withAnimation(.snappy(duration: 0.25)) { _ = autoMerging.insert(id) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                let current = self.task(id)
                let gate = self.mergeGate(for: current)
                guard self.autoMerging.contains(id), current.state == .reviewing, gate.canMerge, gate.autoMerge else {
                    self.autoMerging.remove(id)
                    return
                }
                self.merge(id, byFactory: true)
            }
        }
    }

    private func nextPRNumber() -> Int {
        (tasks.compactMap { $0.pr?.number }.max() ?? 480) + 1
    }

    private func nextTaskID(like id: String) -> String {
        let prefix = id.split(separator: "-").first.map(String.init) ?? "TASK"
        let highest = tasks
            .filter { $0.id.hasPrefix(prefix + "-") }
            .compactMap { Int($0.id.split(separator: "-").last ?? "") }
            .max() ?? 0
        return "\(prefix)-\(highest + 1)"
    }

    // MARK: Launch arguments

    /// Launch arguments like `-destination inbox -layout timeline -inspector NO` jump straight to a view.
    init() {
        let defaults = UserDefaults.standard
        if let layout = defaults.string(forKey: "layout").flatMap({ GoalLayout(rawValue: $0.capitalized) }) {
            self.layout = layout
        }
        switch defaults.string(forKey: "destination") {
        case "inbox": destination = .inbox
        case "mytasks": destination = .myTasks
        case "scratchpad": destination = .scratchpad
        case "usage": destination = .usage
        case "hands": destination = .needsHand
        case "activity": destination = .activity
        case "machines": destination = .machines
        case "requests": destination = .intake
        case "goals": destination = .allGoals
        case let goal?: destination = .goal(goal)
        case nil: break
        }
        if let task = defaults.string(forKey: "task") {
            selectedTask = task
            showInspector = true
        }
        if let task = defaults.string(forKey: "focus") {
            selectedTask = task
            focusedTask = task
        }
        if defaults.object(forKey: "inspector") != nil {
            showInspector = defaults.bool(forKey: "inspector")
        }
        if defaults.bool(forKey: "compose") {
            draft = ComposeDraft(title: "Passkey sign-in on the login page", body: FactoryData.sampleBrief, goal: "Auth overhaul")
            isComposing = true
        }
        if let script = defaults.string(forKey: "actions") {
            Task { @MainActor in await self.play(script) }
        }
    }

    /// Stand-in for the factory's reviewer finishing its round, so the unlock can be shown in mockup mode.
    private func passAutoReview(_ id: String) {
        withAnimation(.snappy(duration: 0.3)) {
            update(id) { task in
                guard var review = task.autoReview, let round = review.current, round.verdict != .passed else { return }
                review.rounds[review.rounds.count - 1] = ReviewRound(number: round.number, verdict: .passed, found: 0, when: "now")
                task.autoReview = review
                task.activity.insert(ActivityItem(who: review.reviewer.name, text: "Passed review round \(round.number)", when: "now"), at: 0)
            }
        }
    }

    /// Plays a demo script such as `approve:ATL-147; split:ATL-144:3; accept:Auth overhaul:high`,
    /// one action per second (`wait:5` for longer), so flows can be shown (or screenshotted) without
    /// clicking. `ui:compose; idea:Dark mode; ui:draft; ui:watch` starts Draft with AI and watches it.
    private func play(_ script: String) async {
        for command in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            try? await Task.sleep(for: .seconds(1))
            let parts = command.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "approve": approvePlan(parts[1])
            case "review": approveChanges(parts[1])
            case "pass": passAutoReview(parts[1])
            case "merge": merge(parts[1])
            // The ⋯ menu's Cancel task…, then its confirmation's Cancel Task.
            case "cancelask": confirmingCancel = parts[1]
            case "cancel": confirmingCancel = nil; cancel(parts[1])
            case "retry": retry(parts[1])
            // The queue: Move to top / bottom, a card dropped on another (`drop:<id>:<before>`),
            // Schedule… with a quick pick (`scheduleask:<id>`, then `schedule:<id>:tonight`), Start now.
            case "top": moveToTop(parts[1])
            case "bottom": moveToBottom(parts[1])
            case "drop": queue(parts[1], before: parts.count > 2 ? parts[2] : nil)
            case "scheduleask": schedulingTask = parts[1]
            case "schedule":
                schedulingTask = nil
                let pick = SchedulePopover.picks.first { $0.label.lowercased().hasPrefix(parts.count > 2 ? parts[2] : "tonight") } ?? SchedulePopover.picks[0]
                schedule(parts[1], at: pick.date())
            case "startnow": startNow(parts[1])
            case "rerun": rerunFailedChecks(parts[1])
            case "split": split(parts[1], into: parts.count > 2 ? Int(parts[2]) ?? 2 : 2)
            case "send": submitDraft(sendToPlanning: true)
            case "steer": steer(parts[1], text: parts.dropFirst(2).joined(separator: ":"), interruptNow: false)
            case "idea": draft.title = parts.dropFirst().joined(separator: ":")
            case "wait": try? await Task.sleep(for: .seconds(Double(parts[1]) ?? 1))
            case "ui":
                switch parts[1] {
                case "compose": startCompose()
                case "cancel": cancelCompose()
                case "draft": draftWithAI()
                case "watch": watchingAIDraft = true
                case "goal": goalSheet = .new
                case "note": newNote()
                // The factory name clicked by accident, then Back: the switch and the way out, without the mouse.
                case "switch": startOnboarding()
                case "back": cancelOnboarding()
                default: break
                }
            case "title": draft.title = parts.dropFirst().joined(separator: ":")
            // What's on the clipboard, pasted into the editor on screen: `paste:editor`.
            case "paste": NotificationCenter.default.post(name: MarkdownEditor.demoPaste, object: nil)
            case "preview": NotificationCenter.default.post(name: MarkdownEditor.demoPreview, object: nil)
            case "hand": resolveHand(parts[1], option: task(parts[1]).hand?.options.first, note: "")
            case "teamslots": setTeamSlots(parts[1], to: Int(parts[2]) ?? 1)
            case "offline": toggleOffline(parts[1])
            case "resume": resumeElsewhere(parts[1])
            case "share": setShareable(parts[1], true)
            case "pause": pauseMachine(parts[1], until: "1:15 AM")
            case "handoff": pauseMachine(parts[1], until: nil, handOff: true)
            case "drive": takeWheel(parts[1])
            case "compose-intake": composeFromIntake(parts[1])
            case "attach": attachIntake(parts[1], to: parts[2])
            case "setup": machineSheet = parts[1] == "new" ? .new : .edit(parts[1])
            case "accept":
                let level = RiskLevel.allCases.first { $0.title.lowercased() == parts.last?.lowercased() } ?? .low
                acceptances[parts[1]] = RiskAcceptance(autoMergeUpTo: level, acceptedBy: FactoryData.me, when: "just now")
            default: break
            }
        }
    }
}
