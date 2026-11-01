import Foundation

/// A goal's tasks sorted by what a person should do with them, like the Mac's Overview
/// (GoalOverviewSections) but over Wire tasks, for the iOS goal page: what's waiting on you,
/// what's up next (and in what order), what's moving, and what landed lately.
/// Each open task sits in exactly one section; cancelled, closed and backlogged tasks and older
/// merges are left out (a backlogged task that needs you still shows under Needs you).
public struct GoalOverview: Equatable, Sendable {
    /// Why a task is waiting on a person, most pressing first.
    public enum Reason: Int, Comparable, Sendable {
        case hand, question, approval, review

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The primary action on its card.
        public var action: String {
            switch self {
            case .hand: "Lend a hand"
            case .question: "Answer"
            case .approval: "Approve plan"
            case .review: "Review"
            }
        }

        public var icon: String {
            switch self {
            case .hand: "hand.raised.fill"
            case .question: "questionmark.bubble.fill"
            case .approval: "checkmark.seal"
            case .review: "eye"
            }
        }
    }

    public struct Waiting: Identifiable, Equatable, Sendable {
        public let task: Wire.Task
        public let reason: Reason
        /// One line on what it's waiting for.
        public let why: String
        /// Someone asked you by name to sign it off.
        public let requested: Bool
        public var id: String { task.id }
    }

    public var needsYou: [Waiting] = []
    /// Waiting for a session with nobody on it, front of the queue first.
    public var queued: [Wire.Task] = []
    /// Being planned or waiting for plan approval, with nothing asked of you.
    public var planning: [Wire.Task] = []
    /// The goal's drafts, first first.
    public var drafts: [Wire.Task] = []
    /// Building or in review with nothing asked of you.
    public var inMotion: [Wire.Task] = []
    /// Merged in the last `recentDays`, newest first.
    public var recentlyLanded: [Wire.Task] = []

    public static let recentDays = 7

    /// Nothing waiting on you, nothing up next and nothing moving.
    public var isQuiet: Bool { needsYou.isEmpty && upNextCount == 0 && inMotion.isEmpty }
    public var upNextCount: Int { queued.count + planning.count + drafts.count }

    /// `me` is whose Needs you it is; `now` is in ms since 1970.
    public init(tasks: [Wire.Task], me: String?, now: UInt64) {
        let window = UInt64(Self.recentDays) * 86_400_000
        for task in tasks {
            switch task.state {
            case .cancelled, .closed:
                continue
            case .merged:
                if task.updatedAt + window >= now { recentlyLanded.append(task) }
                continue
            default:
                break
            }
            if let waiting = Self.waiting(task, me: me) {
                needsYou.append(waiting)
            } else if task.state == .backlog {
                // Parked: it lives in All tasks, not the Overview.
                continue
            } else if Self.queued(task) {
                queued.append(task)
            } else {
                switch task.state {
                case .drafting: drafts.append(task)
                case .building, .reviewing: inMotion.append(task)
                case .planning, .awaitingApproval: planning.append(task)
                default: break
                }
            }
        }
        // A sign-off asked of you by name comes first, then by reason; stable within those.
        let asked = { (w: Waiting) in w.requested && w.reason != .hand ? 0 : 1 }
        needsYou = needsYou.enumerated()
            .sorted { (asked($0.element), $0.element.reason, $0.offset) < (asked($1.element), $1.element.reason, $1.offset) }
            .map(\.element)
        drafts.sort { ($0.draftRank ?? Double($0.createdAt), $0.id) < ($1.draftRank ?? Double($1.createdAt), $1.id) }
        queued.sort { ($0.queueRank ?? Double($0.createdAt), $0.id) < ($1.queueRank ?? Double($1.createdAt), $1.id) }
        recentlyLanded.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Waiting for its next session with nobody on it: the Mac board's Queued column.
    public static func queued(_ t: Wire.Task) -> Bool {
        guard t.worker == nil, t.hand == nil, t.question == nil else { return false }
        switch t.state {
        case .planning: return true
        case .building: return t.waiting != nil
        case .reviewing: return t.autoReview?.rounds.last?.verdict == .inProgress
        default: return false
        }
    }

    /// Why `me` should step in on it, if they should (the Mac's and the inbox's rules).
    public static func waiting(_ t: Wire.Task, me: String?) -> Waiting? {
        guard let me else { return nil }
        let requested = t.requested.contains(me) && (t.state == .awaitingApproval || t.state == .reviewing)
        if let hand = t.hand, hand.assignee == me {
            return Waiting(task: t, reason: .hand, why: hand.summary, requested: requested)
        }
        if let question = t.question, t.owner == me {
            return Waiting(task: t, reason: .question, why: question.text, requested: requested)
        }
        if t.state == .awaitingApproval, requested || !t.approvals.contains(me) {
            let why = requested ? "Your review is requested · plan v\(t.planVersion)" : "Plan v\(t.planVersion) is ready for your approval"
            return Waiting(task: t, reason: .approval, why: why, requested: requested)
        }
        if t.state == .reviewing {
            if requested { return Waiting(task: t, reason: .review, why: "Your review is requested", requested: true) }
            if t.autoReview?.rounds.last?.verdict == .passed, t.reviews.count < t.reviewsNeeded, !t.reviews.contains(me) {
                return Waiting(task: t, reason: .review, why: "Passed automatic review; ready for yours", requested: false)
            }
        }
        return nil
    }

    /// Its plan's steps done and in all, while it has a plan with progress.
    public static func steps(_ t: Wire.Task) -> (done: Int, total: Int)? {
        guard t.plan.contains(where: { $0.progress != nil }) else { return nil }
        return (t.plan.filter { $0.progress == .done }.count, t.plan.count)
    }
}

extension FeedState {
    /// A goal's tasks in Overview sections for `me` (default: whoever is signed in).
    public func overview(goal: String, me: String? = nil, now: Date = Date()) -> GoalOverview {
        GoalOverview(tasks: tasks(in: goal), me: me ?? self.me?.login, now: UInt64(now.timeIntervalSince1970 * 1000))
    }
}
