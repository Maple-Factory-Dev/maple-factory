import Foundation
import Testing
@testable import MapleFactory

/// A task's effort comes through LiveAdapter; one from an older server, without the field, has none.
@MainActor struct EffortTests {
    private func task(effort: String?) throws -> Wire.Task {
        let field = effort.map { #","effort":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"building","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"\(field)}
        """.utf8))
    }

    private let goals = [Wire.Goal(id: "g", name: "Auth", prefix: "MF", color: "#336699", summary: "", lead: "andrea", repos: [])]

    @Test func decodesItsEffort() throws {
        let wire = try task(effort: "Login revamp")
        #expect(wire.effort == "Login revamp")
        #expect(LiveAdapter.task(wire, goals: goals, members: [], me: "andrea").effort == "Login revamp")
    }

    @Test func anOlderServersTaskHasNone() throws {
        let wire = try task(effort: nil)
        #expect(wire.effort == nil)
        #expect(LiveAdapter.task(wire, goals: goals, members: [], me: "andrea").effort == nil)
    }

    @Test func siblingsAreTheGoalsTasksWithTheSameEffortInIdOrder() {
        let state = AppState()
        let siblings = state.tasks(inEffort: "Login revamp", goal: "Auth overhaul")
        #expect(siblings.map(\.id) == ["ATL-136", "ATL-138", "ATL-149", "ATL-152", "ATL-163"])
        #expect(siblings.filter { $0.state == .merged }.count == 2)
        #expect(state.efforts(in: "Auth overhaul") == ["Login revamp"])
        #expect(state.efforts(in: "Billing v2") == ["Stripe hardening"])
    }

    @Test func settingAnEffortShowsInItsSiblings() {
        let state = AppState()
        state.setEffort("ATL-161", "  Login   revamp ")
        #expect(state.task("ATL-161").effort == "Login revamp")
        #expect(state.tasks(inEffort: "Login revamp", goal: "Auth overhaul").map(\.id).contains("ATL-161"))
        state.setEffort("ATL-161", nil)
        #expect(state.task("ATL-161").effort == nil)
    }
}
