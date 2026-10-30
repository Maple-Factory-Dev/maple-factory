import Foundation
import Testing
@testable import MapleKit

/// The iOS app's store keeps a FeedState: a snapshot, then deltas, decoded from the feed's JSON.
struct FeedStateTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private func task(_ id: String, state: String, extra: String = "") -> String {
        """
        {"id":"\(id)","goal":"g1","title":"Task \(id)","state":"\(state)","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":2,"approvalsNeeded":1,"reviewsNeeded":1,
         "shareable":false,"agent":"claude"\(extra)}
        """
    }

    private var snapshot: String {
        """
        {"type":"snapshot","org":"acme","protocolVersion":1,
         "me":{"login":"andrea","role":"admin"},
         "members":[{"login":"andrea","role":"admin"},{"login":"sam","role":"member"}],
         "machines":[{"id":"m1","name":"Studio","owner":"andrea","online":true,"version":"0.2.0"}],
         "goals":[{"id":"g1","name":"Maple","prefix":"MF","color":"#D24E26","summary":"","lead":"sam"}],
         "tasks":[\(task("MF-1", state: "awaitingApproval")),\(task("MF-2", state: "building"))],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}},
         "follows":[{"goal":"g1","following":false}],
         "runnerLatest":"0.10.1"}
        """
    }

    @Test func snapshotFillsTheState() throws {
        var state = FeedState()
        #expect(state.apply(try decode(snapshot)) == nil)
        #expect(state.hasSnapshot)
        #expect(state.org == "acme")
        #expect(state.me?.login == "andrea")
        #expect(state.tasks.map(\.id) == ["MF-1", "MF-2"])
        #expect(state.goals.first?.prefix == "MF")
        #expect(state.machines.first?.name == "Studio")
        #expect(state.follows["g1"] == false)
        #expect(state.following(state.goals[0]) == false)
        #expect(state.runnerOutdated(state.machines[0]))
    }

    @Test func taskDeltaReplacesOrInserts() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))

        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-1", state: "building"))}"#))
        #expect(state.tasks.count == 2)
        #expect(state.task("MF-1")?.state == .building)

        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-3", state: "drafting"))}"#))
        #expect(state.tasks.map(\.id) == ["MF-3", "MF-1", "MF-2"])

        state.apply(try decode(#"{"type":"task.removed","id":"MF-2"}"#))
        #expect(state.tasks.map(\.id) == ["MF-3", "MF-1"])
    }

    @Test func inboxGroupsWhatWaitsOnYou() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        #expect(state.inbox(for: "andrea").map(\.kind) == [.approval])

        // Once you've approved it, it leaves your inbox.
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-1", state: "awaitingApproval", extra: #","approvals":["andrea"]"#))}"#))
        #expect(state.inbox(for: "andrea").isEmpty)

        let hand = #","hand":{"reason":"needsInput","summary":"Which database?","at":9,"assignee":"andrea"}"#
        let mention = #","comments":[{"id":"c1","author":"sam","text":"@andrea look","at":5,"mentions":["andrea"]}]"#
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "building", extra: hand + mention))}"#))
        let kinds = state.inbox(for: "andrea").map(\.kind)
        #expect(kinds == [.hand, .mention])
    }

    @Test func notices() throws {
        var state = FeedState()
        #expect(state.apply(try decode(#"{"type":"toast","text":"Merged","taskId":"MF-1"}"#)) == .toast("Merged", taskId: "MF-1"))
        #expect(state.apply(try decode(#"{"type":"error","message":"Nope"}"#)) == .error("Nope"))
    }

    @Test func versions() {
        #expect(FeedState.version("0.2.0", isOlderThan: "0.10.1"))
        #expect(!FeedState.version("0.10.1", isOlderThan: "0.10.1"))
        #expect(!FeedState.version("1.0.0-beta", isOlderThan: "1.0"))
    }
}
