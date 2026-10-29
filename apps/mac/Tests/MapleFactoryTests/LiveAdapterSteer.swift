import Foundation
import Testing
@testable import MapleFactory

/// A planner session closes once it submits its plan, so a plan waiting for approval has no worker.
/// It still has to be steerable, or Request changes quietly posts a comment instead of asking for plan v2 (MF-26).
@MainActor struct LiveAdapterSteer {
    private func task(state: String, worker: String? = nil) throws -> Wire.Task {
        let worker = worker.map { #","worker":{"role":"\#($0)","agent":"claude","machine":"m","session":"s","startedAt":1}"# } ?? ""
        return try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"\(state)","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"\(worker)}
        """.utf8))
    }

    private func adapt(_ t: Wire.Task) -> FactoryTask {
        LiveAdapter.task(t, goals: [], members: [], me: nil)
    }

    @Test func aWaitingPlanWithNoSessionStillSteersThePlanner() throws {
        let task = adapt(try task(state: "awaitingApproval"))
        #expect(task.worker == nil)
        #expect(task.agent?.name == "Planner")
        #expect(task.isSteerable)
    }

    @Test func aReviewWithNoSessionSteersTheBuilder() throws {
        let task = adapt(try task(state: "reviewing"))
        #expect(task.worker == nil)
        #expect(task.agent?.name == "Builder")
        #expect(task.isSteerable)
    }

    @Test func aRunningSessionStillNamesItsAgent() throws {
        let task = adapt(try task(state: "reviewing", worker: "reviewer"))
        #expect(task.worker != nil)
        #expect(task.agent?.name == FactoryData.reviewer.name)
    }

    @Test func finishedWorkHasNoAgent() throws {
        #expect(adapt(try task(state: "merged")).agent == nil)
        #expect(!adapt(try task(state: "drafting")).isSteerable)
    }
}
