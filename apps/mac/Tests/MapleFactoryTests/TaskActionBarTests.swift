import Foundation
import Testing
@testable import MapleFactory

/// MF-257: the action bar under a task's title offers the next step for drafts, queued plans and the
/// backlog, primary first, and nothing for states that have their own block (or nothing to pick).
@MainActor struct TaskActionBarTests {
    private func task(state: String, planned: Bool = false, running: Bool = false) throws -> FactoryTask {
        let plan = planned ? #","plan":[{"text":"Add hello.txt","file":"hello.txt","progress":"pending","added":false}]"# : ""
        let worker = running ? #","worker":{"role":"planner","agent":"claude","machine":"m","session":"s","startedAt":1}"# : ""
        let wire = try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"\(state)","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":\(planned ? 2 : 0),"approvalsNeeded":1,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"\(plan)\(worker)}
        """.utf8))
        return LiveAdapter.task(wire, goals: [], members: [], me: "andrea")
    }

    @Test func aDraftSendsToPlanningFirst() throws {
        let actions = TaskNextActions.for(try task(state: "drafting"))
        #expect(actions == [.sendToPlanning, .queue, .schedule, .sendToBacklog])
        #expect(actions.first?.title == "Send to planning")
    }

    @Test func aQueuedPlanCanStartNow() throws {
        let t = try task(state: "planning")
        #expect(t.queued)
        #expect(TaskNextActions.for(t) == [.startNow, .runNow, .schedule])
    }

    @Test func aRunningPlanHasNoBar() throws {
        let t = try task(state: "planning", running: true)
        #expect(!t.queued)
        #expect(TaskNextActions.for(t).isEmpty)
    }

    @Test func theBacklogApprovesAPlanOrPlansOne() throws {
        #expect(TaskNextActions.for(try task(state: "backlog", planned: true)) == [.approveAndBuild, .planAgain])
        #expect(TaskNextActions.for(try task(state: "backlog", planned: false)) == [.sendToPlanning])
    }

    @Test func statesWithTheirOwnBlockHaveNoBar() throws {
        for state in ["awaitingApproval", "building", "merged"] {
            #expect(TaskNextActions.for(try task(state: state, planned: true)).isEmpty, "\(state)")
        }
    }
}
