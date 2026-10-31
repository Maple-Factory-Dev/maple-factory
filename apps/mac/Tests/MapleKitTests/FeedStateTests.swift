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
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{"low":true}},
         "acceptances":[{"goal":"g1","upTo":"low","by":"sam","at":5}],
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
        // An approval is yours to give, whoever owns the task.
        #expect(state.inbox(for: "sam").map(\.assignee) == ["sam"])

        // Once you've approved it, it leaves your inbox.
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-1", state: "awaitingApproval", extra: #","approvals":["andrea"]"#))}"#))
        #expect(state.inbox(for: "andrea").isEmpty)

        let hand = #","hand":{"reason":"needsInput","summary":"Which database?","at":9,"assignee":"andrea"}"#
        let mention = #","comments":[{"id":"c1","author":"sam","text":"@andrea look","at":5,"mentions":["andrea"]}]"#
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "building", extra: hand + mention))}"#))
        let kinds = state.inbox(for: "andrea").map(\.kind)
        #expect(kinds == [.hand, .mention])
    }

    /// Like the Mac inbox: a task in review waits on you only once its automatic review passed.
    @Test func reviewWaitsForTheAutomaticReview() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        state.apply(try decode(#"{"type":"task.removed","id":"MF-1"}"#))
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "reviewing"))}"#))
        #expect(state.inbox(for: "andrea").isEmpty)

        let review = { (verdict: String) in
            #","autoReview":{"maxRounds":3,"rounds":[{"number":1,"verdict":"\#(verdict)","found":0,"at":4}],"summary":"","ask":[],"proofs":[],"findings":[]}"#
        }
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "reviewing", extra: review("changesRequested")))}"#))
        #expect(state.inbox(for: "andrea").isEmpty)

        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "reviewing", extra: review("passed")))}"#))
        let entries = state.inbox(for: "andrea")
        #expect(entries.map(\.kind) == [.review])
        #expect(entries.first?.message == "Passed automatic review; ready for yours")
        // Once you've approved the changes, it leaves your inbox.
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "reviewing", extra: review("passed") + #","reviews":["andrea"]"#))}"#))
        #expect(state.inbox(for: "andrea").isEmpty)
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

    @Test func githubStatusFollowsTheFeed() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        #expect(state.githubStatus == nil)

        let incident = #"{"indicator":"minor","description":"Partial System Outage","incidents":[{"name":"Incident with Actions","status":"investigating","url":"https://www.githubstatus.com/incidents/x"}],"components":["Actions"],"checkedAt":1}"#
        state.apply(try decode(#"{"type":"github.status","status":\#(incident)}"#))
        #expect(state.githubStatus?.incidents.first?.name == "Incident with Actions")

        // All clear, whether the server says nothing or an operational status.
        state.apply(try decode(#"{"type":"github.status","status":{"indicator":"none","description":"All Systems Operational","incidents":[],"components":[],"checkedAt":2}}"#))
        #expect(state.githubStatus == nil)
        state.apply(try decode(#"{"type":"github.status","status":\#(incident)}"#))
        state.apply(try decode(#"{"type":"github.status"}"#))
        #expect(state.githubStatus == nil)
    }

    @Test func policyAndAcceptancesFollowTheFeed() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        #expect(state.policy?.autoMerge["low"] == true)
        #expect(state.acceptance(for: "g1")?.upTo == .low)
        #expect(state.acceptance(for: "g1")?.by == "sam")
        #expect(state.acceptance(for: "g2") == nil)

        state.apply(try decode(#"{"type":"policy.updated","policy":{"maxFiles":10,"maxLines":200,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{"low":true,"medium":true},"autoMerges":false},"acceptances":[{"goal":"g1","upTo":"medium","by":"andrea","at":9}]}"#))
        #expect(state.policy?.maxFiles == 10)
        #expect(state.policy?.autoMerges == false)
        #expect(state.acceptance(for: "g1")?.upTo == .medium)
        #expect(state.acceptance(for: "g1")?.by == "andrea")

        // Taking it back: the server sends the list without it.
        state.apply(try decode(#"{"type":"policy.updated","policy":{"maxFiles":10,"maxLines":200,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}},"acceptances":[]}"#))
        #expect(state.acceptance(for: "g1") == nil)
    }

    @Test func canLeadIsTheLeadOrAnAdmin() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        let goal = state.goals[0]
        let admin = state.member("andrea")
        let lead = Wire.Member(login: "sam", role: "member")
        let other = Wire.Member(login: "kim", role: "member")
        #expect(state.canLead(goal, me: admin))
        #expect(state.canLead(goal, me: lead))
        #expect(!state.canLead(goal, me: other))
        #expect(!state.canLead(goal, me: nil))
    }

    @Test func unfinishedTasksLeaveOutMergedAndCancelled() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-3", state: "merged"))}"#))
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-4", state: "cancelled"))}"#))
        state.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-5", state: "draft"))}"#))
        #expect(Set(state.unfinishedTasks(in: "g1").map(\.id)) == ["MF-1", "MF-2", "MF-5"])
        #expect(state.unfinishedTasks(in: "g2").isEmpty)
    }
}
