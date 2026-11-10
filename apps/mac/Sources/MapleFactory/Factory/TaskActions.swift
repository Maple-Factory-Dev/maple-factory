import Foundation
import MapleKit

/// Something you can do to one task: what its ⋯ menu offers, and ⌘K's "This task" section.
enum TaskAction: String, CaseIterable, Hashable {
    case moveToTop, moveToBottom, schedule, startNow, runNow, queue
    case approvePlan, merge
    case sendToPlanning, planAgain, approveAndBuild, sendToBacklog, retry, cancel
    case takeOver, assign, moveToGoal, rename, toggleShareable
    case openPullRequest, copyBranch, copyID, copyLink

    var title: String {
        switch self {
        case .moveToTop: "Move to top"
        case .moveToBottom: "Move to bottom"
        case .schedule: "Schedule…"
        case .startNow: "Start now"
        case .runNow: "Run now, skip the slot wait"
        case .queue: "Queue"
        case .approvePlan: "Approve plan"
        case .merge: "Merge"
        case .sendToPlanning: "Send to planning"
        case .planAgain: "Plan again"
        case .approveAndBuild: "Approve & build"
        case .sendToBacklog: "Send to backlog"
        case .retry: "Retry"
        case .cancel: "Cancel task…"
        case .takeOver: "Take it over"
        case .assign: "Assign…"
        case .moveToGoal: "Move to goal…"
        case .rename: "Rename…"
        case .toggleShareable: "Run on teammates' machines"
        case .openPullRequest: "Open pull request"
        case .copyBranch: "Copy branch name"
        case .copyID: "Copy ID"
        case .copyLink: "Copy link"
        }
    }

    var icon: String {
        switch self {
        case .moveToTop: "arrow.up.to.line"
        case .moveToBottom: "arrow.down.to.line"
        case .schedule: "clock"
        case .startNow: "play"
        case .runNow: "bolt"
        case .queue: "list.number"
        case .approvePlan: "checkmark.seal"
        case .merge: "arrow.triangle.merge"
        case .sendToPlanning, .planAgain: "paperplane"
        case .approveAndBuild: "hammer"
        case .sendToBacklog: TaskState.backlog.icon
        case .retry: "arrow.clockwise"
        case .cancel: "xmark.circle"
        case .takeOver: "person.crop.circle.badge.checkmark"
        case .assign: "person.badge.plus"
        case .moveToGoal: "folder"
        case .rename: "pencil"
        case .toggleShareable: "person.3"
        case .openPullRequest: "arrow.up.right.square"
        case .copyBranch: "arrow.triangle.branch"
        case .copyID: "number"
        case .copyLink: "link"
        }
    }

    var isDestructive: Bool { self == .cancel }

    /// The ones the ⋯ menu doesn't show: the task view has its own Approve and Merge buttons, and Copy link
    /// lives in the share menu.
    var paletteOnly: Bool { self == .approvePlan || self == .merge || self == .copyLink }

    /// Other words people type for it.
    var keywords: [String] {
        switch self {
        case .approvePlan: ["approve", "accept", "sign off", "lgtm"]
        case .merge: ["ship", "land", "pr"]
        case .cancel: ["stop", "kill", "abandon"]
        case .assign: ["owner", "reassign", "give"]
        case .takeOver: ["assign", "mine", "owner"]
        case .moveToGoal: ["goal", "project", "move"]
        case .openPullRequest: ["pr", "github", "review"]
        case .copyLink: ["share", "url"]
        case .retry: ["again", "restart", "rerun"]
        default: []
        }
    }
}

/// What the app knows about a task beyond the task itself, for which of its actions to offer.
struct TaskActionContext: Equatable {
    /// It's mine (Take it over is for someone else's).
    var isMine = true
    /// I'm signed in with a GitHub login to take it over with.
    var canTakeOver = true
    /// Its owner or an admin can hand it to someone (Assign…).
    var canReassign = true
    /// It has a branch to copy.
    var hasBranch = false
    /// There's another goal it could move to.
    var hasMoveTargets = true
    /// I've already approved its plan.
    var iApproved = false
    /// Its merge gate is clear: proofs, checks and reviews in.
    var canMerge = false
    /// A merge is under way.
    var isMerging = false
    /// The caller can show a Schedule… popover / an Assign… picker.
    var canSchedule = true
    var canAssign = true
}

/// Which of a task's actions its state allows, grouped the way the ⋯ menu's dividers group them. The ⋯ menu
/// (TaskActionButtons) and ⌘K's "This task" both read this, so the two never disagree.
enum TaskActions {
    static func available(_ task: FactoryTask, _ ctx: TaskActionContext) -> [[TaskAction]] {
        var groups: [[TaskAction]] = []
        let state = task.state

        // The queue's.
        if task.queued {
            var g: [TaskAction] = [.moveToTop, .moveToBottom]
            if ctx.canSchedule { g.append(.schedule) }
            g.append(.startNow)
            if state == .planning || state == .building { g.append(.runNow) }
            groups.append(g)
        } else if state == .drafting {
            groups.append([.moveToTop, .moveToBottom])
            groups.append(ctx.canSchedule ? [.queue, .schedule] : [.queue])
        }

        // What to do next.
        if state != .merged {
            var g: [TaskAction] = []
            // The approval block's rule, and the merge button's.
            if state == .awaitingApproval && !ctx.iApproved { g.append(.approvePlan) }
            if state == .reviewing && ctx.canMerge && !ctx.isMerging { g.append(.merge) }
            if state == .drafting { g.append(.sendToPlanning) }
            if state == .backlog {
                g.append(task.plan.isEmpty ? .sendToPlanning : .planAgain)
                if !task.plan.isEmpty { g.append(.approveAndBuild) }
            }
            if state == .drafting || state == .awaitingApproval { g.append(.sendToBacklog) }
            // Waiting on its plan's approval or in the backlog, nothing is running to retry.
            if state != .drafting && state != .awaitingApproval && state != .backlog { g.append(.retry) }
            if state != .cancelled && state != .closed { g.append(.cancel) }
            groups.append(g)
        }

        // Editing.
        if !state.isFinished {
            var g: [TaskAction] = []
            if !ctx.isMine && ctx.canTakeOver { g.append(.takeOver) }
            if ctx.canAssign && ctx.canReassign { g.append(.assign) }
            // The menu shows it disabled with nowhere to go; ⌘K leaves it out.
            g.append(.moveToGoal)
            groups.append(g)
            groups.append([.rename, .toggleShareable])
        }

        // Getting at it.
        var g: [TaskAction] = []
        if let pr = task.pr, !pr.isLocal { g.append(.openPullRequest) }
        if ctx.hasBranch { g.append(.copyBranch) }
        g.append(.copyID)
        g.append(.copyLink)
        groups.append(g)
        return groups.filter { !$0.isEmpty }
    }

    /// The ⋯ menu's groups: everything but the palette-only actions.
    static func menu(_ task: FactoryTask, _ ctx: TaskActionContext) -> [[TaskAction]] {
        available(task, ctx).map { $0.filter { !$0.paletteOnly } }.filter { !$0.isEmpty }
    }

    /// ⌘K's flat list, the primary one (Approve plan, Merge) first because it's first in its group.
    static func palette(_ task: FactoryTask, _ ctx: TaskActionContext) -> [TaskAction] {
        let all = available(task, ctx).flatMap { $0 }
        let primary = all.filter { $0 == .approvePlan || $0 == .merge }
        return primary + all.filter { $0 != .approvePlan && $0 != .merge && $0 != .toggleShareable
            && ($0 != .moveToGoal || ctx.hasMoveTargets) }
    }
}
