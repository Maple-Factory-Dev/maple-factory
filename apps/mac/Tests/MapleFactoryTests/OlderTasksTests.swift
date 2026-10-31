import Foundation
import Testing
@testable import MapleFactory

/// The snapshot window (MF-212): the snapshot leaves out tasks finished over 14 days ago; its tallies
/// still count them, `tasks.page` and `task.get` bring them in, and progress counts stay whole throughout.
@MainActor struct OlderTasksTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private func task(_ id: String, _ state: String, updated: UInt64 = 2) -> String {
        """
        {"id":"\(id)","goal":"g","title":"Task \(id)","state":"\(state)","owner":"alice","brief":"",
         "createdAt":1,"updatedAt":\(updated),"planVersion":1,"approvalsNeeded":1,"reviewsNeeded":0,"shareable":false,"agent":"claude"}
        """
    }

    /// Two open, one recently merged; the tally says 4 more merged and 2 cancelled were left out.
    private func client(tallies: Bool = true) throws -> FactoryClient {
        let tally = tallies ? #","tallies":[{"goal":"g","merged":5,"cancelled":2,"closed":0,"total":9}],"olderTasks":6"# : ""
        let client = FactoryClient()
        client.apply(try decode(#"""
        {"type":"snapshot","org":"acme","protocolVersion":2,
         "me":{"login":"alice","role":"member","teams":[]},"members":[{"login":"alice","role":"admin","teams":[]}],
         "machines":[],"ended":[],
         "goals":[{"id":"g","name":"Goal","prefix":"MF","color":"#14B8A6","summary":"","lead":"alice","repos":[]}],
         "tasks":[\#(task("MF-1", "building")),\#(task("MF-2", "drafting")),\#(task("MF-3", "merged"))]\#(tally),
         "acceptances":[],"online":[],"notes":[],"follows":[],"intake":[],"repos":[],"secrets":[],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}}}
        """#))
        return client
    }

    @Test func snapshotCountsWhatItLeftOut() throws {
        let client = try client()
        #expect(client.older["g"] == OlderTasks(merged: 4, finished: 6))
        #expect(client.hasOlder(goal: "g"))
    }

    @Test func anOlderServerLeavesNothingOut() throws {
        let client = try client(tallies: false)
        #expect(client.older.isEmpty)
        #expect(!client.hasOlder(goal: "g"))
    }

    @Test func pagesJoinTheTasksAndTheCountsGoDown() throws {
        let client = try client()
        client.apply(try decode(#"{"type":"tasks.page","goal":"g","more":true,"tasks":[\#(task("MF-9", "merged")),\#(task("MF-8", "cancelled"))]}"#))
        #expect(client.tasks.map(\.id) == ["MF-1", "MF-2", "MF-3", "MF-9", "MF-8"])
        #expect(client.factoryTasks.map(\.id) == client.tasks.map(\.id))
        #expect(client.older["g"] == OlderTasks(merged: 3, finished: 4))
        // A task already there (a live update brought it) isn't added or counted twice.
        client.apply(try decode(#"{"type":"tasks.page","goal":"g","more":false,"tasks":[\#(task("MF-9", "merged"))]}"#))
        #expect(client.tasks.count == 5)
        // The last page: none left, whatever the counts say.
        #expect(!client.hasOlder(goal: "g"))
    }

    @Test func aTaskAskedForByIdJoinsQuietly() throws {
        let client = try client()
        client.fetchTask(id: "MF-7")
        client.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-7", "merged"))}"#))
        #expect(client.tasks.last?.id == "MF-7")
        #expect(client.older["g"] == OlderTasks(merged: 3, finished: 5))
    }
}
