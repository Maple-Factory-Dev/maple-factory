import Foundation
import Testing
@testable import MapleFactory

/// MF-67: a task parked in the backlog decodes, shows in its own column, and nothing about it says it needs you.
@MainActor struct BacklogTests {
    private func task(state: String, planned: Bool) throws -> Wire.Task {
        let plan = planned ? #","plan":[{"text":"Add hello.txt","file":"hello.txt","progress":"pending","added":false}]"# : ""
        return try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"\(state)","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":\(planned ? 2 : 0),"approvalsNeeded":1,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"\(plan)}
        """.utf8))
    }

    @Test func backlogDecodesAndRoundTrips() throws {
        let t = try task(state: "backlog", planned: true)
        #expect(t.state == .backlog)
        #expect(String(decoding: try JSONEncoder().encode(Wire.TaskState.backlog), as: UTF8.self) == #""backlog""#)
        #expect(LiveAdapter.state(.backlog) == .backlog)
    }

    @Test func anUnknownFutureStateStillFallsBack() throws {
        let t = try task(state: "somewhereNewer", planned: false)
        #expect(t.state == .other("somewhereNewer"))
        #expect(LiveAdapter.state(t.state) == .building)
    }

    @Test func itsDetailSaysWhetherItsPlanned() throws {
        let planned = LiveAdapter.task(try task(state: "backlog", planned: true), goals: [], members: [], me: "andrea")
        #expect(planned.state == .backlog)
        #expect(planned.detail == "Backlog · plan v2")
        // Its plan can still be revised, by the planner.
        #expect(planned.isSteerable)
        let unplanned = LiveAdapter.task(try task(state: "backlog", planned: false), goals: [], members: [], me: "andrea")
        #expect(unplanned.detail == "Backlog · not planned")
        #expect(!unplanned.isSteerable)
    }

    @Test func aParkedPlanDoesntNeedYou() throws {
        #expect(!LiveAdapter.needsYou(try task(state: "backlog", planned: true), me: "andrea"))
        #expect(LiveAdapter.needsYou(try task(state: "awaitingApproval", planned: true), me: "andrea"))
    }

    @Test func itsTrackShowsBacklogOnlyWhileParked() {
        #expect(TaskState.stages(for: .backlog).contains(.backlog))
        #expect(!TaskState.stages(for: .building).contains(.backlog))
        #expect(TaskState.pipeline.firstIndex(of: .backlog)! == TaskState.pipeline.firstIndex(of: .awaitingApproval)! + 1)
    }
}
