import Testing
@testable import MapleFactory

/// When a plan's step changes from the previous version are marked up by default.
@MainActor
struct PlanChangesTests {
    private func task(version: Int, _ state: TaskState, changed: Bool = true) -> FactoryTask {
        var task = FactoryTask(id: "MF-1", title: "Plan", state: state, detail: "")
        task.planVersion = version
        task.plan = [
            PlanStep(text: "Keep", file: "a.swift"),
            PlanStep(text: "Revised", file: "b.swift", change: changed ? .modified(from: "Old") : nil),
            PlanStep(text: "Extra", file: "c.swift", change: changed ? .added : nil),
        ]
        return task
    }

    @Test func firstVersionIsNeverFresh() {
        #expect(!task(version: 1, .awaitingApproval).planChangesFresh)
    }

    @Test func revisionAwaitingApprovalIsFresh() {
        #expect(task(version: 3, .awaitingApproval).planChangesFresh)
        #expect(task(version: 2, .awaitingApproval).planChangesFresh)
    }

    @Test(arguments: [TaskState.building, .reviewing, .merged, .backlog])
    func approvedRevisionIsNotFresh(_ state: TaskState) {
        #expect(!task(version: 3, state).planChangesFresh)
    }

    @Test func revisionWithNoChangedStepsIsNotFresh() {
        #expect(!task(version: 3, .awaitingApproval, changed: false).planChangesFresh)
    }
}
