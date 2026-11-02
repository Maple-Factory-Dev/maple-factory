import Foundation

/// A factory as its `/client/connect` feed describes it: the snapshot, then each delta applied in
/// turn. Pure, so the iOS app's store can keep one and tests can feed it messages directly.
public struct FeedState: Sendable {
    public var org = ""
    /// The factory's display name, when it has one.
    public var name: String?
    public var me: Wire.Member?
    public var members: [Wire.Member] = []
    public var machines: [Wire.Machine] = []
    public var goals: [Wire.Goal] = []
    /// The org's repos (Settings → Repositories on the Mac), for a goal's repo picker.
    public var repos: [Wire.OrgRepo] = []
    /// Secret names per repo (never values), and who last changed each.
    public var secrets: [Wire.RepoSecret] = []
    /// Repos whose merges are on hold.
    public var mergeHolds: [Wire.MergeHold] = []
    /// Newest first, as the server sends them.
    public var tasks: [Wire.Task] = []
    public var intake: [Wire.IntakeRequest] = []
    /// Goals you follow (true) or unfollowed (false); a goal missing here follows the defaults.
    public var follows: [String: Bool] = [:]
    public var online: [Wire.Presence] = []
    public var runnerLatest: String?
    public var serverVersion: String?
    /// What githubstatus.com reports while GitHub is having issues; nil while all is clear.
    public var githubStatus: Wire.GitHubStatus?
    /// The factory's rules for sign-off and auto-merge, by risk.
    public var policy: Wire.RiskPolicy?
    /// Goals letting the factory auto-merge up to a risk level.
    public var acceptances: [Wire.RiskAcceptance] = []
    /// Every goal's recurring tasks, by id. Empty from an older server.
    public var recurring: [String: Wire.Recurring] = [:]
    public var hasSnapshot = false
    /// The finished tasks the snapshot left out (older than its 14 days) and not loaded since, by goal id.
    /// Empty from an older server, which sends every task.
    public var older: [String: OlderTasks] = [:]
    /// Goals whose next page of older tasks is on its way.
    public var loadingOlder: Set<String> = []
    /// Where each goal's next page of older tasks starts: the last task of its last page.
    public var olderCursor: [String: OlderCursor] = [:]
    /// Tasks asked for by ID (`task.get`) that haven't come yet.
    public var fetching: Set<String> = []

    public init() {}

    /// What a message says that isn't state: a toast or an error to show.
    public enum Notice: Equatable, Sendable {
        case toast(String, taskId: String?)
        case error(String)
    }

