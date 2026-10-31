import Foundation
import Testing
@testable import MapleFactory

/// A task's priority and what it follows up come through LiveAdapter; one from an older server,
/// without the fields, has neither.
@MainActor struct PriorityTests {
    private func task(_ fields: String = "") throws -> Wire.Task {
        try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-2","goal":"g","title":"A follow-up","state":"drafting","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":0,"approvalsNeeded":0,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"\(fields)}
        """.utf8))
    }

    private let goals = [Wire.Goal(id: "g", name: "Auth", prefix: "MF", color: "#336699", summary: "", lead: "andrea", repos: [])]

    @Test func decodesItsPriorityAndWhatItFollowsUp() throws {
        let wire = try task(#","priority":"p2","followUpOf":"MF-1#f3""#)
        #expect(wire.priority == .p2)
        #expect(wire.followUpOf == "MF-1#f3")
        let task = LiveAdapter.task(wire, goals: goals, members: [], me: "andrea")
        #expect(task.priority == "p2")
        #expect(task.followUpOf == "MF-1#f3")
    }

    @Test func aNullPriorityIsNone() throws {
        let wire = try task(#","priority":null,"followUpOf":null"#)
        #expect(LiveAdapter.task(wire, goals: goals, members: [], me: "andrea").priority == nil)
    }

    @Test func anOlderServersTaskHasNeither() throws {
        let wire = try task()
        #expect(wire.priority == nil)
        #expect(wire.followUpOf == nil)
        let task = LiveAdapter.task(wire, goals: goals, members: [], me: "andrea")
        #expect(task.priority == nil)
        #expect(task.followUpOf == nil)
    }
}
