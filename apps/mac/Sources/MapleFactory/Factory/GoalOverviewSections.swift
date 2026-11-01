import Foundation

/// A goal's tasks sorted by what a person should do with them, for the Overview layout: what's
/// waiting on you, what's up next (and in what order), what's moving, and what landed lately.
/// Each open task sits in exactly one section; cancelled, closed and backlogged tasks and older merges
/// are left out (a backlogged task that needs a person still shows under Needs you).
struct GoalOverviewSections {
    /// Why a task is waiting on a person, most pressing first.
    enum Reason: Int, Comparable {
        case hand, question, approval, review

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The primary action on its card.
        var action: String {
            switch self {
            case .hand: "Lend a hand"
            case .question: "Answer"
            case .approval: "Approve plan"
            case .review: "Review"
            }
        }

        var icon: String {
            switch self {
            case .hand: "hand.raised.fill"
            case .question: "questionmark.bubble.fill"
            case .approval: "checkmark.seal"
            case .review: "eye"
            }
        }
    }

    struct Waiting: Identifiable {
        let task: FactoryTask
        let reason: Reason
        /// One line on what it's waiting for.
        let why: String
        var id: String { task.id }
    }

    var needsYou: [Waiting] = []
    /// The goal's drafts, first first.
    var drafts: [FactoryTask] = []
    /// Waiting for a session, front of the queue first.
    var queued: [FactoryTask] = []
    /// Being planned or waiting for plan approval, with nothing asked of a person.
    var planning: [FactoryTask] = []
    /// Building or in review with nothing asked of a person.
    var inMotion: [FactoryTask] = []
    /// Merged in the last `recentDays`, newest first.
    var recentlyLanded: [FactoryTask] = []

    static let recentDays = 7

    /// Nothing waiting on you, nothing up next and nothing moving.
    var isQuiet: Bool { needsYou.isEmpty && drafts.isEmpty && queued.isEmpty && planning.isEmpty && inMotion.isEmpty }

    /// `today` is a day offset like `FactoryTask.span`'s; `pendingMerge` is a person merges it (the board's Pending merge).
    init(tasks: [FactoryTask], today: Int, pendingMerge: (FactoryTask) -> Bool = { _ in false }) {
        for task in tasks {
            switch task.state {
            case .cancelled, .closed:
                continue
            case .merged:
                if today - task.span.upperBound <= Self.recentDays { recentlyLanded.append(task) }
                continue
            default:
                break
            }
            if let waiting = Self.waiting(task, pendingMerge: pendingMerge(task)) {
                needsYou.append(waiting)
            } else if task.state == .backlog {
                // Parked: it lives on the Board's Backlog column, not in the Overview.
                continue
            } else if task.queued {
                queued.append(task)
            } else {
                switch task.state {
                case .drafting: drafts.append(task)
                case .building, .reviewing: inMotion.append(task)
                case .planning, .awaitingApproval: planning.append(task)
                case .backlog, .merged, .cancelled, .closed: break
                }
            }
        }
        // Stable: within a reason, the goal's own order holds.
        // A review someone requested of you comes first (MF-299), then by reason.
        let asked = { (w: Waiting) in w.task.requested.contains { $0.id == FactoryData.me.id } && w.reason != .hand ? 0 : 1 }
        needsYou = needsYou.enumerated().sorted { (asked($0.element), $0.element.reason, $0.offset) < (asked($1.element), $1.element.reason, $1.offset) }.map(\.element)
        drafts.sort { $0.draftRank < $1.draftRank }
        queued.sort { $0.queueRank < $1.queueRank }
        recentlyLanded.sort { $0.span.upperBound > $1.span.upperBound }
    }

    /// Why a person should step in on it, if they should.
    static func waiting(_ task: FactoryTask, pendingMerge: Bool = false) -> Waiting? {
        if let hand = task.hand {
            return Waiting(task: task, reason: .hand, why: hand.headline.isEmpty ? hand.reason.title : hand.headline)
        }
        guard task.needsYou || pendingMerge else { return nil }
        if let question = task.question {
            return Waiting(task: task, reason: .question, why: question)
        }
        switch task.state {
        case .awaitingApproval where task.requested.contains { $0.id == FactoryData.me.id }:
            return Waiting(task: task, reason: .approval, why: "Your review is requested · plan v\(task.planVersion)")
        case .awaitingApproval:
            return Waiting(task: task, reason: .approval, why: "Plan v\(task.planVersion) is ready for your approval")
        case .reviewing where pendingMerge:
            return Waiting(task: task, reason: .review, why: "Proven, reviewed and green: ready for you to merge")
        default:
            return Waiting(task: task, reason: .review, why: task.detail.isEmpty ? "Waiting for your sign-off" : task.detail)
        }
    }

    /// Its plan's steps done and in all, while it has a plan with progress.
    static func steps(_ task: FactoryTask) -> (done: Int, total: Int)? {
        guard task.plan.contains(where: { $0.progress != nil }) else { return nil }
        return (task.plan.filter { $0.progress == .done }.count, task.plan.count)
    }
}

/// A section of the Overview a person can collapse to its header.
enum OverviewSection: String, CaseIterable {
    case needsYou, upNext, queue, drafts, planning, inMotion, landed
}

/// Which Overview sections are collapsed, kept as a comma-joined string so @AppStorage can hold it.
struct OverviewCollapse: Equatable {
    var collapsed: Set<OverviewSection>

    /// Only Recently landed starts collapsed.
    static let defaultRaw = OverviewSection.landed.rawValue

    init(collapsed: Set<OverviewSection> = [.landed]) { self.collapsed = collapsed }

    /// Unknown or empty keys are dropped.
    init(raw: String) {
        collapsed = Set(raw.split(separator: ",").compactMap { OverviewSection(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    /// In `OverviewSection.allCases` order, so the same set always stores the same string.
    var raw: String { OverviewSection.allCases.filter(collapsed.contains).map(\.rawValue).joined(separator: ",") }

    func isCollapsed(_ section: OverviewSection) -> Bool { collapsed.contains(section) }

    func toggling(_ section: OverviewSection) -> Self {
        var next = self
        if next.collapsed.remove(section) == nil { next.collapsed.insert(section) }
        return next
    }
}
