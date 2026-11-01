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

    @Test func secretsAndMergeHoldsFollowSnapshotAndDeltas() throws {
        var state = FeedState()
        state.apply(try decode(snapshot))
        #expect(state.secrets.isEmpty)
        #expect(state.mergeHolds.isEmpty)

        let withBoth = snapshot.replacingOccurrences(of: "\"runnerLatest\":\"0.10.1\"}", with: """
        "runnerLatest":"0.10.1",
         "secrets":[{"repo":"acme/web","name":"API_KEY","updatedBy":"andrea","updatedAt":3}],
         "mergeHolds":[{"repo":"acme/web","reason":"Incident","by":"sam","at":4}]}
        """)
        state.apply(try decode(withBoth))
        #expect(state.secrets.map(\.name) == ["API_KEY"])
        #expect(state.mergeHolds.map(\.repo) == ["acme/web"])
        #expect(state.mergeHolds.first?.reason == "Incident")

        state.apply(try decode("""
        {"type":"secrets.updated","secrets":[{"repo":"acme/web","name":"API_KEY","updatedBy":"andrea","updatedAt":3},
         {"repo":"acme/api","name":"DB_URL","updatedBy":"sam","updatedAt":6}]}
        """))
        #expect(state.secrets.map(\.name) == ["API_KEY", "DB_URL"])

        state.apply(try decode(#"{"type":"mergeHolds.updated","holds":[]}"#))
        #expect(state.mergeHolds.isEmpty)
        state.apply(try decode(#"{"type":"mergeHolds.updated","holds":[{"repo":"acme/api","reason":"Freeze","by":"andrea","at":7}]}"#))
        #expect(state.mergeHolds.map(\.repo) == ["acme/api"])

        // A snapshot without them (an older server) clears what was there.
        state.apply(try decode(snapshot))
        #expect(state.secrets.isEmpty)
        #expect(state.mergeHolds.isEmpty)
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

    // MARK: Activity

    private var activitySnapshot: String {
        let one = task("MF-1", state: "building", extra: #","events":[{"who":"andrea","text":"approved the plan","at":100},{"who":"builder","text":"pushed step 1","at":300}]"#)
        let two = task("MF-2", state: "reviewing", extra: #","events":[{"who":"planner","text":"wrote a plan","at":200},{"who":"sam","text":"steered","at":400}]"#).replacingOccurrences(of: #""owner":"andrea""#, with: #""owner":"sam""#)
        let tasks = "[\(task("MF-1", state: "awaitingApproval")),\(task("MF-2", state: "building"))]"
        return snapshot.replacingOccurrences(of: tasks, with: "[\(one),\(two)]")
    }

    @Test func activityIsNewestFirstAcrossTasks() throws {
        var state = FeedState()
        state.apply(try decode(activitySnapshot))
        let feed = state.activity()
        #expect(feed.map(\.at) == [400, 300, 200, 100])
        #expect(feed.map(\.task) == ["MF-2", "MF-1", "MF-2", "MF-1"])
        #expect(feed.map(\.text).first == "steered")
    }

    @Test func activitySplitsAgentsFromPeople() throws {
        var state = FeedState()
        state.apply(try decode(activitySnapshot))
        #expect(state.activity(filter: .agents).map(\.who) == ["builder", "planner"])
        #expect(state.activity(filter: .people).map(\.who) == ["sam", "andrea"])
        #expect(state.activity(filter: .agents).allSatisfy { $0.isAgent })
        #expect(state.activity(filter: .people).allSatisfy { !$0.isAgent })
    }

    @Test func activityMyTasksAreTheOnesIOwn() throws {
        var state = FeedState()
        state.apply(try decode(activitySnapshot))
        #expect(state.activity(filter: .mine, me: "andrea").map(\.id) == ["MF-1-1", "MF-1-0"])
        #expect(state.activity(filter: .mine, me: "sam").map(\.task) == ["MF-2", "MF-2"])
        #expect(state.activity(filter: .mine, me: nil).isEmpty)
    }

    @Test func activityIdsAreStable() throws {
        var state = FeedState()
        state.apply(try decode(activitySnapshot))
        #expect(state.activity().map(\.id) == ["MF-2-1", "MF-1-1", "MF-2-0", "MF-1-0"])
        #expect(state.activity().map(\.id) == state.activity().map(\.id))
        #expect(Set(state.activity().map(\.id)).count == 4)
    }

    private func recurring(_ id: String, goal: String = "g1", nextAt: Int, paused: Bool = false, title: String? = nil) -> String {
        """
        {"id":"\(id)","goal":"\(goal)","title":"\(title ?? id)","brief":"Do it","agent":"claude","every":10080,"unit":"weeks",
         "firstAt":1,"timeZone":"UTC","nextAt":\(nextAt),"paused":\(paused),"by":"sam"}
        """
    }

    @Test func recurringFollowsSnapshotAndDeltas() throws {
        var state = FeedState()
        // An older server sends no recurring list: none.
        state.apply(try decode(snapshot))
        #expect(state.recurring.isEmpty)

        let withRecurring = snapshot.replacingOccurrences(of: #""runnerLatest":"0.10.1"}"#,
            with: #""runnerLatest":"0.10.1","recurring":[\#(recurring("r1", nextAt: 300)),\#(recurring("r2", nextAt: 100, paused: true)),\#(recurring("r9", goal: "g2", nextAt: 50))]}"#)
        state.apply(try decode(withRecurring))
        // Running first, then soonest; another goal's stay out.
        #expect(state.recurring(goal: "g1").map(\.id) == ["r1", "r2"])
        #expect(state.recurring(goal: "g2").map(\.id) == ["r9"])

        // A new one due sooner goes first; a changed one is replaced.
        state.apply(try decode(#"{"type":"recurring.updated","recurring":\#(recurring("r3", nextAt: 200))}"#))
        state.apply(try decode(#"{"type":"recurring.updated","recurring":\#(recurring("r2", nextAt: 100, title: "Renamed"))}"#))
        #expect(state.recurring(goal: "g1").map(\.id) == ["r2", "r3", "r1"])
        #expect(state.recurring["r2"]?.title == "Renamed")

        state.apply(try decode(#"{"type":"recurring.deleted","id":"r3"}"#))
        #expect(state.recurring(goal: "g1").map(\.id) == ["r2", "r1"])
    }
}