    /// Applies one message from the feed; returns a toast or error for the app to show.
    @discardableResult
    public mutating func apply(_ message: Wire.ServerToClient) -> Notice? {
        switch message {
        case .snapshot(let snapshot):
            org = snapshot.org
            name = snapshot.name
            me = snapshot.me
            members = snapshot.members
            machines = snapshot.machines
            goals = snapshot.goals
            repos = snapshot.repos
            secrets = snapshot.secrets
            mergeHolds = snapshot.mergeHolds ?? []
            tasks = snapshot.tasks
            older = Self.older(tallies: snapshot.tallies, tasks: snapshot.tasks)
            loadingOlder = []
            olderCursor = [:]
            fetching = []
            intake = snapshot.intake
            follows = Dictionary(snapshot.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
            online = snapshot.online
            runnerLatest = snapshot.runnerLatest
            serverVersion = snapshot.serverVersion
            githubStatus = Self.githubNotice(snapshot.githubStatus)
            policy = snapshot.policy
            acceptances = snapshot.acceptances
            recurring = Dictionary((snapshot.recurring ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            hasSnapshot = true
        case .taskUpdated(let update) where fetching.contains(update.task.id):
            // A task asked for by ID (`task.get`), maybe one the snapshot left out.
            fetching.remove(update.task.id)
            mergeOlder([update.task])
        case .taskUpdated(let update):
            Self.upsert(update.task, into: &tasks, front: true)
        case .tasksPage(let page):
            pageArrived(page)
        case .taskRemoved(let removed):
            tasks.removeAll { $0.id == removed.id }
        case .goalUpdated(let update):
            Self.upsert(update.goal, into: &goals, front: false)
        case .machineUpdated(let update):
            Self.upsert(update.machine, into: &machines, front: false)
        case .machineRemoved(let removed):
            machines.removeAll { $0.id == removed.id }
        case .intakeUpdated(let update):
            Self.upsert(update.request, into: &intake, front: true)
        case .followsUpdated(let update):
            follows = Dictionary(update.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
        case .membersUpdated(let update):
            members = update.members
            if let login = me?.login, let updated = members.first(where: { $0.login == login }) { me = updated }
        case .presence(let presence):
            online = presence.online
        case .reposUpdated(let update):
            repos = update.repos
        case .secretsUpdated(let update):
            secrets = update.secrets
        case .mergeHoldsUpdated(let update):
            mergeHolds = update.holds
        case .nameUpdated(let update):
            name = update.name
        case .runnerReleased(let release):
            runnerLatest = release.runnerLatest
        case .githubStatus(let update):
            githubStatus = Self.githubNotice(update.status)
        case .policyUpdated(let update):
            policy = update.policy
            acceptances = update.acceptances
        case .recurringUpdated(let update):
            recurring[update.recurring.id] = update.recurring
        case .recurringDeleted(let deleted):
            recurring[deleted.id] = nil
        case .toast(let toast):
            return .toast(toast.text, taskId: toast.taskId)
        case .error(let error):
            if let id = error.requestId, id.hasPrefix("task.get:") {
                fetching.remove(String(id.dropFirst("task.get:".count)))
            }
            return .error(error.message)
        default:
            break
        }
        return nil
    }

    /// An all-clear status (indicator none, nothing listed) is no notice.
    public static func githubNotice(_ status: Wire.GitHubStatus?) -> Wire.GitHubStatus? {
        guard let status else { return nil }
        return status.indicator == .none && status.incidents.isEmpty && status.components.isEmpty ? nil : status
    }

    private static func upsert<T: Identifiable>(_ item: T, into list: inout [T], front: Bool) {
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list[index] = item
        } else if front {
            list.insert(item, at: 0)
        } else {
            list.append(item)
        }
    }

    // MARK: Older tasks

    /// What the snapshot left out of each goal: its tally (counted over every task) less the tasks it sent.
    public static func older(tallies: [Wire.GoalTally]?, tasks: [Wire.Task]) -> [String: OlderTasks] {
        guard let tallies else { return [:] }
        var held: [String: OlderTasks] = [:]
        for task in tasks { held[task.goal, default: OlderTasks()].count(task.state, by: 1) }
        var older: [String: OlderTasks] = [:]
        for tally in tallies {
            let sent = held[tally.goal] ?? OlderTasks()
            let finished = Int(tally.merged) + Int(tally.cancelled) + Int(tally.closed)
            older[tally.goal] = OlderTasks(merged: max(0, Int(tally.merged) - sent.merged), finished: max(0, finished - sent.finished))
        }
        return older
    }

    /// A page of older tasks: they join the list, and the goal's cursor moves to its last one.
    public mutating func pageArrived(_ page: Wire.ServerToClientTasksPage) {
        let goal = page.goal ?? ""
        loadingOlder.remove(goal)
        if let last = page.tasks.last { olderCursor[goal] = OlderCursor(before: last.updatedAt, id: last.id) }
        mergeOlder(page.tasks)
        // The server knows best: none left means none left, whatever the counts drifted to.
        if !page.more, let id = page.goal { older[id] = OlderTasks() }
    }

    /// Older tasks from `tasks.page` or `task.get` join the end of the list, and the counts left out go
    /// down; one a live update already brought stays as it is. Returns the ones added.
    @discardableResult
    public mutating func mergeOlder(_ page: [Wire.Task]) -> [Wire.Task] {
        let held = Set(tasks.map(\.id))
        let new = page.filter { !held.contains($0.id) }
        for task in new { older[task.goal]?.count(task.state, by: -1) }
        tasks.append(contentsOf: new)
        return new
    }

    /// Whether `goal` (its id) has finished tasks older than the snapshot's that aren't loaded yet.
    public func hasOlder(goal: String) -> Bool { (older[goal]?.finished ?? 0) > 0 }

    /// The `tasks.older` that loads `goal`'s next page, marking it on its way; nil when there's none or it's coming.
    public mutating func olderRequest(goal: String, limit: UInt32 = 50) -> Wire.ClientMessage? {
        guard hasOlder(goal: goal), !loadingOlder.contains(goal) else { return nil }
        loadingOlder.insert(goal)
        let cursor = olderCursor[goal]
        return .tasksOlder(.init(goal: goal, before: cursor?.before, beforeId: cursor?.id, limit: limit))
    }

    /// The `task.get` for a task opened by ID that isn't loaded; nil when it's here or already asked for.
    public mutating func fetchRequest(id: String) -> Wire.ClientMessage? {
        guard hasSnapshot, !fetching.contains(id), task(id) == nil else { return nil }
        fetching.insert(id)
        return .taskGet(.init(id: id))
    }

    // MARK: Reading

    public func task(_ id: String) -> Wire.Task? { tasks.first { $0.id == id } }
    public func goal(_ id: String) -> Wire.Goal? { goals.first { $0.id == id } }
    public func member(_ login: String) -> Wire.Member? { members.first { $0.login == login } }

    /// Goals still in play, in the order the factory keeps them.
    public var activeGoals: [Wire.Goal] { goals.filter { $0.archived != true } }

    public func tasks(in goal: String) -> [Wire.Task] { tasks.filter { $0.goal == goal } }

    /// A goal's recurring tasks (by goal id): running ones first, then soonest next run, as the Mac lists them.
    public func recurring(goal: String) -> [Wire.Recurring] {
        recurring.values.filter { $0.goal == goal }.sorted { ($0.paused ? 1 : 0, $0.nextAt, $0.id) < ($1.paused ? 1 : 0, $1.nextAt, $1.id) }
    }

    /// How far the factory may auto-merge the goal's work, on the record; nil: not at all.
    public func acceptance(for goal: String) -> Wire.RiskAcceptance? { acceptances.last { $0.goal == goal } }

    /// Whether `me` may change the goal's auto-merge or archive it: its lead or an admin, as the server checks.
    public func canLead(_ goal: Wire.Goal, me: Wire.Member?) -> Bool {
        guard let me else { return false }
        return me.role == "admin" || goal.lead == me.login
    }

    /// The goal's tasks that archiving would ask about: any not merged or cancelled, as the server counts them.
    public func unfinishedTasks(in goal: String) -> [Wire.Task] {
        tasks.filter { $0.goal == goal && $0.state != .merged && $0.state != .cancelled }
    }

    /// Whether you follow the goal: you said so, or you lead it, own a task in it, or are on its team.
    public func following(_ goal: Wire.Goal) -> Bool {
        if let choice = follows[goal.id] { return choice }
        guard let me else { return true }
        if goal.lead == me.login { return true }
        if let team = goal.team, me.teams.contains(team) { return true }
        return tasks.contains { $0.goal == goal.id && $0.owner == me.login }
    }

    // MARK: Inbox

    /// What needs people, grouped like the Mac inbox: plans to approve, raised hands, agents'
    /// questions, changes ready for review, failing checks and @mentions of `login`.
    public func inbox(for login: String) -> [InboxEntry] {
        var entries: [InboxEntry] = []
        for task in tasks where task.state != .merged && task.state != .cancelled {
            if task.state == .awaitingApproval && !task.approvals.contains(login) {
                entries.append(InboxEntry(kind: .approval, task: task.id, assignee: login, message: "Plan v\(task.planVersion) is ready for your approval", at: task.updatedAt))
            }
            if let hand = task.hand {
                entries.append(InboxEntry(kind: .hand, task: task.id, assignee: hand.assignee, message: hand.summary, at: hand.at))
            }
            if let question = task.question {
                entries.append(InboxEntry(kind: .question, task: task.id, assignee: task.owner, message: question.text, at: question.at))
            }
            if task.state == .reviewing, !task.reviews.contains(login), task.autoReview?.rounds.last?.verdict == .passed {
                entries.append(InboxEntry(kind: .review, task: task.id, assignee: task.owner, message: "Passed automatic review; ready for yours", at: task.updatedAt))
            }
            if task.pr?.checks.contains(where: { $0.status == .failed }) ?? false {
                entries.append(InboxEntry(kind: .failing, task: task.id, assignee: task.owner, message: "Checks are failing", at: task.updatedAt))
            }
            for comment in task.comments where comment.author != login && (comment.mentions ?? []).contains(login) {
                entries.append(InboxEntry(kind: .mention, task: task.id, assignee: login, message: "\(comment.author): \(comment.text)", at: comment.at, comment: comment.id))
            }
        }
        return entries.sorted { $0.at > $1.at }
    }

    // MARK: Activity

    /// Every task's events as one feed, newest first: what the Mac's Activity page lists, filtered like it.
    /// `me` is whose tasks are "My tasks".
    public func activity(filter: ActivityEntry.Filter = .everyone, me: String? = nil) -> [ActivityEntry] {
        var all: [ActivityEntry] = []
        all.reserveCapacity(tasks.reduce(0) { $0 + $1.events.count })
        for task in tasks {
            switch filter {
            case .mine where task.owner != me: continue
            default: break
            }
            for (index, event) in task.events.enumerated() {
                let entry = ActivityEntry(task: task.id, index: index, who: event.who, text: event.text, at: event.at)
                switch filter {
                case .people where entry.isAgent, .agents where !entry.isAgent: continue
                default: all.append(entry)
                }
            }
        }
        // Stable for equal times: the order tasks and events arrived in.
        return all.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset }.map(\.element)
    }

    // MARK: Versions

    /// Whether `a` is an older version than `b` ("0.2.0" < "0.10.1"); anything after a "-" is ignored.
    public static func version(_ a: String, isOlderThan b: String) -> Bool {
        let parts = { (v: String) in v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q }
        }
        return false
    }

    /// Whether the machine's runner is older than the latest release.
    public func runnerOutdated(_ machine: Wire.Machine) -> Bool {
        guard let version = machine.version, let runnerLatest else { return false }
        return Self.version(version, isOlderThan: runnerLatest)
    }
}

/// One thing in the inbox: a task waiting on someone, and why.
public struct InboxEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case approval, hand, question, review, failing, mention

