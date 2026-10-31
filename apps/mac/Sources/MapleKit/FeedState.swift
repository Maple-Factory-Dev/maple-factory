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
    /// Newest first, as the server sends them.
    public var tasks: [Wire.Task] = []
    public var intake: [Wire.IntakeRequest] = []
    /// Goals you follow (true) or unfollowed (false); a goal missing here follows the defaults.
    public var follows: [String: Bool] = [:]
    public var online: [Wire.Presence] = []
    public var runnerLatest: String?
    public var serverVersion: String?
    public var hasSnapshot = false

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
            tasks = snapshot.tasks
            intake = snapshot.intake
            follows = Dictionary(snapshot.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
            online = snapshot.online
            runnerLatest = snapshot.runnerLatest
            serverVersion = snapshot.serverVersion
            hasSnapshot = true
        case .taskUpdated(let update):
            Self.upsert(update.task, into: &tasks, front: true)
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
        case .nameUpdated(let update):
            name = update.name
        case .runnerReleased(let release):
            runnerLatest = release.runnerLatest
        case .toast(let toast):
            return .toast(toast.text, taskId: toast.taskId)
        case .error(let error):
            return .error(error.message)
        default:
            break
        }
        return nil
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

    // MARK: Reading

    public func task(_ id: String) -> Wire.Task? { tasks.first { $0.id == id } }
    public func goal(_ id: String) -> Wire.Goal? { goals.first { $0.id == id } }
    public func member(_ login: String) -> Wire.Member? { members.first { $0.login == login } }

    /// Goals still in play, in the order the factory keeps them.
    public var activeGoals: [Wire.Goal] { goals.filter { $0.archived != true } }

    public func tasks(in goal: String) -> [Wire.Task] { tasks.filter { $0.goal == goal } }

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
            if task.state == .reviewing, !task.reviews.contains(login), task.autoReview.map({ $0.rounds.last?.verdict == .passed }) ?? true {
                entries.append(InboxEntry(kind: .review, task: task.id, assignee: task.owner, message: task.mergeAt != nil ? "Merging soon unless someone holds it" : "Ready for your review", at: task.updatedAt))
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

extension Wire.Task: Identifiable {}
extension Wire.Goal: Identifiable {}
extension Wire.Machine: Identifiable {}
extension Wire.IntakeRequest: Identifiable {}
