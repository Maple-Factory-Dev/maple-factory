import Testing
@testable import MapleFactory

/// The ⋯ menu's actions, pinned to what TaskActionButtons showed before it read `TaskActions`.
@MainActor
struct TaskActionsTests {
    private let teammate = Person(name: "Sam Rivera", color: .blue, isHuman: true, github: "sam")

    private func task(_ state: TaskState, queued: Bool = false, planned: Bool = false, pr: Bool = false) -> FactoryTask {
        var task = FactoryTask(id: "MF-1", title: "A task", state: state, owner: FactoryData.me, detail: "")
        task.queued = queued
        if planned { task.plan = [PlanStep(text: "Do it", file: "a.swift")] }
        if pr { task.pr = PullRequest(number: 7, state: .open, checks: []) }
        return task
    }

    private func menu(_ task: FactoryTask, _ ctx: TaskActionContext = TaskActionContext()) -> [[TaskAction]] {
        TaskActions.menu(task, ctx)
    }

    private let edits: [[TaskAction]] = [[.assign, .moveToGoal], [.rename, .toggleShareable]]

    @Test func everyStateKeepsItsMenu() {
        let expected: [TaskState: [[TaskAction]]] = [
            .drafting: [[.moveToTop, .moveToBottom], [.queue, .schedule], [.sendToPlanning, .sendToBacklog, .cancel]] + edits + [[.copyID]],
            .planning: [[.retry, .cancel]] + edits + [[.copyID]],
            .awaitingApproval: [[.sendToBacklog, .cancel]] + edits + [[.copyID]],
            .backlog: [[.sendToPlanning, .cancel]] + edits + [[.copyID]],
            .building: [[.retry, .cancel]] + edits + [[.copyID]],
            .reviewing: [[.retry, .cancel]] + edits + [[.copyID]],
            .merged: [[.copyID]],
            .cancelled: [[.retry], [.copyID]],
            .closed: [[.retry], [.copyID]],
        ]
        for state in TaskState.allCases {
            #expect(menu(task(state)) == expected[state], "\(state)")
        }
    }

    @Test func queuedPlanningOffersTheQueue() {
        #expect(menu(task(.planning, queued: true)) ==
                [[.moveToTop, .moveToBottom, .schedule, .startNow, .runNow], [.retry, .cancel]] + edits + [[.copyID]])
        #expect(menu(task(.planning, queued: true), TaskActionContext(canSchedule: false)).first ==
                [.moveToTop, .moveToBottom, .startNow, .runNow])
    }

    @Test func plannedBacklogPlansAgainOrBuilds() {
        #expect(menu(task(.backlog, planned: true)).first == [.planAgain, .approveAndBuild, .cancel])
    }

    @Test func teammatesTaskAndGettingAtIt() {
        var ctx = TaskActionContext(isMine: false, canReassign: false, hasBranch: true, hasMoveTargets: false, canAssign: true)
        // Move to goal stays in the menu (disabled there) with nowhere to go.
        #expect(menu(task(.building, pr: true), ctx) ==
                [[.retry, .cancel], [.takeOver, .moveToGoal], [.rename, .toggleShareable], [.openPullRequest, .copyBranch, .copyID]])
        ctx.canTakeOver = false
        #expect(menu(task(.building), ctx)[1] == [.moveToGoal])
    }

    @Test func menuLeavesOutPaletteOnlyActions() {
        let ctx = TaskActionContext(canMerge: true)
        for state in TaskState.allCases {
            let all = menu(task(state), ctx).flatMap { $0 }
            #expect(!all.contains(.approvePlan) && !all.contains(.merge) && !all.contains(.copyLink))
        }
    }
}