        public var title: String {
            switch self {
            case .approval: "Plans awaiting approval"
            case .hand: "Raised hands"
            case .question: "Questions from agents"
            case .review: "Ready for review"
            case .failing: "Failing checks"
            case .mention: "Mentions"
            }
        }
    }

    public let kind: Kind
    public let task: String
    /// Whose it is to act on.
    public let assignee: String
    public let message: String
    public let at: UInt64
    /// For a mention, the comment it's about, so each one in a task is its own row.
    public var comment: String? = nil

    public var id: String { "\(kind.rawValue)-\(comment ?? task)" }

    public init(kind: Kind, task: String, assignee: String, message: String, at: UInt64, comment: String? = nil) {
        self.kind = kind
        self.task = task
        self.assignee = assignee
        self.message = message
        self.at = at
        self.comment = comment
    }
}

/// One line of the Activity feed: something a person or agent did on a task.
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public enum Filter: String, CaseIterable, Sendable { case everyone = "Everyone", people = "People", agents = "Agents", mine = "My tasks" }

    /// Who counts as an agent rather than a person.
    public static let agents: Set<String> = ["planner", "builder", "reviewer", "factory"]
    public static let pageSize = 50

    /// "<task>-<index of the event in the task>".
    public let id: String
    public let task: String
    public let who: String
    public let text: String
    /// When it happened, in ms since 1970.
    public let at: UInt64

    public var isAgent: Bool { Self.agents.contains(who) }
    public var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }

    public init(task: String, index: Int, who: String, text: String, at: UInt64) {
        self.id = "\(task)-\(index)"
        self.task = task
        self.who = who
        self.text = text
        self.at = at
    }
}

extension Wire.Task: Identifiable {}
extension Wire.Goal: Identifiable {}
extension Wire.Machine: Identifiable {}
extension Wire.IntakeRequest: Identifiable {}

/// A goal's finished tasks the snapshot left out and that aren't loaded yet.
public struct OlderTasks: Equatable, Sendable {
    public var merged = 0
    /// Merged, cancelled and closed.
    public var finished = 0

    public init(merged: Int = 0, finished: Int = 0) {
        self.merged = merged
        self.finished = finished
    }

    public mutating func count(_ state: Wire.TaskState, by n: Int) {
        switch state {
        case .merged: merged = max(0, merged + n); finished = max(0, finished + n)
        case .cancelled, .closed: finished = max(0, finished + n)
        default: break
        }
    }
}

/// Where a goal's next page of older tasks starts.
public struct OlderCursor: Equatable, Sendable {
    public var before: UInt64
    public var id: String

    public init(before: UInt64, id: String) {
        self.before = before
        self.id = id
    }
}
